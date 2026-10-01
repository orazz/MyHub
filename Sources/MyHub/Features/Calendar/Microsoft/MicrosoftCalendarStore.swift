import AppKit
import Observation

/// The Microsoft 365 connection behind the Calendar tab: sign-in, the token,
/// and the next week of events.
///
/// Read when the Calendar tab is shown (at most every two minutes) and every
/// five minutes while the panel stays open. Never in the background.
@MainActor
@Observable
final class MicrosoftCalendarStore {
    enum State: Equatable {
        case notConfigured
        case disconnected
        case signingIn
        /// The refresh token stopped working (revoked, password changed, the
        /// tenant's policy): sign in again.
        case expired
        case connected
    }

    private(set) var state: State
    private(set) var meetings: [Meeting] = []
    private(set) var problem: String?
    private(set) var lastSynced: Date?

    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private var access: (token: Redacted<String>, expires: Date)?
    @ObservationIgnored private var signIn: Task<Void, Never>?
    @ObservationIgnored private var redirect: LoopbackRedirect?
    @ObservationIgnored private var loading: Task<Void, Never>?

    init(preferences: Preferences) {
        self.preferences = preferences
        guard Features.microsoftCalendar else {
            state = .notConfigured
            return
        }
        let hasToken = (try? Keychain.secret(account: MicrosoftAuth.refreshTokenAccount)) != nil
        state = preferences.values.microsoft.clientID.isEmpty ? .notConfigured : (hasToken ? .connected : .disconnected)
    }

    var clientID: String { preferences.values.microsoft.clientID }
    var account: String { preferences.values.microsoft.account }
    var isConnected: Bool { state == .connected }

    /// The Application (client) ID from the app registration. It is not a
    /// secret; it names the app to Microsoft.
    func setClientID(_ id: String) {
        guard Features.microsoftCalendar else { return }
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty || UUID(uuidString: trimmed) != nil else {
            problem = L10n.string("The Application (client) ID looks like 00000000-0000-0000-0000-000000000000.")
            return
        }
        problem = nil
        if trimmed != clientID { disconnect() }
        preferences.update { $0.microsoft.clientID = trimmed }
        state = trimmed.isEmpty ? .notConfigured : (state == .notConfigured ? .disconnected : state)
    }

    // MARK: - Signing in

    /// Opens Microsoft's sign-in page in the default browser and waits for
    /// the answer on a loopback port. Five minutes, then it gives up.
    func connect() {
        guard Features.microsoftCalendar, !clientID.isEmpty else { return }
        signIn?.cancel()
        redirect?.cancel()
        problem = nil
        state = .signingIn
        let clientID = clientID
        signIn = Task { [weak self] in
            do {
                let redirect = try await LoopbackRedirect.start()
                self?.redirect = redirect
                let pkce = MicrosoftAuth.PKCE()
                let stateToken = UUID().uuidString
                guard let url = MicrosoftAuth.authorizeURL(clientID: clientID, redirect: redirect.redirectURI, pkce: pkce, state: stateToken)
                else { throw UsageError.refused("bad URL") }
                NSWorkspace.shared.open(url)
                let query = try await redirect.waitForCallback()
                let code = try MicrosoftAuth.code(fromCallbackQuery: query, expectedState: stateToken)
                let tokens = try await MicrosoftAuth.requestTokens(clientID: clientID, grant: [
                    "grant_type": "authorization_code", "code": code,
                    "redirect_uri": redirect.redirectURI, "code_verifier": pkce.verifier,
                ])
                guard let self, !Task.isCancelled else { return }
                try store(tokens)
                state = .connected
                NSApp.activate()  // back from the browser
                await loadAccount()
                await reload()
            } catch is CancellationError {
                if self?.state == .signingIn { self?.state = .disconnected }
            } catch {
                guard let self else { return }
                state = .disconnected
                problem = Self.describe(error)
            }
        }
    }

    func cancelSignIn() {
        signIn?.cancel()
        redirect?.cancel()
        state = .disconnected
    }

    func disconnect() {
        signIn?.cancel()
        try? Keychain.remove(account: MicrosoftAuth.refreshTokenAccount)
        access = nil
        meetings = []
        lastSynced = nil
        preferences.update { $0.microsoft.account = "" }
        if state != .notConfigured { state = .disconnected }
    }

    private func store(_ tokens: MicrosoftAuth.Tokens) throws {
        access = (tokens.access, tokens.expires)
        // Microsoft rotates refresh tokens; keep the newest.
        if let refresh = tokens.refresh {
            try Keychain.store(refresh, account: MicrosoftAuth.refreshTokenAccount)
        }
    }

    /// A valid access token, refreshing it when it has expired.
    private func accessToken() async throws -> Redacted<String> {
        if let access, access.expires > Date() { return access.token }
        guard let refresh = try Keychain.secret(account: MicrosoftAuth.refreshTokenAccount) else { throw UsageError.unauthorized }
        do {
            let tokens = try await MicrosoftAuth.requestTokens(clientID: clientID, grant: [
                "grant_type": "refresh_token", "refresh_token": refresh.exposed,
            ])
            try store(tokens)
            return tokens.access
        } catch UsageError.server(400, _) {
            // invalid_grant: the refresh token is no longer accepted.
            throw UsageError.unauthorized
        }
    }

    // MARK: - Loading

    func refreshIfStale() {
        guard state == .connected else { return }
        if let lastSynced, Date().timeIntervalSince(lastSynced) < 120 { return }
        loading?.cancel()
        loading = Task { [weak self] in await self?.reload() }
    }

    func reload() async {
        guard state == .connected else { return }
        do {
            let token = try await accessToken()
            let http = HTTPClient(allowedHosts: MicrosoftAuth.hosts)
            let headers = ["Authorization": "Bearer \(token.exposed)", "Prefer": "outlook.timezone=\"UTC\""]
            let now = Date()
            var next = MicrosoftCalendar.calendarViewURL(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(AgendaStore.horizon))
            var found: [Meeting] = []
            var pages = 0
            while let url = next, pages < 5 {
                let page = try MicrosoftCalendar.page(from: try await http.get(url, headers: headers))
                found += page.meetings
                next = page.next
                pages += 1
            }
            guard !Task.isCancelled else { return }
            meetings = found
            lastSynced = Date()
            problem = nil
            if account.isEmpty { await loadAccount() }
        } catch UsageError.unauthorized {
            access = nil
            state = .expired
            meetings = []
        } catch {
            problem = Self.describe(error)
        }
    }

    private func loadAccount() async {
        guard let token = try? await accessToken(), let url = URL(string: "https://graph.microsoft.com/v1.0/me?$select=displayName,mail,userPrincipalName"),
              let data = try? await HTTPClient(allowedHosts: MicrosoftAuth.hosts).get(url, headers: ["Authorization": "Bearer \(token.exposed)"]),
              let name = try? MicrosoftCalendar.account(from: data) else { return }
        preferences.update { $0.microsoft.account = name }
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case MicrosoftAuth.CallbackError.denied(let reason): String(reason.prefix(200))
        case MicrosoftAuth.CallbackError.stateMismatch: L10n.string("The sign-in answer didn't match this request. Try again.")
        case UsageError.server(_, let message): message
        case UsageError.unauthorized: L10n.string("Microsoft didn't accept the sign-in. Try again.")
        case UsageError.network: L10n.string("Microsoft could not be reached.")
        default: L10n.string("Signing in to Microsoft failed.")
        }
    }

    #if DEBUG
    func injectForPreview(_ meetings: [Meeting], account: String) {
        state = .connected
        self.meetings = meetings
        preferences.update { $0.microsoft.account = account }
    }
    #endif
}
