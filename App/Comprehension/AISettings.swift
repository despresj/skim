import Foundation
import Observation

/// The three AI-feature preferences, persisted in UserDefaults (never the key —
/// that's Keychain). Shared by Settings UI and the comprehension service.
@MainActor @Observable final class AISettings {
    var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "skim.ai.enabled") }
    }
    var consentAccepted: Bool {
        didSet { UserDefaults.standard.set(consentAccepted, forKey: "skim.ai.consent") }
    }
    var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "skim.ai.model") }
    }

    init() {
        enabled = UserDefaults.standard.bool(forKey: "skim.ai.enabled")
        consentAccepted = UserDefaults.standard.bool(forKey: "skim.ai.consent")
        model = UserDefaults.standard.string(forKey: "skim.ai.model") ?? OpenAIComprehensionProvider.defaultModel
    }
}
