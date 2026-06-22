import SwiftUI
import UIKit

/// A thin bridge to the system share sheet (`UIActivityViewController`). This is the
/// whole of v1's "share/save": the OS supplies Save Video, Save to Files, AirDrop,
/// Messages, and any installed destination (YouTube / TikTok / Instagram) — Skim
/// builds no direct uploads. Passed the exported file URL as the single activity item.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
