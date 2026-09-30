import AppKit
import BrimCore
@testable import BrimUI
import SwiftUI

struct FakeScreen: ScreenDescribing {
    var frameValue: CGRect
    var hardwareNotch: HardwareNotch? = nil
    var displayIdentifier: String? = nil
}

enum PlacementTests {
    static let panel = CGSize(width: 300, height: 800)

    static let suite = TestSuite("Placement", [
        test("stack space maps onto each edge with zero at the bezel") {
            let right = NotchPlacement(edge: .right, panelSize: panel)
            expectEqual(right.point(along: 10, across: 0), CGPoint(x: 300, y: 10))
            expectEqual(right.point(along: 10, across: 20), CGPoint(x: 280, y: 10))
            let left = NotchPlacement(edge: .left, panelSize: panel)
            expectEqual(left.point(along: 10, across: 20), CGPoint(x: 20, y: 10))
            let wide = CGSize(width: 800, height: 300)
            expectEqual(NotchPlacement(edge: .top, panelSize: wide).point(along: 10, across: 20), CGPoint(x: 10, y: 20))
            expectEqual(NotchPlacement(edge: .bottom, panelSize: wide).point(along: 10, across: 20), CGPoint(x: 10, y: 280))
        },
        test("rects span inward from the bezel") {
            let right = NotchPlacement(edge: .right, panelSize: panel)
            expectEqual(right.rect(along: 100, across: 0, length: 50, depth: 70), CGRect(x: 230, y: 100, width: 70, height: 50))
            let bottom = NotchPlacement(edge: .bottom, panelSize: CGSize(width: 800, height: 300))
            expectEqual(bottom.rect(along: 100, across: 0, length: 50, depth: 70), CGRect(x: 100, y: 230, width: 50, height: 70))
        },
        test("inverse mapping round-trips") {
            for edge in NotchEdge.allCases {
                let size = edge.isVertical ? panel : CGSize(width: 800, height: 300)
                let place = NotchPlacement(edge: edge, panelSize: size)
                let point = place.point(along: 123, across: 45)
                expectEqual(place.along(of: point), 123, "\(edge)")
                expectEqual(place.across(of: point), 45, "\(edge)")
            }
        },
        test("tooltips leave away from the bezel") {
            expectEqual(NotchEdge.right.tooltipDirection, .leading)
            expectEqual(NotchEdge.left.tooltipDirection, .trailing)
            expectEqual(NotchEdge.top.tooltipDirection, .down)
            expectEqual(NotchEdge.bottom.tooltipDirection, .up)
        },
    ])
}

enum PanelFrameTests {
    static let screen = FakeScreen(frameValue: CGRect(x: 0, y: 0, width: 1512, height: 982))
    static let second = FakeScreen(frameValue: CGRect(x: 1512, y: -200, width: 1920, height: 1080))
    static let size = CGSize(width: 330, height: 700)

    static let suite = TestSuite("Panel frames", [
        test("each edge is flush with the physical screen edge and centred") {
            let right = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right)
            expectEqual(right.maxX, 1512)
            expectEqual(right.midY, 491)
            let left = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .left)
            expectEqual(left.minX, 0)
            let wide = CGSize(width: 700, height: 330)
            let top = NotchGeometry.panelFrame(for: screen, panelSize: wide, edge: .top)
            expectEqual(top.maxY, 982)
            expectEqual(top.midX, 756)
            expectEqual(NotchGeometry.panelFrame(for: screen, panelSize: wide, edge: .bottom).minY, 0)
        },
        test("works on a second display with its own origin") {
            let frame = NotchGeometry.panelFrame(for: second, panelSize: size, edge: .right)
            expectEqual(frame.maxX, 1512 + 1920)
            expectEqual(frame.midY, -200 + 540)
        },
        test("the along offset slides down a side edge and right along a horizontal one") {
            let moved = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 100)
            expectEqual(moved.midY, 491 - 100)
            let wide = CGSize(width: 700, height: 330)
            let slid = NotchGeometry.panelFrame(for: screen, panelSize: wide, edge: .bottom, alongOffset: 100)
            expectEqual(slid.midX, 756 + 100)
        },
        test("the offset is clamped so the notch stays on screen") {
            let far = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: .right, alongOffset: 5000, slack: 100)
            expectEqual(far.minY, -100, "only the slack may run past the bezel")
            let limit = NotchGeometry.offsetLimit(for: screen, panelSize: size, edge: .right, slack: 100)
            expectEqual(limit, (982 - 500) / 2)
        },
        test("frames are rounded to whole points") {
            let frame = NotchGeometry.panelFrame(for: screen, panelSize: CGSize(width: 330.4, height: 700.6), edge: .right)
            expectEqual(frame.width, 331)
            expectEqual(frame.height, 701)
            expectEqual(frame.origin.y, frame.origin.y.rounded())
        },
        test("display scope picks the right screens") {
            let a = FakeScreen(frameValue: .zero, displayIdentifier: "A")
            let b = FakeScreen(frameValue: .zero, displayIdentifier: "B")
            expectEqual(NotchGeometry.targetScreens(from: [a, b], scope: .main, chosenID: nil, main: a).map(\.displayIdentifier), ["A"])
            expectEqual(NotchGeometry.targetScreens(from: [a, b], scope: .all, chosenID: nil, main: a).count, 2)
            expectEqual(NotchGeometry.targetScreens(from: [a, b], scope: .specific, chosenID: "B", main: a).map(\.displayIdentifier), ["B"])
            expectEqual(NotchGeometry.targetScreens(from: [a, b], scope: .specific, chosenID: "gone", main: a).map(\.displayIdentifier), ["A"],
                        "an unplugged choice falls back to the main display")
        },
        test("the camera notch is as deep as its deepest signal") {
            expectEqual(HardwareNotch.height(safeAreaTop: 0, beside: [38, 38]), 38)
            expectEqual(HardwareNotch.height(safeAreaTop: 40, beside: [38]), 40)
        },
    ])
}

enum LayoutTests {
    static let suite = TestSuite("Notch layout", [
        test("the design anchor is a 44 pt ring") {
            expectApprox(Double(NotchLayout.ringDiameter), 44, tolerance: 1e-9)
            expectApprox(Double(NotchLayout.sideBodyDepth), 186 * 44 / 117, tolerance: 1e-9)
        },
        test("body length grows by a cell pitch per provider") {
            for edge in NotchEdge.allCases {
                let one = NotchLayout.bodyLength(cellCount: 1, edge: edge)
                let two = NotchLayout.bodyLength(cellCount: 2, edge: edge)
                expectApprox(Double(two - one), Double(NotchLayout.cellPitch(for: edge)), tolerance: 1e-9)
            }
        },
        test("horizontal notches are deeper, to hold the reading under the ring") {
            expect(NotchLayout.bodyDepth(for: .top) > NotchLayout.bodyDepth(for: .right))
            expectApprox(Double(NotchLayout.padStart(for: .top)), Double(NotchLayout.padEnd(for: .top)), tolerance: 1e-9)
        },
        test("ring centres sit inside the body") {
            let flare = NotchLayout.curlRadius
            let length = NotchLayout.shapeLength(cellCount: 3, edge: .right, flare: flare)
            for index in 0..<3 {
                let centre = NotchLayout.ringCenter(index: index, edge: .right, flare: flare)
                expect(centre > flare && centre < length - flare, "ring \(index) at \(centre)")
            }
        },
        test("the settings arc is concentric with the flare, a gap inside it") {
            expectApprox(Double(NotchLayout.orbArcRadius + NotchLayout.orbGap), Double(NotchLayout.curlRadius), tolerance: 1e-9)
            expect(NotchLayout.orbMergeScale > 1, "hiding grows the arc into the black")
        },
        test("the resting arc faces back along the stack and out to the bezel") { @MainActor in
            expectEqual(SettingsOrb.restingTrim(for: .right, convex: false), 0.75...1.0)
            expectEqual(SettingsOrb.restingTrim(for: .bottom, convex: false), 0.25...0.5)
            expectEqual(SettingsOrb.restingTrim(for: .right, convex: true), 0.25...0.5)
        },
        test("a card's height budget covers its rows") { @MainActor in
            let snapshot = DemoData.snapshot(id: "demo.claude", now: Date())
            let bare = NotchLayout.cardHeight(for: snapshot, sessionCount: 0, now: Date())
            let busy = NotchLayout.cardHeight(for: snapshot, sessionCount: 2, now: Date())
            let many = NotchLayout.cardHeight(for: snapshot, sessionCount: 9, now: Date())
            expect(busy > bare)
            expect(many > busy)
            let capped = NotchLayout.cardHeight(for: snapshot, sessionCount: 20, now: Date())
            expectEqual(capped, many, "rows past the cap are summarised, not drawn")
        },
        test("long count rows wrap rather than truncate") {
            expect(!NotchLayout.countRowWraps(LimitWindow(id: "r", label: "Requests", detail: "12")))
            expect(NotchLayout.countRowWraps(LimitWindow(id: "m", label: "llama3.2:3b",
                                                         detail: "2.0 GB · 100% GPU · 4K ctx · unloads in 4m")))
        },
    ])
}

enum ViewModelTests {
    @MainActor
    static func model(edge: NotchEdge = .right, count: Int = 3) -> NotchViewModel {
        let model = NotchViewModel()
        model.snapshots = Array(DemoData.snapshots(now: Date()).prefix(count))
        model.edge = edge
        model.screenSize = CGSize(width: 1512, height: 982)
        return model
    }

    static let suite = TestSuite("Notch geometry", [
        test("folded, the notch is the resting pill; open, the whole shape") { @MainActor in
            let m = model()
            expectEqual(m.notchSize, CGSize(width: NotchLayout.pillWidth, height: NotchLayout.pillHeight))
            m.isExpanded = true
            expectEqual(m.notchSize.height, m.shapeLength)
            expectEqual(m.notchSize.width, NotchLayout.sideBodyDepth)
        },
        test("a top notch grows out of the camera notch") { @MainActor in
            let m = model(edge: .top)
            m.hardwareNotch = HardwareNotch(width: 185, height: 32)
            expectEqual(m.notchSize, CGSize(width: 185, height: 32), "at rest it is exactly the camera notch")
            expectEqual(m.contentInset, 32)
            expectEqual(m.flare, NotchLayout.bezelFillet)
            m.isExpanded = true
            expect(m.shapeLength >= 185, "never narrower than the hole it grows from")
            expectEqual(m.notchDepth, 32 + NotchLayout.bodyDepth(for: .top))
            m.edge = .right
            expectEqual(m.contentInset, 0, "only the top edge joins the camera notch")
        },
        test("the size setting scales the notch but not the camera notch") { @MainActor in
            let m = model(edge: .top)
            m.hardwareNotch = HardwareNotch(width: 185, height: 32)
            m.sizeScale = 1.25
            expectApprox(Double(m.restingLength * m.sizeScale), 185, tolerance: 1e-9)
        },
        test("hovering finds the cell under the pointer") { @MainActor in
            let m = model()
            m.isExpanded = true
            for index in 0..<3 {
                let centre = m.slack + m.ringCenter(index: index) * m.sizeScale
                expectEqual(m.cellIndex(along: centre), index)
            }
            expectNil(m.cellIndex(along: -500))
        },
        test("the orb is hit around its centre only") { @MainActor in
            let m = model()
            m.isExpanded = true
            expect(m.isOnOrb(along: m.orbAlong, across: m.orbInset))
            expect(!m.isOnOrb(along: m.orbAlong - 200, across: m.orbInset))
        },
        test("tooltips stay on the visible part of the panel") { @MainActor in
            let m = model()
            m.visibleAlongRange = 100...600
            expectEqual(m.tooltipAlong(index: 0, length: 200), max(m.slack + m.ringCenter(index: 0), 200))
            m.visibleAlongRange = 0...150
            expectEqual(m.tooltipAlong(index: 2, length: 400), 75, "too small to hold the card: centred")
        },
        test("a long stack on a short screen spends its gaps first") { @MainActor in
            let m = model(count: 4)
            let roomy = m.cellSpacing
            m.screenSize = CGSize(width: 1000, height: 400)
            expect(m.cellSpacing < roomy)
            expect(m.cellSpacing >= 0)
        },
        test("the panel holds the notch, its slack and the card") { @MainActor in
            for edge in NotchEdge.allCases {
                let m = model(edge: edge)
                m.isExpanded = true
                let place = NotchPlacement(edge: edge, panelSize: m.panelSize)
                expectApprox(Double(place.panelLength), Double(m.shapeLength * m.sizeScale + 2 * m.slack), tolerance: 1e-6)
                expect(place.panelDepth > m.notchDrawnDepth + NotchLayout.tailLength, "\(edge)")
            }
        },
    ])
}

enum ShapeTests {
    static let suite = TestSuite("Notch shape", [
        test("the shape reaches the bezel on every edge") {
            let rect = CGRect(x: 0, y: 0, width: 70, height: 300)
            for edge in NotchEdge.allCases {
                let frame = edge.isVertical ? rect : CGRect(x: 0, y: 0, width: 300, height: 70)
                let bounds = SideNotchShape(edge: edge).path(in: frame).boundingRect
                switch edge {
                case .right:  expectApprox(Double(bounds.maxX), 70, tolerance: 0.01)
                case .left:   expectApprox(Double(bounds.minX), 0, tolerance: 0.01)
                case .top:    expectApprox(Double(bounds.minY), 0, tolerance: 0.01)
                case .bottom: expectApprox(Double(bounds.maxY), 70, tolerance: 0.01)
                }
                expect(frame.insetBy(dx: -0.5, dy: -0.5).contains(bounds), "\(edge) stays in its frame")
            }
        },
        test("the flares are inverse: the body's middle is black, the corner pocket is not") {
            let rect = CGRect(x: 0, y: 0, width: 70, height: 300)
            let path = SideNotchShape(edge: .right).path(in: rect)
            expect(path.contains(CGPoint(x: 35, y: 150)))
            expect(!path.contains(CGPoint(x: 2, y: 2)), "the far top corner is outside")
            // The flare leaves the bezel tangentially: hairline-thin at the very
            // top, filling out as it turns in.
            expect(path.contains(CGPoint(x: 69.5, y: 12)), "the flare hugs the screen edge")
            expect(!path.contains(CGPoint(x: 60, y: 12)), "and curves away from it")
        },
        test("a folded pill keeps rounded corners") {
            let pill = CGRect(x: 0, y: 0, width: NotchLayout.pillWidth, height: NotchLayout.pillHeight)
            let path = SideNotchShape(edge: .right).path(in: pill)
            expect(path.contains(CGPoint(x: pill.midX, y: pill.midY)))
            expect(!path.contains(CGPoint(x: 0.3, y: NotchLayout.pillWidth / 2 + 0.3)), "corner is rounded, not square")
        },
    ])
}

enum FullScreenTests {
    static let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)

    static let suite = TestSuite("Full screen", [
        test("a front window covering the display is full screen") {
            expect(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7,
                                                   windows: [(7, 0, screen)]))
        },
        test("below a camera notch still counts") {
            let below = CGRect(x: 0, y: 38, width: 1512, height: 944)
            expect(FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(7, 0, below)],
                                                   safeAreaTopInset: 38))
        },
        test("ordinary and background windows do not") {
            expect(!FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7,
                                                    windows: [(7, 0, CGRect(x: 100, y: 100, width: 800, height: 600))]))
            expect(!FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(8, 0, screen)]))
            expect(!FullScreenDetector.isFullScreen(screenBounds: screen, frontmostPID: 7, windows: [(7, 25, screen)]))
        },
    ])
}
