// Ring construction and activity arcs adapted from Codenotch
// (https://github.com/vinzdg/codenotch), MIT License, Copyright (c) 2026 Vinz.
// See THIRD_PARTY_NOTICES.md.
import AppKit
import BrimCore
import SwiftUI

extension SessionState {
    /// The inner arc's colour.
    var color: Color {
        switch self {
        case .busy:        return Palette.textPrimary
        case .waiting:     return Palette.watch
        case .finished:    return Palette.ample
        case .stale:       return Palette.textSecondary
        case .idle, .unavailable: return Palette.ringTrack
        }
    }
}

/// The ring around a provider's mark: a grey track and a coloured arc from 12
/// o'clock, clockwise, as long as the share used.
///
/// A second, thinner arc appears inside while a session is working — a
/// different radius, weight and colour, so it reads as a separate fact rather
/// than the usage moving.
struct ProviderRing: View {
    /// Nil when there is no denominator: no arc, rather than one drawn against
    /// a guess.
    let usedFraction: Double?
    let glyph: ProviderGlyph
    var isStale = false
    /// Spent right now. Drawn as spent whatever the arc says.
    var isBlocked = false
    /// A local runtime: the arc is a measurement, not an allowance.
    var isLocal = false
    /// A local runtime with something loaded, drawn as a full quiet ring when
    /// there is no measurement to sweep.
    var isLocalActive = false
    var activity: SessionState?
    /// A session here is waiting for the person and nobody has acknowledged
    /// it: amber arc, and the attention dash outside the ring.
    var needsAttention = false
    var isRefreshing = false
    /// Snapshot renders draw the working arc still, since Core Animation does
    /// not run offscreen.
    var staticActivity = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.brimAccent) private var accent
    @State private var spin: Double = 0

    private var band: UsageBand {
        isBlocked ? .exhausted : UsageBand.band(for: usedFraction ?? 0)
    }

    private var sweep: CGFloat { CGFloat(min(max(usedFraction ?? 0, 0), 1)) }

    /// Only the colour changes while asking; the sweep is still the reading.
    private var arcColor: Color {
        if isLocal { return Palette.local }
        return needsAttention ? Palette.watch : band.color(accent: accent)
    }

    var body: some View {
        ZStack {
            // Staleness dims the reading only. Whether an agent is working is
            // known first-hand and stays at full strength.
            ZStack {
                Circle()
                    .strokeBorder(Palette.ringTrack, lineWidth: NotchLayout.trackStroke)

                if usedFraction != nil || isBlocked {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .trim(from: 0, to: isBlocked ? 1 : max(sweep, isLocal ? 0.06 : 0))
                        .stroke(arcColor, style: StrokeStyle(lineWidth: NotchLayout.progressStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90 + spin))
                        .animation(NotchMotion.reading, value: sweep)
                        .animation(NotchMotion.reading, value: band)
                        .animation(NotchMotion.reading, value: needsAttention)
                } else if isLocalActive {
                    Circle()
                        .inset(by: NotchLayout.trackStroke / 2)
                        .stroke(Palette.textSecondary, lineWidth: NotchLayout.progressStroke)
                }

                ProviderGlyphView(glyph: glyph)
                    .foregroundStyle(Palette.textPrimary)
                    .opacity(band == .exhausted ? 0.35 : 1)
            }
            .opacity(isStale ? 0.45 : 1)

            // While the ring asks for attention the halo speaks for the waiting
            // session; once acknowledged, the ordinary waiting pulse returns.
            if let activity, activity != .idle, activity != .unavailable, !(needsAttention && activity == .waiting) {
                ActivityArc(state: activity, still: staticActivity || reduceMotion)
            }

            if needsAttention {
                AttentionHalo(still: staticActivity)
                    .transition(.opacity)
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        .animation(NotchMotion.respectingReduceMotion(.easeInOut(duration: 0.35), reduceMotion), value: needsAttention)
        // Pressed in while a fetch the user asked for is in flight.
        .scaleEffect(isRefreshing ? 0.93 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.62), value: isRefreshing)
        .onChange(of: isRefreshing) { _, refreshing in
            guard refreshing, !reduceMotion else { return }
            // Exactly one turn, which lands where it started and so needs no
            // cancelling.
            withAnimation(.timingCurve(0.32, 0, 0.14, 1, duration: 0.95)) { spin += 360 }
        }
    }
}

/// The inner indicator: a turning arc while working, a pulsing ring while
/// waiting on you, a steady ring for a moment once finished.
private struct ActivityArc: View {
    let state: SessionState
    var still = false
    @State private var pulsing = false

    private var inset: CGFloat { (NotchLayout.ringDiameter - NotchLayout.activityDiameter) / 2 }

    var body: some View {
        Group {
            switch state {
            case .busy:
                if still {
                    Circle().inset(by: inset).trim(from: 0, to: 0.25)
                        .stroke(state.color, style: StrokeStyle(lineWidth: NotchLayout.activityStroke, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                } else {
                    SpinningArc(color: NSColor(state.color), inset: inset)
                }
            case .waiting:
                Circle().inset(by: inset)
                    .stroke(state.color, lineWidth: NotchLayout.activityStroke)
                    .opacity(pulsing ? 0.3 : 1)
                    .onAppear {
                        guard !still else { return }
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulsing = true }
                    }
                    .onDisappear { pulsing = false }
            case .finished, .stale:
                Circle().inset(by: inset)
                    .stroke(state.color, lineWidth: NotchLayout.activityStroke)
                    .transition(.opacity)
            default:
                EmptyView()
            }
        }
        .frame(width: NotchLayout.ringDiameter, height: NotchLayout.ringDiameter)
        .allowsHitTesting(false)
    }
}

/// The working arc as a shape layer turned by Core Animation, so a busy
/// session costs the app nothing between frames.
private struct SpinningArc: NSViewRepresentable {
    let color: NSColor
    let inset: CGFloat

    func makeNSView(context: Context) -> SpinningArcView { SpinningArcView() }

    func updateNSView(_ view: SpinningArcView, context: Context) {
        view.configure(color: color, inset: inset)
    }
}

final class SpinningArcView: NSView {
    private let arc = CAShapeLayer()
    private var inset: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        arc.fillColor = nil
        arc.lineCap = .round
        arc.lineWidth = NotchLayout.activityStroke
        arc.strokeEnd = 0.25
        layer?.addSublayer(arc)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(color: NSColor, inset: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.strokeColor = color.cgColor
        self.inset = inset
        rebuild()
        CATransaction.commit()
        animate()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuild()
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        animate()
    }

    private func rebuild() {
        arc.frame = bounds
        arc.path = Self.circle(in: bounds, inset: inset)
    }

    /// A whole circle from 12 o'clock, clockwise, `inset` in from the bounds.
    /// Shared with the attention dash.
    static func circle(in bounds: CGRect, inset: CGFloat) -> CGPath {
        let radius = max(0, min(bounds.width, bounds.height) / 2 - inset)
        let path = CGMutablePath()
        path.addArc(center: CGPoint(x: bounds.midX, y: bounds.midY), radius: radius,
                    startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        return path
    }

    /// Re-added whenever it went missing: AppKit drops layer animations when a
    /// window leaves the screen.
    private func animate() {
        guard window != nil, arc.animation(forKey: "turn") == nil else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = -2 * Double.pi
        turn.duration = 1.1
        turn.repeatCount = .infinity
        turn.isRemovedOnCompletion = false
        arc.add(turn, forKey: "turn")
    }
}

/// A ring and the reading under it.
struct ProviderCell: View {
    let snapshot: ProviderSnapshot
    var activity: SessionState?
    var needsAttention = false
    var isRefreshing = false
    var now = Date()
    var staticActivity = false

    private var isLocal: Bool { snapshot.fidelity == .local }

    var body: some View {
        VStack(spacing: NotchLayout.ringLabelGap) {
            ProviderRing(
                usedFraction: snapshot.usedFraction,
                glyph: snapshot.glyph,
                isStale: snapshot.status.isStale || snapshot.status.isProblem,
                isBlocked: snapshot.isBlocked(now: now),
                isLocal: isLocal,
                isLocalActive: isLocal && snapshot.cellLabel != "Idle" && !snapshot.status.isProblem,
                activity: activity,
                needsAttention: needsAttention,
                isRefreshing: isRefreshing,
                staticActivity: staticActivity)
            Text(readingText)
                .font(Typography.percent)
                .foregroundStyle(snapshot.hasReading || isLocal ? Palette.textPrimary : Palette.textSecondary)
                .opacity(snapshot.status.isStale ? 0.6 : 1)
                .lineLimit(1)
                .minimumScaleFactor(isLocal ? 0.55 : 1)
                .frame(width: isLocal ? NotchLayout.ringDiameter + Design.px(20) : nil,
                       height: NotchLayout.percentLineHeight)
                .fixedSize(horizontal: !isLocal, vertical: false)
                .contentTransition(.numericText())
                .animation(NotchMotion.reading, value: readingText)
        }
        .frame(height: NotchLayout.cellExtent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    /// "≈" in front of an estimate, right on the ring's reading.
    private var readingText: String {
        guard snapshot.cellLabel == nil, snapshot.hasReading else { return snapshot.headlineText }
        return snapshot.headlineFidelity.qualifier + snapshot.headlineText
    }

    var accessibilityText: String {
        var parts = [snapshot.displayName]
        if let headline = snapshot.headline, let fraction = headline.usedFraction {
            let estimate = snapshot.headlineFidelity == .derived ? "about " : ""
            parts.append("\(headline.label) \(estimate)\(Percent.text(for: fraction)) used")
        } else {
            parts.append(snapshot.cellLabel ?? "no reading")
        }
        if snapshot.status.isStale { parts.append("stale") }
        if let message = snapshot.status.message { parts.append(message) }
        if needsAttention {
            parts.append("waiting for your input")
            return parts.joined(separator: ", ")
                + ". Single-click to acknowledge. Double-click to focus the app it runs in."
        }
        if let activity, activity != .idle { parts.append("session \(activity.word)") }
        return parts.joined(separator: ", ")
    }
}
