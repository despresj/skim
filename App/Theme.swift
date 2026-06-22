import SwiftUI
import UIKit

/// Calm, system-aware palette. Warm paper in light mode; a warm near-black lit
/// by a luminous gold accent in dark — "reading by lamplight." Neutrals sit on
/// a consistent warm ramp so the darks glow rather than glare; the light bronze
/// accent is deepened to meet WCAG AA with white text on the accent fill.
extension Color {
    /// Base canvas. A `readingCanvas` gradient is layered on top for depth.
    /// Dark is a *warm* near-black (#11100D), not a dead neutral, so shadows
    /// read as lamplight; light is warm paper (#FBF7F0), free of the green cast.
    static let readingBackground = dynamic(
        dark:  UIColor(red: 0.067, green: 0.063, blue: 0.051, alpha: 1),
        light: UIColor(red: 0.984, green: 0.969, blue: 0.941, alpha: 1)
    )

    /// Slightly lifted surface for cards and inputs.
    static let readingSurface = dynamic(
        dark:  UIColor(red: 0.129, green: 0.122, blue: 0.106, alpha: 1),
        light: UIColor(white: 1.0, alpha: 1)
    )

    /// Hairline separators / borders.
    static let readingBorder = dynamic(
        dark:  UIColor(white: 1.0, alpha: 0.10),
        light: UIColor(white: 0.0, alpha: 0.08)
    )

    /// Primary text. Warm off-white (#F5F2ED) in dark to cut glare; warm ink
    /// (#211C17), not pure black, in light.
    static let readingForeground = dynamic(
        dark:  UIColor(red: 0.961, green: 0.949, blue: 0.929, alpha: 1),
        light: UIColor(red: 0.129, green: 0.110, blue: 0.090, alpha: 1)
    )

    /// De-emphasized text — hints, placeholders, secondary labels. Warm gray.
    static let readingMuted = dynamic(
        dark:  UIColor(red: 0.604, green: 0.584, blue: 0.549, alpha: 1),
        light: UIColor(red: 0.420, green: 0.400, blue: 0.369, alpha: 1)
    )

    /// Warm accent: luminous gold (#FAC26B) in dark, deep bronze (#A86B14) in
    /// light — the latter deepened so white-on-accent meets AA.
    static let readingAccent = dynamic(
        dark:  UIColor(red: 0.980, green: 0.761, blue: 0.420, alpha: 1),
        light: UIColor(red: 0.659, green: 0.420, blue: 0.078, alpha: 1)
    )

    /// Color for text/icons sitting on top of the accent fill.
    static let readingOnAccent = dynamic(
        dark:  UIColor(red: 0.102, green: 0.086, blue: 0.063, alpha: 1),
        light: UIColor(white: 1.0, alpha: 1)
    )

    /// The pivot ("optimal recognition point") letter that holds your eye on a
    /// fixed spot as words flash past. Tinted with the app's amber accent so the
    /// reading surface speaks one color language — gold (#FAC26B) in dark, bronze
    /// (#A86B14) in light, matching `readingAccent`.
    static let readingPivot = dynamic(
        dark:  UIColor(red: 0.980, green: 0.761, blue: 0.420, alpha: 1),
        light: UIColor(red: 0.659, green: 0.420, blue: 0.078, alpha: 1)
    )

    /// The hot end of the speed-warmth ramp: a brighter, more saturated amber the
    /// accents lean toward at full speed. Stays in the same gold family as
    /// `readingAccent` so the surface keeps one color language — just more
    /// energized. Dark leans luminous; light deepens toward burnt amber so the
    /// warmth still reads against paper. Never red — this is energy, not alarm.
    static let readingAccentHot = dynamic(
        dark:  UIColor(red: 1.000, green: 0.702, blue: 0.282, alpha: 1),
        light: UIColor(red: 0.745, green: 0.404, blue: 0.039, alpha: 1)
    )

    /// The accent warmed toward `readingAccentHot` by `warmth` (0…1). At rest it's
    /// the calm gold; at a blast it's the hotter amber.
    static func readingAccent(warmth: Double) -> Color {
        lerp(.readingAccent, .readingAccentHot, warmth)
    }

    /// The pivot letter warmed the same way, so the focal ORP letter heats with
    /// pace alongside the rest of the accent family.
    static func readingPivot(warmth: Double) -> Color {
        lerp(.readingPivot, .readingAccentHot, warmth)
    }

    /// Blend two colors by `amount` (clamped 0…1). Resolves each endpoint per
    /// trait, so dynamic light/dark colors interpolate correctly in either scheme.
    static func lerp(_ from: Color, _ to: Color, _ amount: Double) -> Color {
        let a = CGFloat(min(1, max(0, amount)))
        let f = UIColor(from)
        let t = UIColor(to)
        return Color(uiColor: UIColor { trait in
            let fc = f.resolvedColor(with: trait)
            let tc = t.resolvedColor(with: trait)
            var fr: CGFloat = 0, fg: CGFloat = 0, fb: CGFloat = 0, fa: CGFloat = 0
            var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
            fc.getRed(&fr, green: &fg, blue: &fb, alpha: &fa)
            tc.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
            return UIColor(red:   fr + (tr - fr) * a,
                           green: fg + (tg - fg) * a,
                           blue:  fb + (tb - fb) * a,
                           alpha: fa + (ta - fa) * a)
        })
    }

    private static func dynamic(dark: UIColor, light: UIColor) -> Color {
        Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

/// Speed-responsive warmth: a tight amber *instrument aura* that gently lights the
/// speed gauge in the reading-hand corner and fades fast into the dark canvas — a
/// localized glow that belongs to the gauge, not a side panel or an edge wash. Its
/// hue rides the speed (muted amber cruising → richer orange-gold at a blast) and it
/// swells a little as the band climbs; it stays subtle while actively reading and a
/// touch more present when paused or while the dial is being turned.
///
/// Two layers, back to front, so the warmth frames the word instead of competing:
///   1. A subtle vignette that lets the edges settle into warm black, deepening the
///      middle and keeping the focal word in a clean, dark pocket.
///   2. A tight aura centered on the gauge — radius only modestly past the
///      instrument, opacity front-loaded so it's nearly gone before the center word.
/// Layered above the base `ReadingCanvas`; the deep background still dominates and
/// the main word keeps its contrast (the glow lives away from it; the vignette only
/// darkens behind it).
struct ReadingWarmth: View {
    let warmth: Double
    let leftHanded: Bool
    /// A touch brighter when the reader is at rest or the dial is being turned (so
    /// the instrument reads as "ready / adjusting"); subtler while actively reading,
    /// where the word owns the surface. Defaults off.
    var emphasized: Bool = false

    var body: some View {
        // Hue rides the speed, in the same amber family as the gauge: a muted
        // amber while cruising, warming toward a richer orange-gold at a blast —
        // never red, never an alarm.
        let hue = Color.readingAccent(warmth: warmth)

        // The reading-hand edge; mirror x for a left-hand grip so the aura follows
        // the gauge to whichever side it lives on.
        func atEdge(_ x: CGFloat) -> CGFloat { leftHanded ? 1 - x : x }

        // Restrained aura strength: subtle while reading, a little more present when
        // paused / adjusting, warming gently with speed — an instrument glow, never
        // a flare.
        let auraPeak = (emphasized ? 0.085 : 0.05) + warmth * 0.06

        // Vignette ink — warm near-black in dark; a faint, low-alpha warm gray in
        // light so the frame stays a whisper against paper, never a smudge.
        let shade = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.016, green: 0.014, blue: 0.010, alpha: 1.0)
                : UIColor(red: 0.38, green: 0.34, blue: 0.28, alpha: 0.12)
        })

        return ZStack {
            // 1 · Vignette, beneath the warmth so the amber still reads warm at the
            //     lower edge instead of being muted by the frame. Clear through the
            //     center (the word's pocket), falling to warm black at the edges.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: .clear, location: 0.5),
                    .init(color: shade.opacity(0.45), location: 0.82),
                    .init(color: shade.opacity(0.85), location: 1.0),
                ]),
                center: UnitPoint(x: 0.5, y: 0.46),
                startRadius: 120,
                endRadius: 560
            )

            // 2 · Tight instrument aura centered on the gauge (mid-height, near the
            //     reading edge). A small radius — only modestly past the instrument —
            //     with opacity front-loaded into the inner stops, so the gauge glows
            //     while the rest of the surface, and the focal word off to the side,
            //     stay calm and dark. Follows the gauge for a left-hand grip.
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: hue.opacity(auraPeak), location: 0.0),
                    .init(color: hue.opacity(auraPeak * 0.5), location: 0.28),
                    .init(color: hue.opacity(auraPeak * 0.16), location: 0.58),
                    .init(color: .clear, location: 1.0),
                ]),
                center: UnitPoint(x: atEdge(0.92), y: 0.5),
                startRadius: 6,
                endRadius: 150
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Full-bleed background: a faint warm glow at the top settling into the deep
/// base. Sits behind every screen for a sense of depth.
struct ReadingCanvas: View {
    var body: some View {
        let top = Color(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(red: 0.125, green: 0.108, blue: 0.082, alpha: 1)
                : UIColor(red: 1.0, green: 0.980, blue: 0.949, alpha: 1)
        })
        LinearGradient(
            colors: [top, .readingBackground, .readingBackground],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

// MARK: - Button styles

/// Filled accent pill with a soft glow and a gentle press-in.
struct PrimaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.readingOnAccent)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(Color.readingAccent, in: Capsule())
            .shadow(color: .readingAccent.opacity(0.35), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}

/// Quiet outlined pill for secondary actions.
struct SecondaryPillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(Color.readingForeground)
            .padding(.vertical, 15)
            // Breathing room on the ends so the label never hugs the capsule's
            // rounded edges — needed when the pill sizes to content (e.g. the
            // completion screen's `.fixedSize`) rather than stretching full width.
            .padding(.horizontal, 28)
            .frame(maxWidth: .infinity)
            .background(Color.readingSurface, in: Capsule())
            .overlay(Capsule().stroke(Color.readingBorder, lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7),
                       value: configuration.isPressed)
    }
}
