// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import BrimCore
import SwiftUI

/// The settings control past the foot of the notch.
///
/// At rest it is one arc of a circle, tucked into the corner the notch's far
/// flare makes and concentric with it. On hover the same circle fills in and
/// takes a gear — one object waking up, not one swapped for another.
struct SettingsOrb: View {
    let isHovered: Bool
    var edge: NotchEdge = .right
    /// True when the arc traces a flush bar's convex corner from outside.
    var convex = false
    var arcRadius: CGFloat = NotchLayout.orbArcRadius
    var arcOffset: CGSize = .zero
    var spins = 0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The quarter of the circle the resting arc occupies: back along the
    /// stack toward the notch, and outward toward the bezel it merges into.
    /// SwiftUI's trim starts at 3 o'clock and runs clockwise.
    static func restingTrim(for edge: NotchEdge, convex: Bool) -> ClosedRange<CGFloat> {
        let concave: ClosedRange<CGFloat>
        switch edge {
        case .right:  concave = 0.75...1.0
        case .left:   concave = 0.5...0.75
        case .top:    concave = 0.5...0.75
        case .bottom: concave = 0.25...0.5
        }
        guard convex else { return concave }
        let turned = (concave.lowerBound + 0.5).truncatingRemainder(dividingBy: 1)
        return turned...(turned + 0.25)
    }

    var body: some View {
        let trim = Self.restingTrim(for: edge, convex: convex)
        ZStack {
            Circle()
                .trim(from: trim.lowerBound, to: trim.upperBound)
                .stroke(Palette.notch, style: StrokeStyle(lineWidth: NotchLayout.orbStroke, lineCap: .round))
                .frame(width: arcRadius * 2, height: arcRadius * 2)
                .opacity(isHovered ? 0 : 1)
                .scaleEffect(isHovered ? 0.86 : 1)
                .offset(arcOffset)

            Circle()
                .fill(Palette.notch)
                .frame(width: NotchLayout.orbDiameter, height: NotchLayout.orbDiameter)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 1.1)

            Image(systemName: "gearshape")
                .font(.system(size: NotchLayout.orbGlyph, weight: .regular))
                .foregroundStyle(Palette.textPrimary)
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.5)
                .rotationEffect(.degrees((isHovered ? 0 : -60) + Double(spins) * 360))
                .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.55, dampingFraction: 0.72), reduceMotion),
                           value: spins)
        }
        .frame(width: arcRadius * 2 + NotchLayout.orbStroke, height: arcRadius * 2 + NotchLayout.orbStroke)
        .animation(NotchMotion.respectingReduceMotion(.spring(response: 0.36, dampingFraction: 0.7), reduceMotion),
                   value: isHovered)
        .keyframeAnimator(initialValue: CGFloat(1), trigger: spins) { orb, scale in
            orb.scaleEffect(scale)
        } keyframes: { _ in
            SpringKeyframe(reduceMotion ? 1 : 0.84, duration: 0.09, spring: .snappy)
            SpringKeyframe(1, duration: 0.34, spring: .bouncy)
        }
        .accessibilityElement()
        .accessibilityLabel("Brim settings")
        .accessibilityAddTraits(.isButton)
    }
}
