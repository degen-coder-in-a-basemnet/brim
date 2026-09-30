import AppKit
import BrimCore
import Combine
import SwiftUI

/// Everything one notch draws, and the geometry that places it.
///
/// Two coordinate spaces meet here. **Shape space** is the notch at design
/// size — every `NotchLayout` number is in it. **Panel space** is points in the
/// window, after the size setting (`sizeScale`) and the slack at each end.
/// Properties say which they return.
@MainActor
final class NotchViewModel: ObservableObject {
    // Readings
    @Published var snapshots: [ProviderSnapshot] = []
    @Published var activity: [String: ActivitySummary] = [:]
    @Published var refreshing: Set<String> = []
    @Published var now = Date()

    // State
    @Published var isExpanded = false
    @Published var hoveredIndex: Int?
    @Published var isHoveringSettings = false
    /// Held open by a click on the body or "Keep open".
    @Published var isPinned = false
    /// A peek in progress: the session it announces, for the tooltip.
    @Published var peekSessionID: String?
    /// Providers with a waiting session nobody has acknowledged. The same on
    /// every display: the fleet owns it.
    @Published var waitingProviders: Set<String> = []
    @Published var settingsSpins = 0

    // Appearance
    @Published var edge: NotchEdge = .right
    @Published var sizeScale: CGFloat = 1
    @Published var accent: Color = Palette.ample
    @Published var resetFormat: ResetTimeFormat = .automatic
    @Published var isAlwaysOn = false
    @Published var hardwareNotch: HardwareNotch?
    @Published var screenSize: CGSize = .zero
    /// The part of the panel on screen, along the stack, in panel space.
    @Published var visibleAlongRange: ClosedRange<CGFloat>?

    var onOpenSettings: (() -> Void)?
    var onFocusSession: ((AgentSession) -> Void)?

    // MARK: - Joining the hardware notch

    /// The camera notch, when this notch grows out of it (top edge only).
    var joinedNotch: HardwareNotch? { edge == .top ? hardwareNotch : nil }

    /// The hardware notch measured in shape space, so that after scaling it is
    /// exactly the hole in the display.
    var shapeHardwareNotch: HardwareNotch? {
        joinedNotch.map { HardwareNotch(width: $0.width / sizeScale, height: $0.height / sizeScale) }
    }

    /// How far in from the bezel the readings start: below the hole, when
    /// there is one. Shape space.
    var contentInset: CGFloat { shapeHardwareNotch?.height ?? 0 }

    var flare: CGFloat { joinedNotch == nil ? NotchLayout.curlRadius : NotchLayout.bezelFillet }

    var drawnCornerRadius: CGFloat {
        guard let notch = shapeHardwareNotch else { return NotchLayout.cornerRadius }
        return min(NotchLayout.cornerRadius, notch.height / 2)
    }

    var notchShape: SideNotchShape {
        SideNotchShape(edge: edge, joining: shapeHardwareNotch, cornerRadius: drawnCornerRadius)
    }

    // MARK: - Stack geometry (shape space)

    var cellSpacing: CGFloat {
        guard edge.isVertical, screenSize.height > 0, snapshots.count > 1 else { return NotchLayout.cellSpacing }
        // A long stack on a short screen spends its gaps first.
        let packed = NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge, flare: flare, spacing: 0)
        let room = screenSize.height / sizeScale - 2 * NotchLayout.endSlack
        return min(NotchLayout.cellSpacing, max(0, (room - packed) / CGFloat(snapshots.count - 1)))
    }

    /// Extra length at each end so a bar joined to the hardware is never
    /// narrower than the hole it grows from.
    var endSpread: CGFloat {
        guard let notch = shapeHardwareNotch else { return 0 }
        let base = NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge, flare: flare, spacing: cellSpacing)
        return max(0, (notch.width + 2 * NotchLayout.cornerRadius - base) / 2)
    }

    var shapeLength: CGFloat {
        NotchLayout.shapeLength(cellCount: snapshots.count, edge: edge, flare: flare, spacing: cellSpacing) + 2 * endSpread
    }

    func ringCenter(index: Int) -> CGFloat {
        NotchLayout.ringCenter(index: index, edge: edge, flare: flare, spacing: cellSpacing) + endSpread
    }

    var cellsLeadIn: CGFloat { flare + endSpread + NotchLayout.padStart(for: edge) }

    var restingLength: CGFloat { shapeHardwareNotch?.width ?? NotchLayout.pillHeight }
    var restingDepth: CGFloat { shapeHardwareNotch?.height ?? NotchLayout.pillWidth }

    var notchLength: CGFloat { isExpanded ? shapeLength : restingLength }
    var notchDepth: CGFloat { isExpanded ? contentInset + NotchLayout.bodyDepth(for: edge) : restingDepth }
    var notchSize: CGSize { NotchPlacement.panelSize(edge: edge, length: notchLength, depth: notchDepth) }

    // MARK: - The orb (shape space)

    var orbHugsCorner: Bool { joinedNotch != nil }

    var orbAlong: CGFloat {
        guard orbHugsCorner else { return shapeLength }
        return shapeLength - flare - drawnCornerRadius + NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
    }

    var orbInset: CGFloat {
        guard orbHugsCorner else { return contentInset + NotchLayout.curlRadius }
        let foot = contentInset + NotchLayout.bodyDepth(for: edge)
        return foot - drawnCornerRadius + NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
    }

    var orbArcRadius: CGFloat {
        orbHugsCorner ? NotchLayout.orbConvexArcRadius(corner: drawnCornerRadius) : NotchLayout.orbArcRadius
    }

    /// Where the resting arc sits relative to the button: on the corner it
    /// hugs, when the button hangs clear of a flush bar.
    var orbArcOffset: CGSize {
        guard orbHugsCorner else { return .zero }
        let inward = CGPoint(x: -edge.outward.x, y: -edge.outward.y)
        let back = -NotchLayout.orbCornerOffset(corner: drawnCornerRadius)
        return CGSize(width: back * (edge.alongDirection.x + inward.x),
                      height: back * (edge.alongDirection.y + inward.y))
    }

    var orbMergeScale: CGFloat { orbHugsCorner ? 0.6 : NotchLayout.orbMergeScale }

    func isOnOrb(along: CGFloat, across: CGFloat) -> Bool {
        hypot(along - orbAlong, across - orbInset) <= NotchLayout.orbHotZone / 2
    }

    // MARK: - The tooltip

    var maxCardHeight: CGFloat {
        let tallest = snapshots.map { cardHeight(for: $0) }.max() ?? 0
        return max(tallest, NotchLayout.cardHeight(
            for: ProviderSnapshot(id: "-", kind: .manual, displayName: "-", glyph: .monogram("-"), fidelity: .manual),
            sessionCount: 0, now: now))
    }

    func cardHeight(for snapshot: ProviderSnapshot) -> CGFloat {
        NotchLayout.cardHeight(for: snapshot, sessionCount: activity[snapshot.id]?.sessions.count ?? 0, now: now)
    }

    /// Panel-space padding at each end of the stack.
    var slack: CGFloat { NotchLayout.slack(for: edge, maxCardHeight: maxCardHeight) }

    /// The drawn notch's depth in panel space, where the card's region begins.
    var notchDrawnDepth: CGFloat { (contentInset + NotchLayout.bodyDepth(for: edge)) * sizeScale }

    var tooltipInset: CGFloat { notchDrawnDepth + NotchLayout.tailGap }

    /// The card's centre along the stack, kept on screen.
    func tooltipAlong(index: Int, length: CGFloat) -> CGFloat {
        let centre = slack + ringCenter(index: index) * sizeScale
        guard let range = visibleAlongRange else { return centre }
        let lower = range.lowerBound + length / 2
        let upper = range.upperBound - length / 2
        guard lower <= upper else { return (range.lowerBound + range.upperBound) / 2 }
        return min(max(centre, lower), upper)
    }

    // MARK: - The panel

    var panelSize: CGSize {
        NotchPlacement.panelSize(
            edge: edge,
            length: shapeLength * sizeScale + 2 * slack,
            depth: notchDrawnDepth + NotchLayout.tooltipDepth(for: edge, maxCardHeight: maxCardHeight))
    }

    var hoveredSnapshot: ProviderSnapshot? {
        guard let hoveredIndex, snapshots.indices.contains(hoveredIndex) else { return nil }
        return snapshots[hoveredIndex]
    }

    func activity(for snapshot: ProviderSnapshot) -> ActivitySummary? {
        activity[snapshot.id]
    }

    func isRefreshing(_ snapshot: ProviderSnapshot) -> Bool {
        refreshing.contains(snapshot.id)
    }

    func needsAttention(_ snapshot: ProviderSnapshot) -> Bool {
        waitingProviders.contains(snapshot.id)
    }

    /// Whether any ring on this notch is asking.
    var isAskingForAttention: Bool {
        snapshots.contains { waitingProviders.contains($0.id) }
    }

    /// The cell under a point along the stack, in panel space.
    func cellIndex(along: CGFloat) -> Int? {
        let pitch = (NotchLayout.cellAlong(for: edge) + cellSpacing) * sizeScale
        for index in snapshots.indices {
            let centre = slack + ringCenter(index: index) * sizeScale
            if abs(along - centre) <= pitch / 2 { return index }
        }
        return nil
    }
}
