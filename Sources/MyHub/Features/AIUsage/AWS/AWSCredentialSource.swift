import Foundation

/// Where Bedrock's AWS credentials come from.
///
/// - `keychain`: access keys typed into MyHub, kept in its Keychain item as
///   JSON (`id`, `secret`, optional `token`).
/// - `profile`: a named profile in `~/.aws/credentials`, read-only, re-read on
///   each fetch. SSO and `credential_process` profiles are not supported yet.
enum AWSCredentialSource {
    static func keychain(account: String) throws -> AWSCredentials {
        guard let stored = try Keychain.secret(account: account),
              let object = try? JSONSerialization.jsonObject(with: Data(stored.exposed.utf8)) as? [String: String],
              let id = object["id"], let secret = object["secret"], !id.isEmpty, !secret.isEmpty else {
            throw UsageError.notConfigured(L10n.string("AWS access keys are missing — remove and add this source again."))
        }
        return AWSCredentials(accessKeyID: id, secret: Redacted(secret), sessionToken: object["token"].flatMap { $0.isEmpty ? nil : Redacted($0) })
    }

    static func encodeForKeychain(id: String, secret: String, token: String) -> Redacted<String> {
        let object = ["id": id, "secret": secret, "token": token]
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        return Redacted(String(decoding: data, as: UTF8.self))
    }

    static func profile(_ name: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> AWSCredentials {
        let aws = home.appendingPathComponent(".aws")
        let credentials = (try? String(contentsOf: aws.appendingPathComponent("credentials"), encoding: .utf8)).map(parseINI) ?? [:]
        let config = (try? String(contentsOf: aws.appendingPathComponent("config"), encoding: .utf8)).map(parseINI) ?? [:]
        if let section = credentials[name],
           let id = section["aws_access_key_id"], let secret = section["aws_secret_access_key"] {
            return AWSCredentials(accessKeyID: id, secret: Redacted(secret), sessionToken: section["aws_session_token"].map(Redacted.init))
        }
        let configSection = config[name == "default" ? "default" : "profile \(name)"] ?? [:]
        if configSection.keys.contains(where: { $0.hasPrefix("sso_") || $0 == "credential_process" || $0 == "role_arn" }) {
            throw UsageError.notConfigured(L10n.format("Profile “%@” uses SSO, a role or credential_process, which MyHub cannot use yet. Use access keys instead.", name))
        }
        throw UsageError.notConfigured(L10n.format("No access keys for profile “%@” in ~/.aws/credentials.", name))
    }

    /// `[section]` headers and `key = value` lines; `#`/`;` comments.
    static func parseINI(_ text: String) -> [String: [String: String]] {
        var sections: [String: [String: String]] = [:]
        var current: String?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                current = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let current, let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            sections[current, default: [:]][key] = value
        }
        return sections
    }
}
