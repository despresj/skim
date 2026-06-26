import SwiftUI

/// BYOK key management. The key lives in Keychain; this screen only ever shows a
/// mask. Copy is explicit that enabling checks may upload read text on paste.
struct AIFeaturesView: View {
    let service: ComprehensionService
    let settings: AISettings
    @Environment(\.dismiss) private var dismiss

    @State private var draftKey = ""
    @State private var status: String?
    @State private var testing = false
    @State private var showingConsent = false

    var body: some View {
        ZStack {
            ReadingCanvas()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("AI Comprehension Checks")
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.readingForeground)

                    Text("Use your own OpenAI API key to generate optional comprehension "
                        + "questions after a read. Your key is stored locally in iOS Keychain. "
                        + "Skim does not provide API credits. When AI comprehension checks are "
                        + "enabled, eligible pasted/imported reads may be sent to OpenAI in the "
                        + "background so questions are ready when you finish.")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.readingMuted)

                    Toggle("Enable comprehension checks", isOn: Binding(
                        get: { settings.enabled },
                        set: { turnedOn in
                            if turnedOn {
                                // Enabling is the consent moment: once accepted, every
                                // eligible paste pre-generates in the background (text may
                                // be sent to OpenAI on paste). Stay off until they accept.
                                if settings.consentAccepted { settings.enabled = true }
                                else { showingConsent = true }
                            } else {
                                settings.enabled = false
                            }
                        }))
                        .tint(Color.readingAccent)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Color.readingForeground)
                        .sheet(isPresented: $showingConsent) {
                            ComprehensionConsentView(
                                onContinue: {
                                    settings.consentAccepted = true
                                    settings.enabled = true
                                    showingConsent = false
                                },
                                onCancel: { showingConsent = false })
                        }

                    if let masked = service.maskedKey() {
                        HStack {
                            Text(masked).font(.system(size: 15, design: .monospaced))
                                .foregroundStyle(Color.readingForeground)
                            Spacer()
                            Button("Delete", role: .destructive) {
                                try? service.deleteKey(); status = "Key deleted."
                            }
                        }
                    } else {
                        SecureField("sk-…", text: $draftKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(size: 15, design: .monospaced))
                        HStack(spacing: 12) {
                            Button("Save Key") {
                                guard !draftKey.isEmpty else { return }
                                try? service.saveKey(draftKey); draftKey = ""; status = "Key saved."
                            }.buttonStyle(PrimaryPillStyle())
                            Button(testing ? "Testing…" : "Test Key") { Task { await test() } }
                                .buttonStyle(SecondaryPillStyle())
                                .disabled(testing || draftKey.isEmpty)
                        }
                    }

                    if let status { Text(status).font(.system(size: 13, design: .rounded))
                        .foregroundStyle(Color.readingMuted) }
                    Spacer(minLength: 0)
                }
                .padding(22)
            }
        }
        .presentationBackground { ReadingCanvas() }
    }

    /// Saves the draft key first (Test validates the configured model + request path).
    private func test() async {
        testing = true; defer { testing = false }
        if service.maskedKey() == nil, !draftKey.isEmpty { try? service.saveKey(draftKey) }
        switch await service.testKey() {
        case .success: status = "Key works."; draftKey = ""
        case .failure(let e): status = e.userMessage
        }
    }
}
