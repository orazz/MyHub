import AppKit
import EventKit
import Observation

/// Upcoming meetings for the next week, and the link that joins the next one.
///
/// Permission is asked for only from the button inside the Calendar section,
/// after the pane has said why. Opening the section merely re-checks the
/// status. Changes to events arrive through `EKEventStoreChanged` at any time;
/// the half-minute clock that keeps the countdown honest runs only while the
/// island is open.
@MainActor
@Observable
final class AgendaStore {
    typealias Access = CalendarSource.Access

    private(set) var access: Access = CalendarSource.access
    private(set) var meetings: [Meeting] = []
    private(set) var calendars: [CalendarInfo] = []
    private(set) var now = Date()
    private(set) var isLoading = false

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let source = CalendarSource()
    /// Microsoft 365 / Teams, read through Microsoft Graph.
    let microsoft: MicrosoftCalendarStore
    @ObservationIgnored private var storeWatch: Task<Void, Never>?
    @ObservationIgnored private let clock = Ticker()
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var isRunning = false

    static let horizon: TimeInterval = 7 * 24 * 3600

    init(preferences: Preferences) {
        self.preferences = preferences
        microsoft = MicrosoftCalendarStore(preferences: preferences)
    }

    /// Something to read meetings from: this Mac's calendars, Microsoft 365,
    /// or both.
    var hasSource: Bool { access == .granted || microsoft.isConnected }

    /// Meetings not yet over, soonest first. Filtered rather than trimmed at
    /// the front: a long meeting can still run after a later short one ends.
    private var live: [Meeting] {
        MicrosoftCalendar.merge(access == .granted ? meetings : [], microsoft.meetings).filter { $0.end > now }
    }

    var next: Meeting? { live.first }

    /// Everything after `next`.
    var upcoming: [Meeting] { Array(live.dropFirst()) }

    /// The agenda under the next-event card: the rest of today and the next
    /// working day.
    var agenda: [Meeting] {
        let calendar = Calendar.current
        let workday = AgendaFormat.nextWorkday(after: now)
        return upcoming.filter { calendar.isDate($0.start, inSameDayAs: now) || calendar.isDate($0.start, inSameDayAs: workday) }
    }

    // MARK: - Lifecycle

    func start() {
        isRunning = true
        access = CalendarSource.access
        guard access == .granted else { return }
        observe()
        reload()
    }

    func stop() {
        isRunning = false
        clock.halt()
        reloadTask?.cancel()
        storeWatch?.cancel()
        storeWatch = nil
    }

    func setActive(_ active: Bool) {
        isActive = active
        guard active, hasSource else { return clock.halt() }
        tick()
        startClock()
    }

    /// The section came into view. Never prompts.
    func refreshAccess() {
        microsoft.refreshIfStale()
        let current = CalendarSource.access
        let changed = current != access
        access = current
        guard current == .granted else { return }
        observe()
        if changed || meetings.isEmpty { reload() }
        if isActive { startClock() }
    }

    func requestAccess() {
        guard CalendarSource.access == .notDetermined else { return refreshAccess() }
        Task { [weak self, source] in
            let granted = await source.requestAccess()
            guard let self else { return }
            access = granted ? .granted : .denied
            if granted { refreshAccess(); reload() }
        }
    }

    // MARK: - Loading

    func reload() {
        guard access == .granted, isRunning else { return }
        reloadTask?.cancel()
        let hidden = Set(preferences.values.calendar.hiddenCalendarIDs)
        isLoading = meetings.isEmpty
        reloadTask = Task { [weak self, source] in
            let start = Date()
            async let allCalendars = source.calendars()
            let found = await source.meetings(from: start, to: start.addingTimeInterval(Self.horizon), hiddenCalendars: hidden)
            let calendars = await allCalendars
            guard let self, !Task.isCancelled else { return }
            self.meetings = found
            self.calendars = calendars
            self.now = Date()
            self.isLoading = false
        }
    }

    /// Any edit in any calendar app, or a sync from a server, posts one
    /// change notice; the agenda is simply fetched again.
    private func observe() {
        guard storeWatch == nil else { return }
        storeWatch = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged).map({ _ in () }) {
                self?.reload()
            }
        }
    }

    /// The countdown on the next-meeting card is in minutes, so a tick every
    /// half minute is plenty, and it may drift.
    private func startClock() {
        guard !clock.isRunning else { return }
        clock.run(every: 30, slack: 0.2) { [weak self] in self?.tick() }
    }

    private func tick() {
        now = Date()
        // Microsoft has no change notice to listen to; every five minutes
        // while the panel is open is enough for a meeting list.
        if let synced = microsoft.lastSynced, now.timeIntervalSince(synced) > 300 { microsoft.refreshIfStale() }
        let current = live
        if current.count != meetings.count { meetings = current }
    }

    // MARK: - Calendars shown

    func isShown(_ calendarID: String) -> Bool {
        !preferences.values.calendar.hiddenCalendarIDs.contains(calendarID)
    }

    func setShown(_ shown: Bool, calendarID: String) {
        preferences.update { values in
            values.calendar.hiddenCalendarIDs.removeAll { $0 == calendarID }
            if !shown { values.calendar.hiddenCalendarIDs.append(calendarID) }
        }
        reload()
    }

    // MARK: - Actions

    /// The link is vetted again here, at the moment it is opened.
    func join(_ meeting: Meeting) {
        if let link = meeting.link, CallLinkDetector.isJoinable(link) {
            NSWorkspace.shared.open(link)
        }
    }

    func openCalendarApp() {
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Where Google, Microsoft 365 / Exchange (Teams) and other calendar
    /// accounts are added so EventKit — and so MyHub — can read them.
    func openInternetAccounts() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    #if DEBUG
    /// Previews and snapshots only.
    func injectForPreview(_ meetings: [Meeting], now: Date) {
        access = .granted
        self.meetings = meetings
        self.now = now
    }
    #endif
}
