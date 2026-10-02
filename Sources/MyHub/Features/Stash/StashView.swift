import AppKit
import SwiftUI

/// Stash, per the handoff: a header with the count and total size, then a
/// grid of tiles ending in a "Drop more" slot; what does not fit scrolls
/// sideways. Empty, the whole area is one drop zone.
///
/// The grid follows the panel size: four columns at the default width (as in
/// the mock), more as the panel widens, and a second row once the content
/// area is tall enough — a bigger panel shows more files, not bigger ones.
struct StashView: View {
    let stash: StashStore
    let session: ScreenSession
    var onFormActive: (Bool) -> Void = { _ in }
    @State private var shareAnchor = ShareAnchor()

    private static let gap: CGFloat = 8
    /// The mock's tile at the default width: (564 − 3 × 8) / 4.
    private static let tileWidth: CGFloat = 135
    /// Below this a tile's preview gets too flat to read; above it, two rows fit.
    private static let twoRowHeight: CGFloat = 230

    var body: some View {
        if stash.items.isEmpty {
            EmptyStash(targeted: session.isDropTarget, canAsk: stash.canAsk,
                       capturing: stash.isCapturingWindow) { stash.captureWindowToAsk() }
        } else {
            VStack(spacing: 10) {
                if stash.askingAbout.isEmpty {
                    header
                } else {
                    AskBar(stash: stash, session: session, onFormActive: onFormActive)
                }
                GeometryReader { proxy in
                    let layout = Self.layout(for: proxy.size, count: stash.items.count + 1)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHGrid(rows: Array(repeating: GridItem(.fixed(layout.tile.height), spacing: Self.gap), count: layout.rows),
                                  spacing: Self.gap) {
                            ForEach(stash.items) { item in
                                StashTile(item: item, stash: stash).frame(width: layout.tile.width, height: layout.tile.height)
                            }
                            DropSlot(targeted: session.isDropTarget).frame(width: layout.tile.width, height: layout.tile.height)
                        }
                        .frame(height: proxy.size.height, alignment: .top)
                    }
                    .scrollDisabled(stash.items.count + 1 <= layout.columns * layout.rows)
                }
            }
        }
    }

    /// Columns that fill the width at about the mock's tile width; a second
    /// row only when the panel is tall enough *and* the first row is full —
    /// three files should not sit in a corner of an empty grid.
    static func layout(for size: CGSize, count: Int) -> (columns: Int, rows: Int, tile: CGSize) {
        let columns = max(4, Int((size.width + gap) / (tileWidth + gap)))
        let rows = size.height >= twoRowHeight && count > columns ? 2 : 1
        let width = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
        let height = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
        return (columns, rows, CGSize(width: width, height: height))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Group {
                if stash.selection.isEmpty {
                    Text(summary)
                } else {
                    Text(L10n.format("%d selected", stash.selection.count))
                }
            }
            .font(HubTheme.Font.body)
            .foregroundStyle(HubTheme.Palette.secondary)
            .monospacedDigit()
            Spacer()
            if !stash.selection.isEmpty {
                if stash.canAsk {
                    GhostPill(title: L10n.string("Ask AI"), symbol: "sparkles") { stash.beginAsking(stash.selection) }
                }
                if stash.canEmail {
                    GhostPill(title: L10n.string("Email"), symbol: "envelope") { stash.email(stash.selection) }
                }
                GhostPill(title: L10n.string("Copy"), symbol: "doc.on.doc") { stash.copy(stash.selection) }
                GhostPill(title: L10n.string("Deselect"), symbol: "xmark") { stash.clearSelection() }
            }
            GhostPill(title: stash.selection.isEmpty ? L10n.string("Share all") : L10n.string("Share"), symbol: "square.and.arrow.up") {
                let ids = stash.selection.isEmpty ? Set(stash.items.map(\.id)) : stash.selection
                shareAnchor.share(stash.items.filter { ids.contains($0.id) }.map(\.url))
            }
            .background(ShareAnchorView(anchor: shareAnchor))
            if stash.selection.isEmpty, stash.canAsk {
                GhostPill(title: L10n.string("Window"), symbol: "macwindow") { stash.captureWindowToAsk() }
                    .help(L10n.string("Click a window to ask AI about it"))
                    .disabled(stash.isCapturingWindow)
            }
            GhostPill(title: L10n.string("Clear"), symbol: "trash") { stash.clear() }
        }
        .frame(height: 26)
    }

    private var summary: String {
        let count = stash.items.count == 1 ? L10n.string("1 item") : L10n.format("%d items", stash.items.count)
        let bytes = stash.totalBytes
        return bytes > 0 ? "\(count) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))" : count
    }
}

private struct StashTile: View {
    let item: StashItem
    let stash: StashStore
    @State private var hovering = false

    private var selected: Bool { stash.isSelected(item.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(HubTheme.Font.bodyMedium)
                    .foregroundStyle(HubTheme.Palette.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(item.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? L10n.string("Folder"))
                    .font(HubTheme.Font.meta)
                    .foregroundStyle(HubTheme.Palette.tertiary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous).fill(HubTheme.Palette.card))
        .overlay(
            RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous)
                .strokeBorder(selected ? HubTheme.Palette.accent : .clear, lineWidth: 1.5)
        )
        .overlay(dragSurface)
        .overlay(alignment: .topTrailing) {
            if hovering {
                Button { stash.remove(item.id) } label: { Image(systemName: "xmark") }
                    .buttonStyle(HubIconButtonStyle(size: 20, filled: true))
                    .accessibilityLabel(L10n.string("Remove from stash"))
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .topLeading) {
            if hovering {
                HStack(spacing: 4) {
                    if stash.canAsk {
                        Button { stash.beginAsking([item.id]) } label: { Image(systemName: "sparkles") }
                            .buttonStyle(HubIconButtonStyle(size: 20, filled: true))
                            .help(L10n.string("Ask AI"))
                    }
                    if stash.canEmail, item.size != nil {
                        Button { stash.email([item.id]) } label: { Image(systemName: "envelope") }
                            .buttonStyle(HubIconButtonStyle(size: 20, filled: true))
                            .help(L10n.string("Email"))
                    }
                    if item.isImage {
                        Button { ImageTools.annotate(item.url) } label: { Image(systemName: "pencil.tip.crop.circle") }
                            .buttonStyle(HubIconButtonStyle(size: 20, filled: true))
                            .help(L10n.string("Annotate in Preview"))
                        Button { copyAtOneX() } label: { Text("1x").font(.system(size: 9, weight: .bold)) }
                            .buttonStyle(HubIconButtonStyle(size: 20, filled: true))
                            .help(L10n.string("Copy at 1x (half the pixels of a Retina screenshot)"))
                    }
                }
                .padding(6)
                .transition(.opacity)
            }
        }
        .animation(HubTheme.Motion.quick, value: hovering)
        .help(item.url.path)
    }

    private var preview: some View {
        RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous)
            .fill(HubTheme.Palette.tile)
            .overlay {
                if let preview = stash.previews[item.id] {
                    Image(nsImage: preview)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(HubTheme.Palette.soft)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: HubTheme.Radius.row, style: .continuous))
            .frame(maxHeight: .infinity)
    }

    private func copyAtOneX() {
        let url = item.url
        Task {
            if let png = await ImageTools.halfSizePNG(of: url) { ImageTools.copyPNG(png) }
        }
    }

    private var dragSurface: some View {
        FileDragSource(
            urls: { stash.dragURLs(startingAt: item.id) },
            image: stash.icon(for: item),
            onClick: { stash.select(item.id, extending: !$0.isDisjoint(with: [.command, .shift])) },
            onDoubleClick: { stash.open(item.id) },
            onHover: { hovering = $0 },
            onDragChange: { stash.isDraggingOut = $0 },
            menu: { contextMenu }
        )
    }

    private var contextMenu: NSMenu {
        let ids: Set<UUID> = stash.isSelected(item.id) ? stash.selection : [item.id]
        let menu = NSMenu()
        menu.addItem(ActionMenuItem(L10n.string("Open"), symbol: "arrow.up.forward.app") { stash.open(item.id) })
        menu.addItem(ActionMenuItem(L10n.string("Show in Finder"), symbol: "folder") { stash.reveal(ids) })
        menu.addItem(ActionMenuItem(L10n.string("Copy"), symbol: "doc.on.doc") { stash.copy(ids) })
        if stash.canAsk {
            menu.addItem(ActionMenuItem(L10n.string("Ask AI…"), symbol: "sparkles") { stash.beginAsking(ids) })
        }
        if stash.canEmail {
            menu.addItem(ActionMenuItem(ids.count > 1 ? L10n.format("Email %d Files", ids.count) : L10n.string("Email"),
                                        symbol: "envelope") { stash.email(ids) })
        }
        if item.isImage {
            menu.addItem(ActionMenuItem(L10n.string("Annotate in Preview"), symbol: "pencil.tip.crop.circle") { ImageTools.annotate(item.url) })
            menu.addItem(ActionMenuItem(L10n.string("Copy at 1x"), symbol: "photo") { copyAtOneX() })
        }
        menu.addItem(.separator())
        menu.addItem(ActionMenuItem(L10n.string("Remove from Stash"), symbol: "xmark") { ids.forEach(stash.remove) })
        return menu
    }
}

/// "Ask … about …": a question and the files, sent to Claude Code, Codex,
/// Claude or ChatGPT — whichever this Mac has.
private struct AskBar: View {
    let stash: StashStore
    let session: ScreenSession
    let onFormActive: (Bool) -> Void
    @State private var question = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            targetMenu
            TextField("", text: $question, prompt: Text(placeholder).foregroundStyle(HubTheme.Palette.tertiary))
                .textFieldStyle(.plain)
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.primary)
                .focused($focused)
                .onSubmit { stash.ask(question) }
                .onExitCommand { stash.cancelAsking() }
            if let problem = stash.askProblem {
                Text(problem).font(HubTheme.Font.meta).foregroundStyle(HubTheme.Palette.warn).lineLimit(1).fixedSize()
            }
            GhostPill(title: L10n.string("Ask"), symbol: "return") { stash.ask(question) }
            Button { stash.cancelAsking() } label: { Image(systemName: "xmark") }
                .buttonStyle(HubIconButtonStyle(size: 22))
                .help(L10n.string("Cancel"))
        }
        .padding(.leading, 10)
        .padding(.trailing, 2)
        .frame(height: 26)
        .background(Capsule().fill(HubTheme.Palette.selected))
        .onAppear {
            onFormActive(true)
            session.wantsKeyboard = true
            focused = true
        }
        .onDisappear { onFormActive(false) }
    }

    /// Which app gets the question; only what's on this Mac.
    private var targetMenu: some View {
        Menu {
            ForEach(stash.askTargets, id: \.self) { target in
                Button { stash.chooseAskTarget(target) } label: {
                    Label(target.name, systemImage: target == stash.askTarget ? "checkmark" : target.symbol)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles").font(.system(size: 11))
                Text(stash.askTarget.name).font(HubTheme.Font.meta).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .foregroundStyle(HubTheme.Palette.accentLight)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(stash.askTargets.count < 2)
    }

    private var placeholder: String {
        let files = stash.askableFiles
        let about = files.count == 1 ? files[0].lastPathComponent : L10n.format("%d files", files.count)
        return stash.askTarget.takesQuestion
            ? L10n.format("Ask %@ about %@", stash.askTarget.name, about)
            : L10n.format("Question to paste in %@ (optional)", stash.askTarget.name)
    }
}

/// The last tile: always there to take more.
private struct DropSlot: View {
    let targeted: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 22))
                .foregroundStyle(HubTheme.Palette.accentLight)
            Text(L10n.string("Drop more"))
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.soft)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .background(DropZoneBackground(radius: HubTheme.Radius.card, targeted: targeted))
    }
}

/// No files: one full-size drop zone.
private struct EmptyStash: View {
    let targeted: Bool
    let canAsk: Bool
    let capturing: Bool
    let captureWindow: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous)
                .fill(HubTheme.Palette.accent.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: "tray.and.arrow.down").font(.system(size: 24)).foregroundStyle(HubTheme.Palette.accentLight))
                .scaleEffect(targeted ? 1.06 : 1)
                .animation(.easeOut(duration: 0.15), value: targeted)
            VStack(spacing: 4) {
                Text(L10n.string("Drop files on the notch to keep them here"))
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(HubTheme.Palette.strong)
                Text(L10n.string("Files stay until you drag them out or clear the stash"))
                    .font(HubTheme.Font.body)
                    .foregroundStyle(Color(hex: 0x7D7E83))
            }
            .multilineTextAlignment(.center)
            if canAsk {
                GhostPill(title: L10n.string("Ask AI about a window"), symbol: "macwindow", action: captureWindow)
                    .disabled(capturing)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DropZoneBackground(radius: HubTheme.Radius.dropZone, targeted: targeted))
    }
}

/// Holds the AppKit view the share sheet is anchored to.
@MainActor
final class ShareAnchor {
    weak var view: NSView?

    func share(_ urls: [URL]) {
        guard let view, !urls.isEmpty else { return }
        NSSharingServicePicker(items: urls).show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
}

struct ShareAnchorView: NSViewRepresentable {
    let anchor: ShareAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
