import AppKit
import SwiftUI
@testable import BrimCore
@testable import BrimUI

enum AttentionUITests {
    static let now = date("2026-09-25T10:00:00Z")
    static let interval: TimeInterval = 0.5

    static func click(_ ring: String?, count: Int = 1, asking: Set<String> = ["claudeCode"],
                      sequence: (String, Date)? = nil, at time: Date = now) -> RingClick {
        RingClick.outcome(ringID: ring, clickCount: count, asking: asking,
                          sequence: sequence.map { (providerID: $0.0, at: $0.1) }, now: time,
                          doubleClickInterval: interval)
    }

    static func event(_ kind: SessionEvent.Kind) -> SessionEvent {
        SessionEvent(kind: kind, session: AgentSession(id: "s", providerID: "claudeCode", name: "brim", detail: "Terminal",
                                                       state: kind == .finished ? .finished : .waiting, since: now),
                     providerName: "Claude Code")
    }

    static let suite = TestSuite("Waiting rings", [
        test("a single click on an asking ring acknowledges it, and refreshes nothing") {
            expectEqual(click("claudeCode"), .acknowledge("claudeCode"))
        },
        test("the second click of a double-click raises the session the first one acknowledged") {
            // By the second click the ring has stopped asking.
            expectEqual(click("claudeCode", count: 2, asking: [], sequence: ("claudeCode", now.addingTimeInterval(-0.2))),
                        .focus("claudeCode"))
            // A double-click straight onto an asking ring does the same.
            expectEqual(click("claudeCode", count: 2), .focus("claudeCode"))
            // Too slow to be a double-click on it, or on another ring: never a
            // single-click action partway through a double-click.
            expectEqual(click("claudeCode", count: 2, asking: [], sequence: ("claudeCode", now.addingTimeInterval(-2))),
                        .ignore)
            expectEqual(click("codex", count: 2, asking: [], sequence: ("claudeCode", now)), .ignore)
        },
        test("a quiet ring's single click is held; clicks off the rings keep their ordinary meaning") {
            expectEqual(click("codex"), .single("codex"))
            expectEqual(click("codex", count: 2, sequence: ("codex", now.addingTimeInterval(-0.3))), .focus("codex"))
            expectEqual(click("codex", count: 2), .ignore)
            expectEqual(click(nil), .ordinary)
            expectEqual(click(nil, count: 2), .ordinary)
        },
        test("the clicks after a double-click do nothing, even where the notch has folded") {
            expectEqual(click("codex", count: 3, asking: [], sequence: ("codex", now.addingTimeInterval(-0.2))), .ignore)
            expectEqual(click(nil, count: 3, asking: [], sequence: ("codex", now.addingTimeInterval(-0.2))), .ignore)
            expectEqual(click(nil, count: 2, asking: [], sequence: ("codex", now.addingTimeInterval(-0.2))), .ignore)
        },
        test("only the provider that waits asks, on every ring of the stack") { @MainActor in
            let model = NotchViewModel()
            model.snapshots = DemoData.snapshots(now: now)
            expect(!model.isAskingForAttention)
            model.waitingProviders = [model.snapshots[1].id]
            expect(model.isAskingForAttention)
            expectEqual(model.snapshots.filter(model.needsAttention).map(\.id), [model.snapshots[1].id])
            // A provider with no ring on this notch doesn't hold it open.
            model.waitingProviders = ["not-shown"]
            expect(!model.isAskingForAttention)
        },
        test("the dash moves like DashRing: a 2 s turn, a 1.5 s dash, a slow breath, in amber") { @MainActor in
            let animations = AttentionDashView.animations()
            expectEqual(animations.turn.keyPath, "transform.rotation.z")
            expectEqual(animations.turn.duration, 2)
            expectApprox(animations.turn.toValue as? Double, -2 * Double.pi)
            expectEqual(animations.turn.repeatCount, .infinity)

            expectEqual(animations.dash.duration, 1.5)
            let keyframes = (animations.dash.animations ?? []).compactMap { $0 as? CAKeyframeAnimation }
            let start = keyframes.first { $0.keyPath == "strokeStart" }?.values as? [Double] ?? []
            let end = keyframes.first { $0.keyPath == "strokeEnd" }?.values as? [Double] ?? []
            // Length 0 → 42 → 42 and offset 0 → -16 → -59 on DashRing's 59.7 circle.
            expectEqual(start.count, 3)
            expectEqual(end.count, 3)
            if start.count == 3, end.count == 3 {
                expectApprox(start[1], 0.268, tolerance: 0.001)
                expectApprox(start[2], 0.988, tolerance: 0.001)
                expectApprox(end[1], 0.972, tolerance: 0.001)
                expectApprox(end[1] - start[1], 42 / (2 * Double.pi * 9.5), tolerance: 0.001)
                expectEqual(end[2], 1)
            }

            // Noticeable, never a strobe: slower than once a second, never dark.
            expect(animations.breath.duration >= 1.5)
            expect(((animations.breath.values as? [Float]) ?? []).allSatisfy { $0 >= 0.6 })

            let view = AttentionDashView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
            view.layout()
            let amber = NSColor(Palette.watch).cgColor
            for layer in [view.layers.track, view.layers.dash] {
                expectEqual(layer.strokeColor, amber)
                expectEqual(layer.lineCap, .round)
                expectNotNil(layer.path)
            }
            expectApprox(Double(view.layers.track.opacity), 0.1, tolerance: 0.01)
        },
        test("reduced motion swaps the moving dash for a steady amber ring") {
            expectEqual(AttentionHalo.rendering(still: false, reduceMotion: true), .steadyRing)
            expectEqual(AttentionHalo.rendering(still: true, reduceMotion: false), .steadyRing)
            expectEqual(AttentionHalo.rendering(still: false, reduceMotion: false), .animatedDash)
        },
        test("the halo stays clear of the reading and inside the notch") {
            let trackOuter = NotchLayout.ringDiameter / 2
            let haloInner = NotchLayout.attentionDiameter / 2 - NotchLayout.attentionStroke
            expect(haloInner > trackOuter, "the dash would cover the usage arc")
            expect(NotchLayout.attentionDiameter < NotchLayout.sideBodyDepth, "the halo would spill out of the notch")
        },
        test("VoiceOver hears that the agent is waiting, and what a click does") { @MainActor in
            let snapshot = DemoData.snapshots(now: now)[0]
            let asking = ProviderCell(snapshot: snapshot, activity: .waiting, needsAttention: true).accessibilityText
            expect(asking.hasPrefix(snapshot.displayName), asking)
            expect(asking.contains("waiting for your input. Single-click to acknowledge. Double-click to focus"), asking)
            let calm = ProviderCell(snapshot: snapshot, activity: .waiting).accessibilityText
            expect(calm.contains("session waiting") && !calm.contains("Single-click"), calm)
        },
        test("finished sessions still peek for the set time; waiting ones no longer do") {
            var settings = AppSettings()
            settings.peekDuration = 5
            expectEqual(NotchFleet.peekDuration(for: event(.finished), settings: settings), 5)
            expectNil(NotchFleet.peekDuration(for: event(.waiting), settings: settings))
            settings.peekOnFinish = false
            expectNil(NotchFleet.peekDuration(for: event(.finished), settings: settings))
        },
        test("a hidden notch is never opened for a waiting session") {
            var settings = AppSettings()
            expect(NotchFleet.attentionOpens(started: true, settings: settings, temporarilyHidden: false))
            expect(!NotchFleet.attentionOpens(started: false, settings: settings, temporarilyHidden: false))
            expect(!NotchFleet.attentionOpens(started: true, settings: settings, temporarilyHidden: true))
            settings.visibility = .hidden
            expect(!NotchFleet.attentionOpens(started: true, settings: settings, temporarilyHidden: false))
            settings.visibility = .onHover
            settings.peekOnWaiting = false
            expect(!NotchFleet.attentionOpens(started: true, settings: settings, temporarilyHidden: false))
        },
    ])
}
