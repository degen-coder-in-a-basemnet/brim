import AppKit
import SwiftUI

/// "This agent needs you": an amber dash chasing round the outside of a
/// provider's ring over a faint amber track, breathing slightly.
///
/// It sits outside the ring, so the reading inside is untouched, and it moves
/// unlike the working arc (growing, travelling and running off its own end, all
/// while turning) so it never reads as loading. The motion follows 21st.dev's
/// DashRing: one turn every two seconds, and a dash cycle every one and a half.
struct AttentionHalo: View {
    enum Rendering: Equatable {
        case animatedDash
        /// Reduced motion, and offscreen renders where Core Animation never
        /// runs: a steady amber ring, still unmistakable.
        case steadyRing
    }

    nonisolated static func rendering(still: Bool, reduceMotion: Bool) -> Rendering {
        still || reduceMotion ? .steadyRing : .animatedDash
    }

    var still = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch Self.rendering(still: still, reduceMotion: reduceMotion) {
            case .animatedDash:
                AttentionDash()
            case .steadyRing:
                Circle()
                    .inset(by: NotchLayout.attentionStroke / 2)
                    .stroke(Palette.watch, lineWidth: NotchLayout.attentionStroke)
                    .opacity(0.9)
            }
        }
        .frame(width: NotchLayout.attentionDiameter, height: NotchLayout.attentionDiameter)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct AttentionDash: NSViewRepresentable {
    func makeNSView(context: Context) -> AttentionDashView { AttentionDashView() }
    func updateNSView(_ view: AttentionDashView, context: Context) {}
}

/// The dash on Core Animation, built like the working arc's `SpinningArcView`:
/// once running it costs the app nothing between frames.
final class AttentionDashView: NSView {
    /// DashRing draws on a circle of radius 9.5, so its dash lengths and offsets
    /// are fractions of this.
    private static let circumference = 2 * Double.pi * 9.5
    static let turn: CFTimeInterval = 2
    static let dashCycle: CFTimeInterval = 1.5
    /// Where the dash begins and ends along the circle at DashRing's three
    /// keyframes: length 0 → 42 → 42 while the offset runs 0 → -16 → -59.
    static let dashStart: [Double] = [0, 16 / circumference, 59 / circumference]
    static let dashEnd: [Double] = [0, 58 / circumference, 1]
    static let trackOpacity: Float = 0.1
    /// A slow breath, well under once a second and never near dark: noticeable,
    /// never a flash.
    static let breath: CFTimeInterval = 2.4
    static let breathLow: Float = 0.7

    private let halo = CALayer()
    private let track = CAShapeLayer()
    private let dash = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let amber = NSColor(Palette.watch).cgColor
        for shape in [track, dash] {
            shape.fillColor = nil
            shape.strokeColor = amber
            shape.lineWidth = NotchLayout.attentionStroke
            shape.lineCap = .round
            halo.addSublayer(shape)
        }
        track.opacity = Self.trackOpacity
        dash.strokeStart = 0
        dash.strokeEnd = 0
        layer?.addSublayer(halo)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    var layers: (track: CAShapeLayer, dash: CAShapeLayer) { (track, dash) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        halo.frame = bounds
        let path = SpinningArcView.circle(in: bounds, inset: NotchLayout.attentionStroke / 2)
        for shape in [track, dash] {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    /// Re-added whenever they went missing: AppKit drops layer animations when
    /// a window leaves the screen.
    private func animate() {
        guard window != nil, dash.animation(forKey: "turn") == nil else { return }
        let animations = Self.animations()
        dash.add(animations.turn, forKey: "turn")
        dash.add(animations.dash, forKey: "dash")
        halo.add(animations.breath, forKey: "breath")
    }

    static func animations() -> (turn: CABasicAnimation, dash: CAAnimationGroup, breath: CAKeyframeAnimation) {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)

        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi   // clockwise, in a layer's y-up space
        turn.duration = Self.turn
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false

        let start = CAKeyframeAnimation(keyPath: "strokeStart")
        start.values = dashStart
        let end = CAKeyframeAnimation(keyPath: "strokeEnd")
        end.values = dashEnd
        for keyframes in [start, end] {
            keyframes.keyTimes = [0, 0.5, 1]
            keyframes.timingFunctions = [ease, ease]
        }
        let dash = CAAnimationGroup()
        dash.animations = [start, end]
        dash.duration = dashCycle
        dash.repeatCount = .infinity
        dash.isRemovedOnCompletion = false

        let breath = CAKeyframeAnimation(keyPath: "opacity")
        breath.values = [1, breathLow, 1]
        breath.keyTimes = [0, 0.5, 1]
        breath.timingFunctions = [ease, ease]
        breath.duration = Self.breath
        breath.repeatCount = .infinity
        breath.isRemovedOnCompletion = false
        return (turn, dash, breath)
    }
}
