import SwiftUI

/// Clipboard, per the handoff: a search field, then 38pt rows with a type
/// icon, the content, the source app and time, and a pin. The first (or
/// chosen) row is highlighted; ↑↓ move, ⏎ pastes into the app underneath,
/// ⌘P pins, ⌫ deletes, Esc hands the keyboard back.
struct ClipboardView: View {
    @Bindable var clipboard: PasteboardMonitor
    let shield: ContentShield
    let session: ScreenSession
    /// Copy is done; fold the island and paste.
    let onPaste: () -> Void

    @State private var selected = 0
    @State private var toolResult: String?
    @FocusState private var searchFocused: Bool

    private var entries: [ClipEntry] { clipboard.visibleEntries }

    var body: some View {
        VStack(spacing: 8) {
            searchField
            if entries.isEmpty {
                EmptyPaneHint(symbol: "doc.on.clipboard",
                              text: clipboard.query.isEmpty ? L10n.string("Copied text and files will appear here") : L10n.string("No matches"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                                ClipRow(entry: entry, isSelected: index == clampedSelection, clipboard: clipboard, shield: shield) {
                                    selected = index
                                }
                                .id(entry.id)
                            }
                        }
                    }
                    .onChange(of: clampedSelection) { _, index in
                        guard entries.indices.contains(index) else { return }
                        withAnimation(HubTheme.Motion.quick) { proxy.scrollTo(entries[index].id) }
                    }
                }
                toolStrip
            }
        }
        .onChange(of: clipboard.query) { selected = 0 }
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            if session.wantsKeyboard { searchFocused = true }
        }
        .onChange(of: session.wantsKeyboard) { _, wants in searchFocused = wants }
    }

    /// The selected entry's text, when it may be shown and transformed.
    private var selectedText: String? {
        guard entries.indices.contains(clampedSelection) else { return nil }
        let entry = entries[clampedSelection]
        guard case .text(let text) = entry.content, !shield.masks(entry.id.uuidString, in: .clipboard) else { return nil }
        return text
    }

    /// Developer tools for the selected text. The result is copied and lands
    /// at the top of the history, ready to paste.
    @ViewBuilder
    private var toolStrip: some View {
        if let text = selectedText {
            HStack(spacing: 6) {
                if let toolResult {
                    Label(toolResult, systemImage: "checkmark")
                        .font(HubTheme.Font.meta)
                        .foregroundStyle(HubTheme.Palette.success)
                        .lineLimit(1)
                        .fixedSize()
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(TextTool.suggestions(for: text)) { tool in
                            GhostPill(title: tool.title, symbol: tool.symbol) { run(tool, on: text) }
                        }
                    }
                }
            }
            .frame(height: 26)
        }
    }

    private func run(_ tool: TextTool, on text: String) {
        guard let result = tool.apply(to: text) else {
            show(L10n.string("Not applicable"))
            return
        }
        clipboard.copyText(result, record: true)
        selected = 0
        show(L10n.format("%@ copied", tool.title))
    }

    private func show(_ message: String) {
        toolResult = message
        Task {
            try? await Task.sleep(for: .seconds(2))
            if toolResult == message { toolResult = nil }
        }
    }

    private var clampedSelection: Int { min(max(0, selected), max(0, entries.count - 1)) }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(HubTheme.Palette.tertiary)
            TextField("", text: $clipboard.query, prompt: Text(L10n.string("Search clipboard")).foregroundStyle(HubTheme.Palette.tertiary))
                .textFieldStyle(.plain)
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.primary)
                .focused($searchFocused)
                .onSubmit(pasteSelected)
                .onKeyPress(.upArrow) { move(-1) }
                .onKeyPress(.downArrow) { move(1) }
                .onKeyPress(.escape) {
                    session.wantsKeyboard = false
                    return .handled
                }
                .onKeyPress(phases: .down) { press in handle(press) }
            ShortcutBadge(text: "⌘⇧V")
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous).fill(HubTheme.Palette.card))
    }

    private func move(_ delta: Int) -> KeyPress.Result {
        guard !entries.isEmpty else { return .ignored }
        selected = min(max(0, clampedSelection + delta), entries.count - 1)
        return .handled
    }

    private func handle(_ press: KeyPress) -> KeyPress.Result {
        guard entries.indices.contains(clampedSelection) else { return .ignored }
        let entry = entries[clampedSelection]
        if press.modifiers.contains(.command), press.characters.lowercased() == "p" {
            clipboard.togglePin(entry.id)
            return .handled
        }
        if press.key == .delete, clipboard.query.isEmpty {
            clipboard.remove(entry.id)
            return .handled
        }
        return .ignored
    }

    private func pasteSelected() {
        guard entries.indices.contains(clampedSelection) else { return }
        clipboard.copy(entries[clampedSelection].id)
        selected = 0
        onPaste()
    }
}

private struct ClipRow: View {
    let entry: ClipEntry
    let isSelected: Bool
    let clipboard: PasteboardMonitor
    let shield: ContentShield
    let select: () -> Void
    @State private var isHovered = false
    @State private var copiedFlash = false

    private var rowID: String { entry.id.uuidString }
    private var hidden: Bool { shield.masks(rowID, in: .clipboard) }

    var body: some View {
        let kind = entry.kind
        HStack(spacing: 10) {
            Image(systemName: copiedFlash ? "checkmark" : kind.symbol)
                .font(.system(size: 14))
                .foregroundStyle(copiedFlash ? HubTheme.Palette.success : isSelected ? HubTheme.Palette.accentLight : HubTheme.Palette.muted)
                .frame(width: 18)
            if case .color(let hex) = kind, !hidden {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(hex: UInt32(hex, radix: 16) ?? 0))
                    .frame(width: 14, height: 14)
            }
            ShieldedText(
                text: entry.preview,
                hidden: hidden,
                font: kind.isMonospaced ? HubTheme.Font.mono : HubTheme.Font.body
            )
            if isHovered, shield.isShielded(.clipboard) {
                RevealButton(hidden: hidden) { shield.togglePeek(rowID) }
            }
            Text([entry.source, ClipFormat.ago(entry.date)].compactMap { $0 }.joined(separator: " · "))
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.tertiary)
                .lineLimit(1)
                .fixedSize()
            if entry.pinned || isHovered {
                Button { clipboard.togglePin(entry.id) } label: {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12))
                        .foregroundStyle(entry.pinned ? HubTheme.Palette.muted : HubTheme.Palette.tertiary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? L10n.string("Unpin (⌘P)") : L10n.string("Pin (⌘P)"))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .selectedRow(isSelected || isHovered)
        .contentShape(Rectangle())
        .onTapGesture {
            select()
            clipboard.copy(entry.id)
            copiedFlash = true
            Task {
                try? await Task.sleep(for: .seconds(1))
                copiedFlash = false
            }
        }
        .onHover { isHovered = $0 }
        .contextMenu {
            Button(entry.pinned ? L10n.string("Unpin") : L10n.string("Pin")) { clipboard.togglePin(entry.id) }
            Button(L10n.string("Delete"), role: .destructive) { clipboard.remove(entry.id) }
        }
    }
}
