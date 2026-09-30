// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import AppKit
import BrimCore

/// The display's own camera notch — not ours.
struct HardwareNotch: Equatable {
    let width: CGFloat
    let height: CGFloat

    /// The cutout's depth from every signal AppKit offers. `safeAreaInsets.top`
    /// alone collapses when the menu bar auto-hides, but the strips beside the
    /// notch keep reporting its height.
    static func height(safeAreaTop: CGFloat, beside strips: [CGFloat]) -> CGFloat {
        max(safeAreaTop, strips.max() ?? 0)
    }
}

/// What the geometry needs from a screen, so tests can fake one.
protocol ScreenDescribing {
    var frameValue: CGRect { get }
    var hardwareNotch: HardwareNotch? { get }
    var displayIdentifier: String? { get }
}

extension NSScreen: ScreenDescribing {
    var frameValue: CGRect { frame }

    /// Survives reconfiguration and restarts, so a saved choice still names the
    /// same monitor.
    var displayIdentifier: String? {
        guard let number = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let unmanaged = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)
        else { return nil }
        return CFUUIDCreateString(nil, unmanaged.takeRetainedValue()) as String
    }

    /// Measured from the menu-bar strips either side of the notch; a display
    /// without one reports no auxiliary areas.
    var hardwareNotch: HardwareNotch? {
        guard let left = auxiliaryTopLeftArea, let right = auxiliaryTopRightArea else { return nil }
        let width = frame.width - left.width - right.width
        let height = HardwareNotch.height(safeAreaTop: safeAreaInsets.top, beside: [left.height, right.height])
        guard width > 0, height > 0 else { return nil }
        return HardwareNotch(width: width, height: height)
    }
}

enum NotchGeometry {
    /// The panel's frame, anchored to the physical display edge so showing or
    /// hiding the Dock never moves it.
    ///
    /// `alongOffset` slides it along the edge from the centre: down the screen
    /// for vertical edges, right for horizontal ones. `slack` is the padding
    /// each end of the panel carries for a card; the clamp keeps the visible
    /// notch on screen while letting that padding run past the bezel.
    static func panelFrame(for screen: ScreenDescribing, panelSize: CGSize, edge: NotchEdge,
                           alongOffset: CGFloat = 0, slack: CGFloat = 0) -> CGRect {
        let full = screen.frameValue
        let width = panelSize.width.rounded(.up)
        let height = panelSize.height.rounded(.up)
        let origin: CGPoint
        switch edge {
        case .right, .left:
            let y = clamp(full.midY - height / 2 - alongOffset, min: full.minY - slack, max: full.maxY - height + slack)
            origin = CGPoint(x: edge == .right ? full.maxX - width : full.minX, y: y)
        case .top, .bottom:
            let x = clamp(full.midX - width / 2 + alongOffset, min: full.minX - slack, max: full.maxX - width + slack)
            origin = CGPoint(x: x, y: edge == .top ? full.maxY - height : full.minY)
        }
        return CGRect(x: origin.x.rounded(), y: origin.y.rounded(), width: width, height: height)
    }

    /// The largest offset either way that keeps the notch on screen.
    static func offsetLimit(for screen: ScreenDescribing, panelSize: CGSize, edge: NotchEdge, slack: CGFloat) -> CGFloat {
        let full = screen.frameValue
        let visible = (edge.isVertical ? panelSize.height : panelSize.width) - 2 * slack
        let room = (edge.isVertical ? full.height : full.width) - visible
        return max(0, room / 2)
    }

    static func clamp(_ value: CGFloat, min lo: CGFloat, max hi: CGFloat) -> CGFloat {
        guard lo <= hi else { return lo }
        return Swift.min(Swift.max(value, lo), hi)
    }

    /// Which screens get a notch.
    static func targetScreens<Screen: ScreenDescribing>(from screens: [Screen], scope: DisplayScope,
                                                        chosenID: String?, main: Screen?) -> [Screen] {
        switch scope {
        case .all:
            return screens
        case .specific:
            if let chosenID, let match = screens.first(where: { $0.displayIdentifier == chosenID }) {
                return [match]
            }
            return main.map { [$0] } ?? Array(screens.prefix(1))
        case .main:
            return main.map { [$0] } ?? Array(screens.prefix(1))
        }
    }
}
