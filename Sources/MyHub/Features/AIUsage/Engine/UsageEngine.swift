import Foundation

/// When a provider may be asked again. Pure, so the schedule is tested.
///
/// After success: not before `minimumInterval`. After failure: exponential
/// (30 s, 1 min, 2 min … capped at 30 min) with a little jitter, and never
/// sooner than the server's `Retry-After`.
struct Backoff: Sendable, Equatable {
    private(set) var failures = 0
    private(set) var notBefore = Date.distantPast

    static let base: TimeInterval = 30
    static let cap: TimeInterval = 30 * 60

    func allows(_ now: Date) -> Bool { now >= notBefore }

    mutating func succeeded(at now: Date, minimumInterval: TimeInterval) {
        failures = 0
        notBefore = now.addingTimeInterval(minimumInterval)
    }

    /// `jitter` in 0...1 (random in production, fixed in tests).
    mutating func failed(at now: Date, retryAfter: TimeInterval?, jitter: Double) {
        failures += 1
        let exponential = min(Self.base * pow(2, Double(failures - 1)), Self.cap)
        let wait = max(exponential * (1 + 0.2 * jitter), retryAfter ?? 0)
        notBefore = now.addingTimeInterval(wait)
    }
}

/// Runs providers in parallel and remembers, per account, when each may be
/// asked again. One slow or failing source never holds up or cancels the
/// others: each child returns its own outcome.
actor UsageEngine {
    struct Outcome: Sendable {
        let accountID: String
        let result: Result<UsageSnapshot, UsageError>?
        /// Skipped because of `minimumInterval` or backoff.
        var skipped: Bool { result == nil }
    }

    private var schedule: [String: Backoff] = [:]
    private let jitter: @Sendable () -> Double

    init(jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) }) {
        self.jitter = jitter
    }

    /// `force` (the refresh button) skips the polite interval after a success,
    /// never the backoff after a failure — hammering a rate-limited endpoint
    /// only extends the penalty.
    func refresh(_ providers: [any UsageProvider], now: Date, force: Bool) async -> [Outcome] {
        let due = providers.filter { provider in
            let state = schedule[provider.accountID] ?? Backoff()
            return state.allows(now) || (force && state.failures == 0)
        }
        let skipped = providers.filter { p in !due.contains { $0.accountID == p.accountID } }
            .map { Outcome(accountID: $0.accountID, result: nil) }

        var outcomes: [Outcome] = []
        await withTaskGroup(of: Outcome.self) { group in
            for provider in due {
                group.addTask {
                    do {
                        return Outcome(accountID: provider.accountID, result: .success(try await provider.fetch(now: now)))
                    } catch let error as UsageError {
                        return Outcome(accountID: provider.accountID, result: .failure(error))
                    } catch {
                        return Outcome(accountID: provider.accountID, result: .failure(.badResponse(String(describing: type(of: error)))))
                    }
                }
            }
            for await outcome in group { outcomes.append(outcome) }
        }

        for outcome in outcomes {
            let interval = due.first { $0.accountID == outcome.accountID }?.minimumInterval ?? 60
            var state = schedule[outcome.accountID] ?? Backoff()
            switch outcome.result {
            case .success: state.succeeded(at: now, minimumInterval: interval)
            case .failure(let error): state.failed(at: now, retryAfter: error.retryAfter, jitter: jitter())
            case nil: break
            }
            schedule[outcome.accountID] = state
        }
        return outcomes + skipped
    }

    func forget(_ accountID: String) {
        schedule[accountID] = nil
    }
}
