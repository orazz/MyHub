import Foundation

/// Holds a disk write until typing pauses, and never loses the last one.
///
/// Each `schedule` replaces what was waiting — the newest closure carries the
/// newest state. `flush` runs it now (quit), `cancel` drops it (a reload that
/// was not an edit). Capture the owner weakly in the closure you pass in.
@MainActor
final class WriteCoalescer {
    private let delay: Duration
    private var pending: Task<Void, Never>?
    private var action: (@MainActor () -> Void)?

    init(delay: Duration = .milliseconds(800)) {
        self.delay = delay
    }

    var hasPendingWrite: Bool { action != nil }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        self.action = action
        pending?.cancel()
        pending = Task { [weak self, delay] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    func flush() {
        pending?.cancel()
        fire()
    }

    func cancel() {
        pending?.cancel()
        pending = nil
        action = nil
    }

    private func fire() {
        pending = nil
        let action = self.action
        self.action = nil
        action?()
    }
}
