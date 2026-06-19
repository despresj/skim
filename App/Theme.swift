import SwiftUI
import UIKit

/// Calm, system-aware palette: warm cream in light mode, deep charcoal in dark.
extension Color {
    static let readingBackground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.07, alpha: 1)
            : UIColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1)
    })

    static let readingForeground = Color(uiColor: UIColor { trait in
        trait.userInterfaceStyle == .dark
            ? UIColor(white: 0.92, alpha: 1)
            : UIColor(white: 0.12, alpha: 1)
    })
}
