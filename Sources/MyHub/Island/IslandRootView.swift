import SwiftUI

/// Everything drawn in one island window: the black shape and, when open,
/// the current tab's content above the dock.
struct IslandRootView: View {
    let model: HubModel
    let session: ScreenSession

    private var isOpen: Bool { session.isActive }
    private var theme: PanelTheme { ThemeState.shared.theme }

    /// Where the gradient starts black: the edge the island hangs from.
    private var dockedEdge: UnitPoint {
        switch session.metrics.position {
        case .center: .top
        case .left: .leading
        case .right: .trailing
        }
    }
    private var size: CGSize { session.bodySize }
    private var topRadius: CGFloat { isOpen ? HubTheme.Radius.openTop : HubTheme.Radius.collapsedTop }

    /// Over a real hole with nothing to show, paint nothing: the hole is black
    /// already, and a painted shape would linger in Mission Control and
    /// mid-swipe between spaces as a second, squarer notch.
    private var paintsShape: Bool {
        !session.metrics.sitsOnNotch || size != session.metrics.notch
    }

    /// Top-left of the body in SwiftUI's window coordinates (origin top-left),
    /// wherever the island is docked.
    private var origin: CGPoint {
        let metrics = session.metrics
        let rect = metrics.toWindow(metrics.bodyRect(size))
        return CGPoint(x: rect.minX, y: metrics.windowSize.height - rect.maxY)
    }

    /// The open outline the shadow is drawn for.
    private func shadowKey(side: Bool) -> PanelShadow.Key {
        let open = session.openBodySize
        let top = HubTheme.Radius.openTop
        return PanelShadow.Key(
            width: open.width + (side ? 0 : 2 * top), height: open.height + (side ? 2 * top : 0),
            topRadius: top, bottomRadius: HubTheme.Radius.openBottom,
            position: session.metrics.position, offsetY: side ? 10 : 20,
            scale: session.metrics.screen.backingScaleFactor
        )
    }

    private var shape: IslandShape {
        IslandShape(
            topRadius: topRadius,
            bottomRadius: isOpen ? HubTheme.Radius.openBottom : HubTheme.Radius.collapsedBottom,
            position: session.metrics.position
        )
    }

    /// Where content sits inside the shape: against the docked edge, so the
    /// growing shape uncovers it from the notch outwards.
    private var contentAlignment: Alignment {
        switch session.metrics.position {
        case .center: .top
        case .left: .leading
        case .right: .trailing
        }
    }

    var body: some View {
        let side = session.metrics.position.isSide
        // The shoulders extend past the body along the docked edge.
        let shapeSize = CGSize(width: size.width + (side ? 0 : 2 * topRadius), height: size.height + (side ? 2 * topRadius : 0))
        let open = session.openBodySize

        ZStack(alignment: contentAlignment) {
            shape.fill(paintsShape ? Color.black : Color.clear)
            // The theme's gradient fades in with the opening and out with the
            // close, so the closed notch is always plain black.
            if theme.isGradient {
                shape.fill(theme.background(from: dockedEdge))
                    .opacity(isOpen ? 1 : 0)
            }

            if isOpen {
                // Laid out at its open size from the first frame and revealed
                // by the shape as it grows — never squeezed, never spilling
                // outside the black. A bigger panel (Settings → Panel size)
                // gives the tabs more room; nothing is magnified.
                panel
                    .frame(width: open.width, height: open.height, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .opacity.animation(HubTheme.Motion.contentIn),
                        removal: .opacity.animation(HubTheme.Motion.contentOut)
                    ))
            } else if let flash = session.flash {
                NotchFlashView(flash: flash, gap: side ? 8 : session.metrics.notch.width)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(HubTheme.Motion.contentOut))
            } else if session.showsFocus {
                FocusLiveView(focus: model.focus, gap: side ? 8 : session.metrics.notch.width)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(HubTheme.Motion.contentOut))
            } else if session.showsAgents {
                AgentLiveView(agents: model.agents, gap: side ? 8 : session.metrics.notch.width)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(HubTheme.Motion.contentOut))
            } else if session.showsBadge {
                InboxBadgeView(count: model.inbox.badgeCount, side: side)
                    .frame(width: size.width, height: size.height)
                    .transition(.opacity.animation(HubTheme.Motion.contentOut))
            }
        }
        .frame(width: shapeSize.width, height: shapeSize.height, alignment: contentAlignment)
        .clipShape(shape)
        // The shadow is the costliest thing to animate — a 25pt blur redrawn
        // every frame the outline changes. It arrives once the panel has
        // settled and leaves the instant it starts to close.
        .background {
            // Drawn once per size as an image (PanelShadow); only shown open,
            // where the outline is fixed.
            if isOpen {
                PanelShadowView(key: shadowKey(side: side))
                    .transition(.asymmetric(insertion: .opacity.animation(HubTheme.Motion.shadowIn), removal: .identity))
            }
        }
        .offset(x: origin.x - (side ? 0 : topRadius), y: origin.y - (side ? topRadius : 0))
        .frame(width: session.metrics.windowSize.width, height: session.metrics.windowSize.height, alignment: .topLeading)
        // A soft spring out, a quicker critically-damped return — closing
        // should feel like letting go, not like a bounce.
        .animation(isOpen ? HubTheme.Motion.open : HubTheme.Motion.close, value: isOpen)
        .animation(HubTheme.Motion.open, value: session.flash)
        .animation(HubTheme.Motion.open, value: session.showsFocus)
        .animation(HubTheme.Motion.open, value: session.showsBadge)
        .animation(HubTheme.Motion.open, value: session.showsAgents)
        .environment(\.colorScheme, .dark)
        .environment(model.drafts)
    }

    private var panel: some View {
        VStack(spacing: ScreenMetrics.stackGap) {
            SectionPane(model: model, session: session)
                .id(model.section)
                .transition(.opacity)
                .frame(height: session.metrics.contentHeight)
                .frame(maxWidth: .infinity)
            DockView(model: model, session: session)
        }
        .animation(HubTheme.Motion.content, value: model.section)
        .padding(.top, session.metrics.topPadding)
        .padding(.horizontal, ScreenMetrics.horizontalPadding)
        .padding(.bottom, ScreenMetrics.bottomPadding)
        .foregroundStyle(HubTheme.Palette.primary)
    }
}

/// The pane for the current section.
struct SectionPane: View {
    let model: HubModel
    let session: ScreenSession

    var body: some View {
        switch model.section {
        case .stash:
            StashView(stash: model.stash, session: session, onFormActive: { model.formActive = $0 })
        case .clipboard:
            ClipboardView(clipboard: model.clipboard, shield: model.shield, session: session, onPaste: { model.pasteAndClose() })
        case .calendar:
            AgendaView(agenda: model.agenda, shield: model.shield, roomy: session.metrics.contentHeight > 220)
        case .notes:
            ScratchpadView(store: model.notes, snippets: model.snippets,
                           mode: Binding(get: { model.notesMode }, set: { model.notesMode = $0 }),
                           shield: model.shield, session: session,
                           useSnippet: { model.useSnippet($0, paste: $1) })
        case .focus:
            FocusView(focus: model.focus, session: session, onFormActive: { model.formActive = $0 })
        case .agents:
            AgentsView(agents: model.agents, shield: model.shield)
        case .inbox:
            InboxView(inbox: model.inbox, shield: model.shield, session: session) { target in
                if target == .dev { model.dev.page = .git }
                if target == .jira { model.jira.setupVisible = true }
                session.select(target)
            }
        case .jira:
            JiraView(jira: model.jira, shield: model.shield, session: session, onFormActive: { model.formActive = $0 })
        case .dev:
            DevView(dev: model.dev, preferences: model.preferences, session: session,
                    onFormActive: { model.formActive = $0 })
        case .usage:
            UsageView(usage: model.usage, shield: model.shield, session: session,
                      onFormActive: { model.formActive = $0 })
        case .builds:
            BuildsView(builds: model.builds, preferences: model.preferences)
        case .settings:
            SettingsView(model: model, session: session)
        }
    }
}
