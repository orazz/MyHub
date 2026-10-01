import Foundation

/// A source being set up: what the form holds before it becomes an account.
///
/// Lives in `UsageStore`, not in the view, so a key pasted into the form
/// survives the island folding when the pointer drifts away. The secret
/// fields leave memory as soon as the draft is saved (into the Keychain) or
/// cancelled.
struct SourceDraft: Equatable, Sendable {
    var kind: ProviderKind
    var label: String
    /// API key, or the AWS secret access key.
    var secret = ""
    var accessKeyID = ""
    var sessionToken = ""
    var region = "us-east-1"
    var useProfile = false
    var profile = "default"
    var includeCost = false
    var preset: CustomEndpointConfig.Preset = .litellm
    var url = ""
    var authHeader = "Authorization"
    var bearer = true
    var percentPath = ""
    var usedPath = ""
    var limitPath = ""
    var spendPath = ""
    var resetPath = ""
    var currency = "USD"

    init(kind: ProviderKind) {
        self.kind = kind
        self.label = kind.title
    }

    private func blank(_ text: String) -> Bool { text.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Why it cannot be saved yet, or nil.
    var problem: String? {
        switch kind {
        case .anthropicAdmin, .openAIAdmin, .openRouter:
            return blank(secret) ? L10n.string("Paste the key.") : nil
        case .bedrock:
            if !BedrockProvider.isValidRegion(region.trimmingCharacters(in: .whitespaces)) { return L10n.string("Enter a region such as us-east-1.") }
            if useProfile { return blank(profile) ? L10n.string("Enter the profile name.") : nil }
            return blank(accessKeyID) || blank(secret) ? L10n.string("Enter the access key ID and secret.") : nil
        case .custom:
            guard customConfig.client != nil else { return L10n.string("Enter an HTTPS URL (plain HTTP only for localhost).") }
            if preset == .generic, blank(percentPath), blank(spendPath), blank(usedPath) || blank(limitPath) {
                return L10n.string("Map at least one field: percent, spend, or used + limit.")
            }
            return nil
        case .claudePlan, .claudeLogs, .codexPlan, .codexLogs:
            return nil
        }
    }

    /// Saved anyway, but worth saying.
    var warning: String? {
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .anthropicAdmin where !key.isEmpty && !key.hasPrefix("sk-ant-admin"):
            return L10n.string("This doesn't look like an Admin key (sk-ant-admin…). Regular API keys can't read usage.")
        case .openAIAdmin where !key.isEmpty && !key.hasPrefix("sk-admin"):
            return L10n.string("This doesn't look like an Admin key (sk-admin-…). Project keys can't read organisation costs.")
        case .bedrock where includeCost:
            return L10n.string("Cost Explorer charges $0.01 per request; MyHub asks at most once an hour.")
        default:
            return nil
        }
    }

    var customConfig: CustomEndpointConfig {
        let trimmedURL = url.trimmingCharacters(in: .whitespaces)
        if preset == .litellm { return .litellm(baseURL: trimmedURL) }
        var config = CustomEndpointConfig()
        config.preset = .generic
        config.url = trimmedURL
        config.authHeader = authHeader.trimmingCharacters(in: .whitespaces)
        config.bearer = bearer
        config.percentPath = percentPath
        config.usedPath = usedPath
        config.limitPath = limitPath
        config.spendPath = spendPath
        config.resetPath = resetPath
        config.currency = currency.trimmingCharacters(in: .whitespaces).uppercased()
        return config
    }

    /// Non-secret settings, stored in preferences.json.
    var options: [String: String] {
        switch kind {
        case .bedrock:
            return ["region": region.trimmingCharacters(in: .whitespaces),
                    "credentials": useProfile ? "profile" : "keychain",
                    "profile": profile.trimmingCharacters(in: .whitespaces),
                    "cost": includeCost ? "on" : "off"]
        case .custom:
            return customConfig.options
        default:
            return [:]
        }
    }

    /// What goes into the Keychain, if anything.
    var secretToStore: Redacted<String>? {
        let key = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .anthropicAdmin, .openAIAdmin, .openRouter:
            return Redacted(key)
        case .bedrock:
            return useProfile ? nil : AWSCredentialSource.encodeForKeychain(
                id: accessKeyID.trimmingCharacters(in: .whitespaces), secret: key,
                token: sessionToken.trimmingCharacters(in: .whitespacesAndNewlines))
        case .custom:
            return key.isEmpty ? nil : Redacted(key)
        case .claudePlan, .claudeLogs, .codexPlan, .codexLogs:
            return nil
        }
    }
}
