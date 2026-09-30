// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import BrimCore
import CoreGraphics

extension NotchEdge {
    /// Where the tooltip goes: away from the bezel, always.
    enum TooltipDirection: Equatable {
        case leading    // card to the left of the notch
        case trailing   // card to the right
        case up         // card above
        case down       // card below
    }

    var tooltipDirection: TooltipDirection {
        switch self {
        case .right:  return .leading
        case .left:   return .trailing
        case .top:    return .down
        case .bottom: return .up
        }
    }

    /// A unit vector toward the bezel in panel coordinates (y grows down): the
    /// way contents slide as the notch folds into the edge.
    var outward: CGPoint {
        switch self {
        case .right:  return CGPoint(x: 1, y: 0)
        case .left:   return CGPoint(x: -1, y: 0)
        case .top:    return CGPoint(x: 0, y: -1)
        case .bottom: return CGPoint(x: 0, y: 1)
        }
    }

    /// A unit vector along the stack, perpendicular to `outward`.
    var alongDirection: CGPoint {
        isVertical ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
    }

    var explanation: String {
        switch self {
        case .right:  return "Attached to the right-hand edge. Option-drag to move it up or down."
        case .left:   return "Attached to the left-hand edge. Option-drag to move it up or down."
        case .top:    return "A bar across the top, readings side by side. On a Mac with a camera notch it grows out of it."
        case .bottom: return "Attached to the bottom edge. Option-drag to move it left or right."
        }
    }
}

/// The one place in the notch that knows which way round the axes are.
///
/// Everything else works in stack space: `along` runs the length of the stack
/// and `across` measures inward from the bezel, so zero is always the screen
/// edge. This turns those into panel coordinates (origin top-left, as in a
/// flipped hosting view and in SwiftUI).
struct NotchPlacement {
    let edge: NotchEdge
    let panelSize: CGSize

    func point(along: CGFloat, across: CGFloat) -> CGPoint {
        switch edge {
        case .right:  return CGPoint(x: panelSize.width - across, y: along)
        case .left:   return CGPoint(x: across, y: along)
        case .top:    return CGPoint(x: along, y: across)
        case .bottom: return CGPoint(x: along, y: panelSize.height - across)
        }
    }

    /// A rect spanning `depth` inward from `across`, so a region anchored at
    /// the bezel never hangs off the far side of it.
    func rect(along: CGFloat, across: CGFloat, length: CGFloat, depth: CGFloat) -> CGRect {
        switch edge {
        case .right:
            return CGRect(x: panelSize.width - across - depth, y: along, width: depth, height: length)
        case .left:
            return CGRect(x: across, y: along, width: depth, height: length)
        case .top:
            return CGRect(x: along, y: across, width: length, height: depth)
        case .bottom:
            return CGRect(x: along, y: panelSize.height - across - depth, width: length, height: depth)
        }
    }

    static func panelSize(edge: NotchEdge, length: CGFloat, depth: CGFloat) -> CGSize {
        edge.isVertical ? CGSize(width: depth, height: length) : CGSize(width: length, height: depth)
    }

    func along(of point: CGPoint) -> CGFloat {
        edge.isVertical ? point.y : point.x
    }

    func across(of point: CGPoint) -> CGFloat {
        switch edge {
        case .right:  return panelSize.width - point.x
        case .left:   return point.x
        case .top:    return point.y
        case .bottom: return panelSize.height - point.y
        }
    }

    var panelLength: CGFloat { edge.isVertical ? panelSize.height : panelSize.width }
    var panelDepth: CGFloat { edge.isVertical ? panelSize.width : panelSize.height }
}
