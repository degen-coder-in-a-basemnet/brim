// Measurements, palette and motion adapted from Codenotch
// (https://github.com/vinzdg/codenotch), MIT License, Copyright (c) 2026 Vinz.
// See THIRD_PARTY_NOTICES.md.
import AppKit
import BrimCore
import SwiftUI

/// Every number in the notch is measured off the reference design frame
/// (2000 × 2000 px), so the layout is proportionally exact rather than
/// eyeballed. The frame fixes ratios, not a size: the provider ring is 44 pt
/// and measures 117 px, and that one anchor sets the scale for everything.
enum Design {
    /// Points per pixel of the design frame.
    static let scale: CGFloat = 44.0 / 117.0

    static func px(_ pixels: CGFloat) -> CGFloat { pixels * scale }

    /// Cap height as a share of the em for SF Pro. Text in the frame can only be
    /// measured by its capitals, so this converts back to a point size.
    private static let capRatio: CGFloat = 0.714

    static func fontSize(capPixels pixels: CGFloat) -> CGFloat {
        px(pixels) / capRatio
    }
}

/// Colours sampled from the design frame. The notch is always the solid black
/// surface, so these are its dark-appearance values.
enum Palette {
    static let notch = Color.black
    static let card = Color.black
    /// Translucent white rather than a fixed grey; over black they composite to
    /// the frame's #303030 and #2D2D2D.
    static let ringTrack = Color.white.opacity(0.188)
    static let barTrack = Color.white.opacity(0.176)

    static let ample = Color(hex: 0x00FF88)
    static let watch = Color(hex: 0xF2FF00)
    static let critical = Color(hex: 0xFF3F00)

    static let textPrimary = Color.white
    static let textSecondary = Color(hex: 0x808080)
    /// The local-runtime arc: a measurement, not an allowance, so it takes no
    /// warning colour.
    static let local = Color.white.opacity(0.78)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}

extension UsageBand {
    /// Only the "plenty of room" state follows the accent. Warning colours stay
    /// fixed: their job is to interrupt.
    func color(accent: Color) -> Color {
        switch self {
        case .ample:                return accent
        case .watch:                return Palette.watch
        case .critical, .exhausted: return Palette.critical
        }
    }
}

extension AccentChoice {
    var color: Color {
        hex.map { Color(hex: $0) } ?? Color(nsColor: .controlAccentColor)
    }
}

/// Font sizes derived from cap heights in the frame.
enum Typography {
    /// The percentage under each ring: 27 px caps.
    static let percent = Font.system(size: Design.fontSize(capPixels: 27), weight: .semibold)
    /// "Claude Usage": 26 px caps.
    static let cardTitle = Font.system(size: Design.fontSize(capPixels: 26), weight: .semibold)
    /// "Current session", "73% Used", "Resets in 51 min": 18 px caps.
    static let cardBody = Font.system(size: Design.fontSize(capPixels: 18), weight: .regular)
    /// The fidelity and source line at the foot of the card.
    static let cardFoot = Font.system(size: Design.fontSize(capPixels: 15), weight: .regular)
}

/// The whole surface moves with one vocabulary: springs just short of bouncy,
/// so things settle rather than arrive.
enum NotchMotion {
    /// Folding open and shut. Heavy enough to read as a body of liquid
    /// changing shape; the small overshoot is the whole effect.
    static let unfold = Animation.spring(response: 0.62, dampingFraction: 0.72)
    /// Contents catching up with the black as it opens.
    static let contents = Animation.spring(response: 0.48, dampingFraction: 0.8)
    /// The tooltip travelling between cells.
    static let glide = Animation.spring(response: 0.5, dampingFraction: 0.86)
    /// Contents changing inside something already moving.
    static let crossfade = Animation.easeInOut(duration: 0.16)
    /// A percentage changing: a ring that sweeps reads as a measurement.
    static let reading = Animation.spring(response: 0.9, dampingFraction: 0.9)
    /// The settings arc being drawn back into the notch.
    static let merge = Animation.easeIn(duration: 0.2)
    /// Hover arriving on a cell.
    static let hoverIn = Animation.spring(response: 0.18, dampingFraction: 0.85)
    static let hoverOut = Animation.easeOut(duration: 0.18)

    /// Each cell trails the one before it, capped so long stacks stay quick.
    static func stagger(index: Int) -> Animation {
        contents.delay(min(Double(index) * 0.045, 0.18))
    }

    static func respectingReduceMotion(_ animation: Animation, _ reduce: Bool) -> Animation? {
        reduce ? nil : animation
    }
}

private struct AccentKey: EnvironmentKey {
    static let defaultValue = Palette.ample
}

extension EnvironmentValues {
    var brimAccent: Color {
        get { self[AccentKey.self] }
        set { self[AccentKey.self] = newValue }
    }
}
