import SwiftUI

/// Notes, per the handoff: a list on the left under a dashed "New note" row;
/// the note on the right as a card — title, then text and checkboxes. Click
/// the text to edit it as plain text (`- [ ]` makes a checkbox); tick boxes
/// without entering the editor. Esc hands the keyboard back.
struct ScratchpadView: View {
    @Bindable var store: ScratchpadStore
    let snippets: SnippetStore
    @Binding var mode: NotesMode
    let shield: ContentShield
    let session: ScreenSession
    /// Expand a snippet onto the clipboard; `true` also pastes it.
    let useSnippet: (Snippet, Bool) -> Void

    @State private var editing = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode == .notes {
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 8) {
                        modeSwitch
                        list
                    }
                    .frame(width: 170)
                    editorCard
                }
            } else {
                SnippetsPane(store: snippets, session: session, use: useSnippet) { modeSwitch }
            }
        }
        .task {
            store.arrive()
            // A fresh, empty note opens straight into the editor.
            if store.selected?.isBlank == true { editing = true }
            try? await Task.sleep(for: .milliseconds(60))
            if editing, session.wantsKeyboard { editorFocused = true }
        }
        .onChange(of: session.wantsKeyboard) { _, wants in
            if wants, editing { editorFocused = true }
            if !wants { editorFocused = false; editing = false }
        }
        .onChange(of: store.selectedID) { editing = store.selected?.isBlank == true }
        .onKeyPress(.escape) {
            editing = false
            session.wantsKeyboard = false
            return .handled
        }
    }

    private var modeSwitch: some View {
        HubSegmented(options: [(NotesMode.notes, L10n.string("Notes")), (.snippets, L10n.string("Snippets"))],
                     selection: $mode)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - List

    private var list: some View {
        VStack(spacing: 2) {
            Button {
                store.add()
                editing = true
                session.wantsKeyboard = true
                editorFocused = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 13))
                    Text(L10n.string("New note")).font(HubTheme.Font.body)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(HubTheme.Palette.muted)
                .padding(.vertical, 8)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous)
                    .strokeBorder(HubTheme.Palette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressFade())
            .padding(.bottom, 4)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(store.visible) { note in
                        NoteRow(note: note, store: store, shield: shield)
                    }
                }
            }
        }
    }

    // MARK: - Editor

    @ViewBuilder
    private var editorCard: some View {
        Group {
            if store.isFileBroken {
                EmptyPaneHint(symbol: "exclamationmark.triangle",
                              text: L10n.string("notes.json could not be read. It is left untouched — fix or move it, then relaunch."))
            } else if let note = store.selected {
                if shield.masks(note.id.uuidString, in: .notes) {
                    VStack(alignment: .leading, spacing: 9) {
                        ShieldHatch().frame(height: 12).padding(.trailing, 120)
                        ForEach(0..<3, id: \.self) { _ in ShieldHatch().frame(height: 9) }
                        Spacer(minLength: 0)
                        HStack { Spacer(); RevealButton(hidden: true) { shield.togglePeek(note.id.uuidString) } }
                    }
                } else if editing {
                    TextEditor(text: Binding(get: { store.selected?.text ?? "" }, set: { store.update(note.id, text: $0) }))
                        .font(HubTheme.Font.body)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($editorFocused)
                        .id(note.id)
                } else {
                    RenderedNote(note: note) { line in
                        store.update(note.id, text: NoteText.toggling(note.text, line: line))
                    } edit: {
                        editing = true
                        session.wantsKeyboard = true
                        editorFocused = true
                    }
                }
            } else {
                EmptyPaneHint(symbol: "square.and.pencil", text: L10n.string("No note selected"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard()
    }
}

enum NotesMode: String, Sendable { case notes, snippets }

/// Snippets: the list on the left, the selected one on the right with its
/// title and text, and Copy / Paste. Placeholders are filled in at use time.
private struct SnippetsPane<Switch: View>: View {
    let store: SnippetStore
    let session: ScreenSession
    let use: (Snippet, Bool) -> Void
    @ViewBuilder let modeSwitch: Switch
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 8) {
                modeSwitch
                Button {
                    store.add()
                    session.wantsKeyboard = true
                    titleFocused = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus").font(.system(size: 13))
                        Text(L10n.string("New snippet")).font(HubTheme.Font.body)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(HubTheme.Palette.muted)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .overlay(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous)
                        .strokeBorder(HubTheme.Palette.dashed, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressFade())
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 2) {
                        ForEach(store.snippets) { snippet in
                            SnippetRow(snippet: snippet, store: store, use: use)
                        }
                    }
                }
            }
            .frame(width: 170)
            editor
        }
        .onDisappear { store.sweep() }
    }

    @ViewBuilder
    private var editor: some View {
        Group {
            if store.isFileBroken {
                EmptyPaneHint(symbol: "exclamationmark.triangle",
                              text: L10n.string("snippets.json could not be read. It is left untouched — fix or move it, then relaunch."))
            } else if let snippet = store.selected {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("", text: Binding(get: { store.selected?.title ?? "" }, set: { store.update(snippet.id, title: $0) }),
                              prompt: Text(L10n.string("Title")).foregroundStyle(HubTheme.Palette.tertiary))
                        .textFieldStyle(.plain)
                        .font(HubTheme.Font.title)
                        .frame(minHeight: 24)
                        .focused($titleFocused)
                    TextEditor(text: Binding(get: { store.selected?.body ?? "" }, set: { store.update(snippet.id, body: $0) }))
                        .font(HubTheme.Font.mono)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .id(snippet.id)
                    HStack(spacing: 6) {
                        Text(SnippetExpander.placeholders.map { "{{\($0)}}" }.joined(separator: " "))
                            .font(HubTheme.Font.axis)
                            .foregroundStyle(HubTheme.Palette.tertiary)
                            .lineLimit(1)
                            .help(L10n.string("Placeholders, filled in when the snippet is used"))
                        Spacer(minLength: 6)
                        GhostPill(title: L10n.string("Copy"), symbol: "doc.on.doc") { use(snippet, false) }
                        Button(L10n.string("Paste")) { use(snippet, true) }
                            .buttonStyle(LightCapsuleButtonStyle())
                    }
                }
            } else {
                EmptyPaneHint(symbol: "text.badge.plus", text: L10n.string("Save text you paste often — replies, code, values."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .hubCard()
    }
}

private struct SnippetRow: View {
    let snippet: Snippet
    let store: SnippetStore
    let use: (Snippet, Bool) -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(snippet.displayTitle.isEmpty ? L10n.string("New snippet") : snippet.displayTitle)
                .font(HubTheme.Font.bodyMedium)
                .foregroundStyle(snippet.displayTitle.isEmpty ? HubTheme.Palette.tertiary : HubTheme.Palette.primary)
                .lineLimit(1)
            Spacer(minLength: 2)
            if hovering {
                Button { use(snippet, true) } label: { Image(systemName: "arrow.down.doc") }
                    .buttonStyle(HubIconButtonStyle(size: 18))
                    .help(L10n.string("Paste"))
                Button { store.remove(snippet.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(HubIconButtonStyle(size: 18))
                    .help(L10n.string("Delete"))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectedRow(store.selectedID == snippet.id)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedID = snippet.id }
        .onHover { hovering = $0 }
    }
}

/// Title, text lines and checkboxes, read-only except for the boxes.
private struct RenderedNote: View {
    let note: Note
    let toggle: (Int) -> Void
    let edit: () -> Void

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 9) {
                Text(note.title.isEmpty ? L10n.string("Untitled") : note.title)
                    .font(HubTheme.Font.title)
                    .foregroundStyle(note.title.isEmpty ? HubTheme.Palette.tertiary : HubTheme.Palette.primary)
                ForEach(NoteText.body(of: note.text)) { line in
                    switch line {
                    case .task(let index, let text, let done):
                        HStack(spacing: 8) {
                            Button { toggle(index) } label: { Checkbox(done: done) }
                                .buttonStyle(.plain)
                            Text(text)
                                .font(HubTheme.Font.body)
                                .strikethrough(done, color: HubTheme.Palette.tertiary)
                                .foregroundStyle(done ? HubTheme.Palette.tertiary : HubTheme.Palette.primary)
                        }
                    case .text(_, let text):
                        Text(text).font(HubTheme.Font.body).foregroundStyle(HubTheme.Palette.soft)
                    case .gap:
                        Color.clear.frame(height: 2)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: edit)
        .help(L10n.string("Click to edit · “- [ ]” makes a checkbox"))
    }
}

/// 14×14, radius 4: accent fill with a dark check when done; a 1.5pt border when not.
private struct Checkbox: View {
    let done: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: HubTheme.Radius.checkbox)
            .fill(done ? HubTheme.Palette.accent : .clear)
            .overlay(
                RoundedRectangle(cornerRadius: HubTheme.Radius.checkbox)
                    .strokeBorder(done ? .clear : HubTheme.Palette.checkboxBorder, lineWidth: 1.5)
            )
            .overlay {
                if done {
                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(HubTheme.Palette.onLight)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}

private struct NoteRow: View {
    let note: Note
    let store: ScratchpadStore
    let shield: ContentShield
    @State private var hovering = false

    private var isSelected: Bool { store.selectedID == note.id }

    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if note.pinned {
                        Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(HubTheme.Palette.tertiary)
                    }
                    ShieldedText(
                        text: note.isBlank ? L10n.string("New note") : note.title,
                        hidden: !note.isBlank && shield.masks(note.id.uuidString, in: .notes),
                        font: HubTheme.Font.bodyMedium,
                        color: note.isBlank ? HubTheme.Palette.tertiary : HubTheme.Palette.primary
                    )
                }
                Text(NoteText.edited(note.edited))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
            }
            if hovering {
                Button { store.togglePin(note.id) } label: { Image(systemName: note.pinned ? "pin.slash" : "pin") }
                    .buttonStyle(HubIconButtonStyle(size: 18))
                    .help(note.pinned ? L10n.string("Unpin") : L10n.string("Pin"))
                Button { store.remove(note.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(HubIconButtonStyle(size: 18))
                    .help(L10n.string("Delete"))
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .selectedRow(isSelected)
        .contentShape(Rectangle())
        .onTapGesture { store.selectedID = note.id }
        .onHover { hovering = $0 }
    }
}
