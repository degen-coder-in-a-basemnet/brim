// Adapted from Codenotch (https://github.com/vinzdg/codenotch), MIT License,
// Copyright (c) 2026 Vinz. See THIRD_PARTY_NOTICES.md.
import AppKit
import SwiftUI

/// A borderless, non-activating panel above everything, full-screen apps
/// included. Glancing at the notch must never take focus from your work.
final class NotchPanel: NSPanel {
    /// Supplies the right-click menu. Handled here because `sendEvent` sees
    /// every event before a SwiftUI subview can swallow it.
    var contextMenuProvider: ((CGPoint) -> NSMenu?)?
    /// A left click on the visible chrome, in window coordinates, with AppKit's
    /// click count so a double-click can be told from two single clicks.
    var onClick: ((CGPoint, Int) -> Void)?
    /// ⌥-drag on the chrome, reported as raw pointer deltas.
    var onDragStart: (() -> Void)?
    var onDrag: ((CGFloat, CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Clicks inside this region go to SwiftUI (the card's session rows);
    /// everything else on the chrome is handled by the controller.
    var routesToContent: ((CGPoint) -> Bool)?

    override func sendEvent(_ event: NSEvent) {
        guard let view = contentView, view.hitTest(event.locationInWindow) != nil else {
            return super.sendEvent(event)
        }
        switch event.type {
        case .rightMouseDown:
            if let menu = contextMenuProvider?(event.locationInWindow) {
                NSMenu.popUpContextMenu(menu, with: event, for: view)
            } else {
                super.sendEvent(event)
            }
        case .leftMouseDown:
            if routesToContent?(event.locationInWindow) == true { return super.sendEvent(event) }
            if event.modifierFlags.contains(.option), onDrag != nil {
                trackOptionDrag()
            } else {
                onClick?(event.locationInWindow, event.clickCount)
            }
        default:
            super.sendEvent(event)
        }
    }

    /// The standard pattern for a drag begun in a mouse-down: consume this
    /// window's events until the button lifts. An ⌥-drag never becomes a click.
    private func trackOptionDrag() {
        onDragStart?()
        while let next = nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp {
                onDragEnd?()
                return
            }
            onDrag?(next.deltaX, next.deltaY)
        }
    }
}

/// The panel's content view. It holds the hosting view so SwiftUI never gets a
/// say in the window's size, and it never claims a hit for itself — most of the
/// panel is empty room for the tooltip and must pass clicks through.
final class NotchContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for subview in subviews.reversed() {
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }
}

/// Only the currently visible chrome receives events.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    /// In view coordinates; the hosting view is flipped, so top-left origin.
    var interactiveRects: [CGRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return super.hitTest(point)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let local = convert(event.locationInWindow, from: nil)
        guard interactiveRects.contains(where: { $0.contains(local) }) else { return nil }
        return menu
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
