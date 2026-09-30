// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import AppKit
import CoreGraphics

/// Whether a full-screen app is in front on a display.
///
/// Reads only each window's owner, layer and bounds from the window server —
/// never titles or contents, which also means no Screen Recording permission.
enum FullScreenDetector {
    static func isFullScreen(screenBounds: CGRect, frontmostPID: pid_t,
                             windows: [(pid: pid_t, layer: Int, bounds: CGRect)],
                             safeAreaTopInset: CGFloat = 0) -> Bool {
        for window in windows where window.pid == frontmostPID && window.layer == 0 {
            let b = window.bounds
            guard abs(b.origin.x - screenBounds.origin.x) <= 4, abs(b.width - screenBounds.width) <= 4 else { continue }
            if abs(b.origin.y - screenBounds.origin.y) <= 4 && abs(b.height - screenBounds.height) <= 4 { return true }
            // Full screen below a camera notch or a visible menu bar.
            let maxTopInset = max(safeAreaTopInset, 40) + 4
            let reachesBottom = abs(b.maxY - screenBounds.maxY) <= 4
            let startsNearTop = b.origin.y >= screenBounds.origin.y - 4 && b.origin.y <= screenBounds.origin.y + maxTopInset
            if reachesBottom && startsNearTop && b.height >= screenBounds.height - (maxTopInset + 10) { return true }
        }
        return false
    }

    static func isFullScreenAppFrontmost(on screen: NSScreen?) -> Bool {
        guard let screen, let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier != Bundle.main.bundleIdentifier else { return false }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? screen.frame.height
        let bounds = CGRect(x: screen.frame.minX, y: primaryHeight - screen.frame.maxY,
                            width: screen.frame.width, height: screen.frame.height)
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return false }
        let windows: [(pid: pid_t, layer: Int, bounds: CGRect)] = list.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let rect = CGRect(dictionaryRepresentation: dict as CFDictionary)
            else { return nil }
            return (pid, layer, rect)
        }
        return isFullScreen(screenBounds: bounds, frontmostPID: front.processIdentifier, windows: windows,
                            safeAreaTopInset: screen.safeAreaInsets.top)
    }
}
