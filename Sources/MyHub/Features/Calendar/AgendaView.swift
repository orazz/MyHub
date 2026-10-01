import AppKit
import SwiftUI

/// Calendar, per the handoff: a date card with the week strip on the left;
/// the next event (with Join) and the agenda for today and the next working
/// day on the right.
struct AgendaView: View {
    let agenda: AgendaStore
    let shield: ContentShield
    /// A larger panel has room for the rest of the week, not just today and
    /// the next working day.
    var roomy = false

    var body: some View {
        switch agenda.hasSource ? .granted : agenda.access {
        case .notDetermined:
            AccessCard(
                symbol: "calendar",
                text: L10n.string("See your next meetings and join calls from the notch. Events are read on this Mac and never leave it."),
                button: L10n.string("Allow Calendar Access"),
                action: agenda.requestAccess,
                microsoft: agenda.microsoft
            )
        case .denied:
            AccessCard(
                symbol: "calendar.badge.exclamationmark",
                text: L10n.string("Calendar access is off. Turn on MyHub in Privacy & Security → Calendars."),
                button: L10n.string("Open Privacy Settings"),
                action: agenda.openPrivacySettings,
                microsoft: agenda.microsoft
            )
        case .granted:
            HStack(spacing: 12) {
                DateCard(now: agenda.now, agenda: agenda).frame(width: 176)
                VStack(spacing: 6) {
                    if let next = agenda.next {
                        NextEventCard(meeting: next, agenda: agenda, shield: shield)
                    }
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            ForEach(roomy ? agenda.upcoming : agenda.agenda) { AgendaRow(meeting: $0, now: agenda.now, shield: shield) }
                        }
                    }
                    if agenda.next == nil {
                        if agenda.isLoading {
                            EmptyPaneHint(symbol: "calendar", text: L10n.string("Loading…"))
                        } else {
                            NothingAhead(agenda: agenda)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

/// No timed events in the next seven days. Says which calendars were read,
/// because the usual reason is a calendar this Mac does not have: Google,
/// Outlook / Microsoft 365 (Teams meetings) and others reach EventKit only
/// once their account is added in System Settings → Internet Accounts.
private struct NothingAhead: View {
    let agenda: AgendaStore

    private var sourcesText: String {
        var parts: [String] = []
        if agenda.access == .granted {
            parts.append(L10n.format("Read %d calendars on this Mac.", agenda.calendars.count))
        }
        if agenda.microsoft.isConnected { parts.append(L10n.string("Microsoft 365 is connected.")) }
        parts.append(L10n.string("All-day events are not shown."))
        if !agenda.microsoft.isConnected {
            parts.append(Features.microsoftCalendar
                ? L10n.string("Teams and Outlook meetings: connect Microsoft 365 (Settings → Calendar), or add the account to this Mac.")
                : L10n.string("Google, Outlook and Teams calendars appear once their account is added to this Mac."))
        }
        return parts.joined(separator: " ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("No meetings in the next 7 days"))
                .font(HubTheme.Font.bodyStrong)
            Text(sourcesText)
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                if agenda.access == .granted {
                    GhostPill(title: L10n.string("Internet Accounts"), symbol: "at") { agenda.openInternetAccounts() }
                    GhostPill(title: L10n.string("Calendar"), symbol: "calendar") { agenda.openCalendarApp() }
                }
                MicrosoftButton(microsoft: agenda.microsoft)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.top, 4)
        .padding(.horizontal, 4)
    }
}

private struct AccessCard: View {
    let symbol: String
    let text: String
    let button: String
    let action: () -> Void
    let microsoft: MicrosoftCalendarStore

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: HubTheme.Radius.card, style: .continuous)
                .fill(HubTheme.Palette.accent.opacity(0.14))
                .frame(width: 52, height: 52)
                .overlay(Image(systemName: symbol).font(.system(size: 24)).foregroundStyle(HubTheme.Palette.accentLight))
            Text(text)
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.soft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Button(button, action: action).buttonStyle(LightCapsuleButtonStyle())
                MicrosoftButton(microsoft: microsoft)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .hubCard()
    }
}

/// "Microsoft 365" sign-in, wherever the Calendar tab has room for it. Shown
/// once an Application ID is set in Settings; hidden while connected.
struct MicrosoftButton: View {
    let microsoft: MicrosoftCalendarStore

    var body: some View {
        switch microsoft.state {
        case .notConfigured, .connected:
            EmptyView()
        case .signingIn:
            GhostPill(title: L10n.string("Waiting for the browser… Cancel"), symbol: "xmark") { microsoft.cancelSignIn() }
        case .disconnected, .expired:
            GhostPill(title: microsoft.state == .expired ? L10n.string("Reconnect Microsoft 365") : L10n.string("Microsoft 365 / Teams"),
                      symbol: "person.badge.key") { microsoft.connect() }
        }
    }
}

private struct DateCard: View {
    let now: Date
    let agenda: AgendaStore
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(now.formatted(.dateTime.weekday(.wide)))
                        .font(HubTheme.Font.body)
                        .foregroundStyle(HubTheme.Palette.secondary)
                    Text(now.formatted(.dateTime.month(.abbreviated).day()))
                        .font(HubTheme.Font.calendarDate)
                        .foregroundStyle(HubTheme.Palette.primary)
                }
                Spacer(minLength: 0)
                if hovering {
                    Button(action: showCalendarMenu) { Image(systemName: "line.3.horizontal.decrease") }
                        .buttonStyle(HubIconButtonStyle(size: 22, filled: true))
                        .help(L10n.string("Calendars to show"))
                }
            }
            Spacer(minLength: 0)
            let days = AgendaFormat.week(of: now)
            Grid(horizontalSpacing: 2, verticalSpacing: 2) {
                GridRow {
                    ForEach(days) { day in
                        Text(day.letter).font(HubTheme.Font.axis).foregroundStyle(HubTheme.Palette.tertiary).frame(maxWidth: .infinity)
                    }
                }
                GridRow {
                    ForEach(days) { day in
                        Text("\(day.number)")
                            .font(.system(size: 11, weight: day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? HubTheme.Palette.onLight : day.isWeekend ? HubTheme.Palette.tertiary : HubTheme.Palette.soft)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(day.isToday ? HubTheme.Palette.accent : .clear))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .hubCard()
        .onHover { hovering = $0 }
    }

    private func showCalendarMenu() {
        let menu = NSMenu()
        var lastSource: String?
        for calendar in agenda.calendars {
            if calendar.source != lastSource {
                if lastSource != nil { menu.addItem(.separator()) }
                let header = NSMenuItem(title: calendar.source, action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                lastSource = calendar.source
            }
            let shown = agenda.isShown(calendar.id)
            let item = ActionMenuItem(calendar.title) { agenda.setShown(!shown, calendarID: calendar.id) }
            item.state = shown ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

private struct NextEventCard: View {
    let meeting: Meeting
    let agenda: AgendaStore
    let shield: ContentShield

    private var hidden: Bool { shield.masks(meeting.id, in: .calendar) }

    private var subtitle: String {
        var parts: [String] = []
        if meeting.link != nil { parts.append(meeting.provider.map { L10n.format("%@ call", $0) } ?? L10n.string("Video call")) }
        else if let location = meeting.location { parts.append(location) }
        if meeting.attendees > 1 { parts.append(L10n.format("%d people", meeting.attendees)) }
        if parts.isEmpty { parts.append(meeting.calendarTitle) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AgendaFormat.nextLine(meeting, now: agenda.now))
                    .font(HubTheme.Font.metaStrong)
                    .foregroundStyle(HubTheme.Palette.accentLight)
                    .monospacedDigit()
                ShieldedText(text: meeting.title, hidden: hidden, font: HubTheme.Font.eventTitle)
                ShieldedText(text: subtitle, hidden: hidden, font: HubTheme.Font.meta, color: HubTheme.Palette.secondary)
            }
            if shield.isShielded(.calendar) {
                RevealButton(hidden: hidden) { shield.togglePeek(meeting.id) }
            }
            if meeting.link != nil {
                Button(L10n.string("Join")) { agenda.join(meeting) }
                    .buttonStyle(LightCapsuleButtonStyle())
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: HubTheme.Radius.eventCard, style: .continuous).fill(HubTheme.Palette.accent.opacity(0.10)))
    }
}

private struct AgendaRow: View {
    let meeting: Meeting
    let now: Date
    let shield: ContentShield

    var body: some View {
        let hidden = shield.masks(meeting.id, in: .calendar)
        let today = Calendar.current.isDate(meeting.start, inSameDayAs: now)
        HStack(spacing: 10) {
            Text(meeting.start.formatted(date: .omitted, time: .shortened))
                .font(HubTheme.Font.body)
                .foregroundStyle(HubTheme.Palette.secondary)
                .monospacedDigit()
                .frame(width: 40, alignment: .leading)
            Circle().fill(meeting.color.swiftUI).frame(width: 6, height: 6)
            if hidden {
                ShieldedText(text: meeting.title, hidden: true)
            } else {
                (Text(meeting.title).foregroundStyle(HubTheme.Palette.primary)
                 + Text(today ? "" : " · " + AgendaFormat.dayTitle(meeting.start, now: now).lowercased()).foregroundStyle(HubTheme.Palette.tertiary))
                    .font(HubTheme.Font.body)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text(AgendaFormat.shortDuration(meeting.end.timeIntervalSince(meeting.start)))
                .font(HubTheme.Font.meta)
                .foregroundStyle(HubTheme.Palette.tertiary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
    }
}

extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
}
