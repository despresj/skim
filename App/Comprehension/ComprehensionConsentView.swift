import SwiftUI

/// Shown once, on the first manual "Check understanding" tap — never during
/// paste/import. Explicit that enabling pre-gen means read text leaves the device.
struct ComprehensionConsentView: View {
    let onContinue: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            ReadingCanvas()
            VStack(alignment: .leading, spacing: 18) {
                Text("Comprehension checks")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.readingForeground)
                Text("Comprehension checks send this read's text to OpenAI using your API key. "
                    + "Because pre-generation runs when you load text, the text may be sent as "
                    + "soon as you paste or import it — not only when you open a check. Your key "
                    + "is stored locally in iOS Keychain. Skim does not provide API credits. You "
                    + "can delete your key anytime in Settings.")
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(Color.readingMuted)
                VStack(spacing: 12) {
                    Button("Continue") { onContinue() }.buttonStyle(PrimaryPillStyle())
                    Button("Cancel") { onCancel() }.buttonStyle(SecondaryPillStyle())
                }
                .padding(.top, 6)
            }
            .padding(24)
        }
        .presentationDetents([.medium])
        .presentationBackground { ReadingCanvas() }
    }
}
