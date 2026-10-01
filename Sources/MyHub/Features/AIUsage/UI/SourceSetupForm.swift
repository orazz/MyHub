import SwiftUI

/// The form for a key-based source. Keys go straight from the secure field
/// into the Keychain on Save; nothing here echoes them back.
struct SourceSetupForm: View {
    let usage: UsageStore
    let session: ScreenSession
    let onFormActive: (Bool) -> Void
    @FocusState private var focused: Bool

    private var draft: SourceDraft { usage.draft ?? SourceDraft(kind: .custom) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: draft.kind.symbol).font(.system(size: 11, weight: .semibold))
                Text(draft.kind.title).font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .foregroundStyle(HubTheme.Palette.primary)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(draft.kind.explanation)
                        .font(.system(size: 9.5))
                        .foregroundStyle(HubTheme.Palette.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    FormRow(L10n.string("Name")) { field(\.label, focus: true) }
                    fields
                }
            }

            HStack(spacing: 8) {
                if let message = usage.draftError ?? draft.warning {
                    Label(message, systemImage: usage.draftError == nil ? "info.circle" : "exclamationmark.triangle")
                        .font(.system(size: 9.5))
                        .foregroundStyle(usage.draftError == nil ? HubTheme.Palette.tertiary : HubTheme.Palette.warn)
                        .lineLimit(2)
                }
                Spacer()
                Button(L10n.string("Cancel")) { usage.cancelDraft() }
                Button(L10n.string("Save")) { usage.saveDraft() }
            }
            .buttonStyle(HubTextButtonStyle())
        }
        .onAppear {
            onFormActive(true)
            session.wantsKeyboard = true
        }
        .onDisappear { onFormActive(false) }
        .onKeyPress(.escape) {
            session.wantsKeyboard = false
            return .handled
        }
    }

    @ViewBuilder
    private var fields: some View {
        switch draft.kind {
        case .anthropicAdmin:
            FormRow(L10n.string("Admin key")) { secure(\.secret, prompt: "sk-ant-admin01-…") }
        case .openAIAdmin:
            FormRow(L10n.string("Admin key")) { secure(\.secret, prompt: "sk-admin-…") }
        case .openRouter:
            FormRow(L10n.string("API key")) { secure(\.secret, prompt: "sk-or-v1-…") }
        case .bedrock:
            FormRow(L10n.string("Region")) { field(\.region) }
            FormRow(L10n.string("Credentials")) {
                Segmented(options: [(false, L10n.string("Access keys")), (true, L10n.string("AWS profile"))],
                          selection: flag(\.useProfile))
            }
            if draft.useProfile {
                FormRow(L10n.string("Profile")) { field(\.profile, prompt: "default") }
            } else {
                FormRow(L10n.string("Access key ID")) { field(\.accessKeyID, prompt: "AKIA…") }
                FormRow(L10n.string("Secret key")) { secure(\.secret) }
                FormRow(L10n.string("Session token")) { secure(\.sessionToken, prompt: L10n.string("optional")) }
            }
            Toggle(L10n.string("Include monthly cost (Cost Explorer)"), isOn: flag(\.includeCost))
                .toggleStyle(HubToggleStyle())
                .font(HubTheme.Font.caption)
        case .custom:
            FormRow(L10n.string("Type")) {
                Segmented(options: [(CustomEndpointConfig.Preset.litellm, "LiteLLM"), (.generic, L10n.string("Any JSON"))],
                          selection: Binding(get: { draft.preset }, set: { usage.draft?.preset = $0 }))
            }
            FormRow(draft.preset == .litellm ? L10n.string("Proxy URL") : L10n.string("URL")) {
                field(\.url, prompt: draft.preset == .litellm ? "https://litellm.example.com" : "https://…")
            }
            FormRow(L10n.string("Key")) { secure(\.secret, prompt: L10n.string("optional")) }
            if draft.preset == .generic {
                FormRow(L10n.string("Auth header")) { field(\.authHeader) }
                Toggle(L10n.string("Send as “Bearer <key>”"), isOn: flag(\.bearer))
                    .toggleStyle(HubToggleStyle()).font(HubTheme.Font.caption)
                FormRow(L10n.string("Percent used")) { field(\.percentPath, prompt: "e.g. usage.percent") }
                FormRow(L10n.string("Used")) { field(\.usedPath, prompt: "e.g. data.spend") }
                FormRow(L10n.string("Limit")) { field(\.limitPath, prompt: "e.g. data.budget") }
                FormRow(L10n.string("Spend")) { field(\.spendPath, prompt: "e.g. data.spend") }
                FormRow(L10n.string("Resets at")) { field(\.resetPath, prompt: L10n.string("optional")) }
                FormRow(L10n.string("Currency")) { field(\.currency) }
            }
        case .claudePlan, .claudeLogs, .codexPlan, .codexLogs:
            EmptyView()
        }
    }

    // MARK: - Bindings into the store's draft

    private func text(_ key: WritableKeyPath<SourceDraft, String>) -> Binding<String> {
        Binding(get: { usage.draft?[keyPath: key] ?? "" }, set: { usage.draft?[keyPath: key] = $0 })
    }

    private func flag(_ key: WritableKeyPath<SourceDraft, Bool>) -> Binding<Bool> {
        Binding(get: { usage.draft?[keyPath: key] ?? false }, set: { usage.draft?[keyPath: key] = $0 })
    }

    private func field(_ key: WritableKeyPath<SourceDraft, String>, prompt: String = "", focus: Bool = false) -> some View {
        TextField("", text: text(key), prompt: Text(prompt).foregroundStyle(HubTheme.Palette.tertiary))
            .textFieldStyle(.plain)
            .autocorrectionDisabled()
            .focused($focused, equals: focus)
            .inputFieldChrome()
    }

    private func secure(_ key: WritableKeyPath<SourceDraft, String>, prompt: String = "") -> some View {
        SecureField("", text: text(key), prompt: Text(prompt).foregroundStyle(HubTheme.Palette.tertiary))
            .textFieldStyle(.plain)
            .inputFieldChrome()
    }
}

private struct FormRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(HubTheme.Font.caption)
                .foregroundStyle(HubTheme.Palette.secondary)
                .frame(width: 92, alignment: .leading)
            content
        }
    }
}

/// A two-way choice drawn by hand (a system segmented control greys out in a
/// non-key window, like `NSSwitch`).
private struct Segmented<Value: Equatable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let (value, title) = options[index]
                Button(title) { selection = value }
                    .buttonStyle(.plain)
                    .font(HubTheme.Font.caption)
                    .padding(.horizontal, 9)
                    .frame(height: 20)
                    .background(Capsule().fill(selection == value ? HubTheme.Palette.surfaceSelected : .clear))
                    .foregroundStyle(selection == value ? HubTheme.Palette.primary : HubTheme.Palette.secondary)
            }
        }
        .padding(2)
        .background(Capsule().fill(HubTheme.Palette.surface))
    }
}

private extension View {
    func inputFieldChrome() -> some View {
        font(HubTheme.Font.caption)
            .foregroundStyle(HubTheme.Palette.primary)
            .padding(.horizontal, 7)
            .frame(height: 21)
            .background(RoundedRectangle(cornerRadius: 5).fill(HubTheme.Palette.surface))
    }
}
