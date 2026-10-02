import SwiftUI

/// The Focus tab, per `design_handoff_focus_tab`: a large timer card with
/// the phase switch, clock, round bars and controls; beside it today's
/// totals, the three switches and a way into Timer settings.
///
/// Drawn for the 300pt content area of the Extra large panel and scaled down
/// for smaller ones: the clock follows the space, the side column narrows,
/// and labels shorten before anything is cut.
struct FocusView: View {
    let focus: FocusStore
    let session: ScreenSession
    let onFormActive: (Bool) -> Void

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            switch focus.showingSettings {
            case false:
                let side: CGFloat = size.width >= 680 ? 248 : 210
                HStack(spacing: 10) {
                    TimerCard(focus: focus, size: CGSize(width: size.width - side - 10, height: size.height))
                    SideColumn(focus: focus, compact: size.height < 260) { focus.showingSettings = true }
                        .frame(width: side)
                }
            case true:
                FocusSettings(focus: focus, compact: size.height < 260) { focus.showingSettings = false }
            }
        }
        .onAppear { onFormActive(true) }
        .onDisappear { onFormActive(false) }
        .onKeyPress(.escape) {
            if focus.showingSettings { focus.showingSettings = false } else { session.wantsKeyboard = false }
            return .handled
        }
    }
}

extension FocusCycle.Phase {
    /// Amber for focus, green for breaks — on every theme.
    var color: Color { self == .work ? HubTheme.Palette.amber : HubTheme.Palette.success }
}

// MARK: - Timer card

private struct TimerCard: View {
    let focus: FocusStore
    let size: CGSize

    private var innerWidth: CGFloat { size.width - 36 }
    private var compact: Bool { size.width < 420 }

    /// As large as the card allows, 104pt at most.
    private var clockSize: CGFloat {
        let height = size.height - 16 - 18 - 28 - 44 - 26 - 12
        return min(104, max(40, min(height, innerWidth / 2.75)))
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let cycle = focus.cycle
            let lengths = focus.lengths
            VStack(spacing: 0) {
                HStack {
                    PhaseSwitch(focus: focus, compact: compact)
                    Spacer(minLength: 6)
                    Text(compact
                         ? "\(cycle.round(lengths: lengths))/\(lengths.rounds)"
                         : L10n.format("Round %d of %d", cycle.round(lengths: lengths), lengths.rounds))
                        .font(.system(size: 12))
                        .foregroundStyle(HubTheme.Palette.secondary)
                        .monospacedDigit()
                }
                .frame(height: 28)

                Spacer(minLength: 4)
                VStack(spacing: 6) {
                    Text(FocusCycle.clock(cycle.remaining(at: now, lengths: lengths)))
                        .font(.system(size: clockSize, weight: .semibold))
                        .tracking(-0.045 * clockSize)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentTransition(.numericText(countsDown: true))
                    HStack(spacing: 6) {
                        Circle().fill(cycle.phase.color).frame(width: 7, height: 7)
                        Text(status(cycle, now: now, lengths: lengths))
                    }
                    .font(.system(size: 13))
                    .foregroundStyle(HubTheme.Palette.muted)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                Spacer(minLength: 4)

                HStack(spacing: 8) {
                    RoundBars(fills: cycle.roundFills(at: now, lengths: lengths), width: compact ? 18 : 30)
                    Spacer(minLength: 6)
                    CircleControl(symbol: "arrow.counterclockwise", size: compact ? 36 : 40, help: L10n.string("Reset")) { focus.reset() }
                    CircleControl(symbol: "forward.end.fill", size: compact ? 36 : 40, help: L10n.string("Skip")) { focus.skip() }
                    PrimaryControl(cycle: cycle, minWidth: compact ? 96 : 124) { focus.startOrPause() }
                }
                .frame(height: 44)
            }
            .padding(.top, 16)
            .padding(.horizontal, 18)
            .padding(.bottom, 18)
            .frame(width: size.width, height: size.height)
            .background(HubTheme.Palette.card)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(cycle.phase.color)
                    .frame(width: size.width * cycle.progress(at: now, lengths: lengths), height: 3)
                    // No per-second animation: it would keep SwiftUI drawing
                    // every frame while the timer runs, to move a line by a
                    // fraction of a point.
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private func status(_ cycle: FocusCycle, now: Date, lengths: FocusCycle.Lengths) -> String {
        let doing = cycle.phase == .work ? L10n.string("Focusing") : cycle.phase.title
        if let endsAt = cycle.endsAt {
            return L10n.format("%@ · ends at %@", doing, endsAt.formatted(date: .omitted, time: .shortened))
        }
        if cycle.isPaused {
            return L10n.format("Paused · %@", cycle.phase == .work ? L10n.string("focusing") : cycle.phase.title.lowercased())
        }
        let minutes = Int(lengths.length(of: cycle.phase) / 60)
        return cycle.phase == .work
            ? L10n.format("Ready · %d min focus", minutes)
            : L10n.format("Ready · %d min %@", minutes, cycle.phase.title.lowercased())
    }
}

/// Focus 25m · Short break · Long break, on a black capsule.
private struct PhaseSwitch: View {
    let focus: FocusStore
    let compact: Bool
    @Namespace private var capsule

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FocusCycle.Phase.allCases, id: \.self) { phase in
                let active = focus.cycle.phase == phase
                Button { focus.select(phase) } label: {
                    HStack(spacing: 5) {
                        if active { Circle().fill(phase.color).frame(width: 6, height: 6) }
                        Text(compact ? phase.shortTitle : phase.title)
                            .font(.system(size: 12, weight: active ? .semibold : .regular))
                            .foregroundStyle(active ? HubTheme.Palette.primary : HubTheme.Palette.iconInactive)
                        if active {
                            Text("\(Int(focus.lengths.length(of: phase) / 60))m")
                                .font(.system(size: 12))
                                .foregroundStyle(HubTheme.Palette.secondary)
                                .monospacedDigit()
                        }
                    }
                    .lineLimit(1)
                    .padding(.vertical, 5)
                    .padding(.horizontal, compact ? 9 : 12)
                    .background {
                        if active { Capsule().fill(HubTheme.Palette.segmentActive).matchedGeometryEffect(id: "phase", in: capsule) }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black))
        .animation(HubTheme.Motion.dock, value: focus.cycle.phase)
    }
}

/// One 30×6 bar per round: white when done, filling amber for the round
/// under way.
private struct RoundBars: View {
    let fills: [Double]
    let width: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            ForEach(Array(fills.enumerated()), id: \.offset) { _, fill in
                Capsule()
                    .fill(HubTheme.Palette.track)
                    .frame(width: width, height: 6)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(fill >= 1 ? HubTheme.Palette.primary : HubTheme.Palette.amber)
                            .frame(width: width * fill, height: 6)
                    }
            }
        }
    }
}

private struct CircleControl: View {
    let symbol: String
    let size: CGFloat
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.4))
                .foregroundStyle(hovering ? HubTheme.Palette.primary : HubTheme.Palette.soft)
                .frame(width: size, height: size)
                .background(Circle().fill(hovering ? HubTheme.Palette.segmentActive : HubTheme.Palette.selected))
                .contentShape(Circle())
        }
        .buttonStyle(PressFade())
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Start / Pause / Resume: a light capsule, 44 tall.
private struct PrimaryControl: View {
    let cycle: FocusCycle
    let minWidth: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: cycle.isRunning ? "pause.fill" : "play.fill").font(.system(size: 16))
                Text(cycle.isRunning ? L10n.string("Pause") : cycle.isPaused ? L10n.string("Resume") : L10n.string("Start"))
                    .font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(HubTheme.Palette.onLight)
            .frame(minWidth: minWidth, minHeight: 44)
            .padding(.horizontal, 14)
            .background(Capsule().fill(hovering ? Color.white : HubTheme.Palette.primary))
            .contentShape(Capsule())
        }
        .buttonStyle(PressFade())
        .onHover { hovering = $0 }
        .keyboardShortcut(.space, modifiers: [])
    }
}

// MARK: - Side column

private struct SideColumn: View {
    let focus: FocusStore
    let compact: Bool
    let openSettings: () -> Void
    @State private var hoveringSettings = false

    var body: some View {
        VStack(spacing: 8) {
            today
            VStack(spacing: 0) {
                toggle(compact ? L10n.string("On notch") : L10n.string("Countdown on notch"), "timer", \.showInNotch)
                toggle(compact ? L10n.string("Chime") : L10n.string("Chime at the end"), "bell", \.chime)
                toggle(L10n.string("Do Not Disturb"), "moon", \.doNotDisturb)
                    .help(L10n.string("Runs the Shortcuts set in Timer settings when a round starts and ends"))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 16)
            .frame(maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HubTheme.Palette.card))
            .toggleStyle(HubToggleStyle())

            Button(action: openSettings) {
                HStack(spacing: 8) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 14)).foregroundStyle(HubTheme.Palette.secondary)
                    Text(L10n.string("Timer settings")).font(.system(size: 12))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(HubTheme.Palette.secondary)
                }
                .padding(.horizontal, 14)
                .frame(height: compact ? 32 : 38)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(hoveringSettings ? HubTheme.Palette.selected : HubTheme.Palette.card))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringSettings = $0 }
        }
        .foregroundStyle(HubTheme.Palette.primary)
    }

    private var today: some View {
        let figures = focus.cycle.today(at: Date())
        let rounds = figures.rounds == 1 ? L10n.string("1 round") : L10n.format("%d rounds", figures.rounds)
        let focused = figures.rounds == 0 ? L10n.string("Nothing focused yet") : L10n.format("%@ focused", FocusCycle.duration(figures.focused))
        return Group {
            if compact {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(L10n.string("Today")).font(.system(size: 12)).foregroundStyle(HubTheme.Palette.secondary)
                    Text(rounds).font(.system(size: 15, weight: .semibold))
                    Spacer(minLength: 2)
                    Text(figures.rounds == 0 ? "" : FocusCycle.duration(figures.focused))
                        .font(.system(size: 12)).foregroundStyle(HubTheme.Palette.tertiary)
                }
                .padding(.vertical, 10)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Today")).font(.system(size: 12)).foregroundStyle(HubTheme.Palette.secondary)
                    Text(rounds).font(.system(size: 22, weight: .semibold))
                    Text(focused).font(.system(size: 12)).foregroundStyle(HubTheme.Palette.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 14)
            }
        }
        .padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HubTheme.Palette.card))
    }

    /// A switch bound to one of the focus settings. Takes a key path rather
    /// than a setter closure: the Command Line Tools' Swift 6.3 compiler
    /// crashes generating code for a main-actor closure passed into a Binding.
    private func toggle(_ title: String, _ icon: String, _ key: WritableKeyPath<Preferences.Focus, Bool> & Sendable) -> some View {
        Toggle(isOn: Binding(get: { focus.settings[keyPath: key] }, set: { on in focus.update { $0[keyPath: key] = on } })) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(HubTheme.Palette.secondary).frame(width: 18)
                Text(title).font(.system(size: 12)).lineLimit(1)
            }
        }
        .frame(height: compact ? 32 : 38)
    }
}

// MARK: - Timer settings

private struct FocusSettings: View {
    let focus: FocusStore
    let compact: Bool
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: back) {
                    HStack(spacing: 2) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(L10n.string("Timer")).font(.system(size: 12))
                    }
                    .foregroundStyle(HubTheme.Palette.soft)
                    .padding(.vertical, 5).padding(.leading, 6).padding(.trailing, 12)
                    .background(Capsule().fill(HubTheme.Palette.selected))
                    .contentShape(Capsule())
                }
                .buttonStyle(PressFade())
                Text(L10n.string("Timer settings")).font(.system(size: 13, weight: .semibold))
                Spacer()
            }
            .frame(height: 28)

            HStack(spacing: 10) {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        stepper(L10n.string("Focus"), L10n.string("Length of one round"), focus.settings.workMinutes, 5...90, 5, "min") { v in focus.update { $0.workMinutes = v } }
                        stepper(L10n.string("Short break"), L10n.string("Between rounds"), focus.settings.shortBreakMinutes, 1...30, 1, "min") { v in focus.update { $0.shortBreakMinutes = v } }
                        stepper(L10n.string("Long break"), L10n.string("After the last round"), focus.settings.longBreakMinutes, 5...60, 5, "min") { v in focus.update { $0.longBreakMinutes = v } }
                        stepper(L10n.string("Rounds"), L10n.string("Before a long break"), focus.settings.rounds, 1...12, 1, "") { v in focus.update { $0.rounds = v } }
                    }
                    .padding(.vertical, 8)
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HubTheme.Palette.card))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        Label(L10n.string("Do Not Disturb"), systemImage: "moon.fill").font(.system(size: 13))
                        Text(L10n.string("Run a Shortcut when a round starts and ends, for example one that turns a Focus on."))
                            .font(.system(size: 11)).foregroundStyle(HubTheme.Palette.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ShortcutPicker(title: L10n.string("When a round starts"), icon: "play.circle", names: focus.shortcutNames,
                                       value: focus.settings.startShortcut) { v in focus.update { $0.startShortcut = v } }
                        ShortcutPicker(title: L10n.string("When a round ends"), icon: "stop.circle", names: focus.shortcutNames,
                                       value: focus.settings.endShortcut) { v in focus.update { $0.endShortcut = v } }
                        if let problem = focus.shortcutProblem {
                            Text(problem).font(.system(size: 11)).foregroundStyle(HubTheme.Palette.danger)
                        }
                    }
                    .padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(HubTheme.Palette.card))
            }
        }
        .foregroundStyle(HubTheme.Palette.primary)
        .onAppear { focus.loadShortcutNames() }
    }

    private func stepper(_ title: String, _ hint: String, _ value: Int, _ range: ClosedRange<Int>, _ step: Int,
                         _ unit: String, set: @escaping (Int) -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if !compact { Text(hint).font(.system(size: 11)).foregroundStyle(HubTheme.Palette.tertiary) }
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                StepButton(symbol: "minus", enabled: value > range.lowerBound) { set(max(range.lowerBound, value - step)) }
                Text(unit.isEmpty ? "\(value)" : "\(value) \(unit)")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 62)
                StepButton(symbol: "plus", enabled: value < range.upperBound) { set(min(range.upperBound, value + step)) }
            }
            .padding(3)
            .background(Capsule().fill(HubTheme.Palette.selected))
        }
        .frame(height: compact ? 40 : 54)
    }
}

private struct StepButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(enabled ? HubTheme.Palette.soft : HubTheme.Palette.tertiary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(hovering && enabled ? HubTheme.Palette.segmentActive : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}

/// A Shortcut name: typed, or picked from the user's Shortcuts listed below
/// the field as it is typed into.
private struct ShortcutPicker: View {
    let title: String
    let icon: String
    let names: [String]
    let value: String
    let set: (String) -> Void
    @Environment(FormDrafts.self) private var drafts
    private var key: String { "focus.shortcut.\(title)" }
    private var text: String { drafts[key] }
    private var editing: Bool { drafts["\(key).editing"] == "1" }

    private var matches: [String] {
        guard editing else { return [] }
        let needle = text.trimmingCharacters(in: .whitespaces)
        let pool = needle.isEmpty ? names : names.filter { $0.localizedCaseInsensitiveContains(needle) && $0 != needle }
        return Array(pool.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11)).foregroundStyle(HubTheme.Palette.secondary)
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(HubTheme.Palette.secondary)
                TextField("", text: Binding(get: { drafts[key] }, set: { drafts[key] = $0; drafts["\(key).editing"] = "1" }),
                          prompt: Text(L10n.string("Shortcut name")).foregroundStyle(HubTheme.Palette.tertiary))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .onSubmit { commit(text) }
                if !text.isEmpty {
                    Button { commit("") } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(HubTheme.Palette.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(HubTheme.Palette.selected))
            if !matches.isEmpty {
                WrapLayout(spacing: 4) {
                    ForEach(matches, id: \.self) { name in GhostPill(title: name) { commit(name) } }
                }
            }
        }
        .onAppear { if !editing { drafts[key] = value } }
        .onChange(of: value) { _, new in if !editing { drafts[key] = new } }
    }

    private func commit(_ name: String) {
        drafts[key] = name
        drafts.clear("\(key).editing")
        set(name.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Closed notch

/// The closed notch while a round runs: a phase-coloured dot and mm:ss
/// either side of the camera, drawn only while visible.
struct FocusLiveView: View {
    let focus: FocusStore
    var gap: CGFloat = 150

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Circle().fill(focus.cycle.phase.color).frame(width: 7, height: 7)
                Spacer(minLength: gap)
                Text(FocusCycle.clock(focus.cycle.remaining(at: context.date, lengths: focus.lengths)))
                    .monospacedDigit()
            }
        }
        .font(HubTheme.Font.metaStrong)
        .foregroundStyle(HubTheme.Palette.primary)
        .padding(.horizontal, 14)
        .frame(maxHeight: .infinity)
    }
}
