// Hover, fold and click behaviour adapted from Codenotch
// (https://github.com/vinzdg/codenotch), MIT License, Copyright (c) 2026 Vinz.
// See THIRD_PARTY_NOTICES.md.
import AppKit
import BrimCore
import Combine
import SwiftUI

/// What the notch can ask the rest of the app to do.
@MainActor
struct NotchActions {
    var refresh: (String) -> Void = { _ in }
    var refreshAll: () -> Void = {}
    var openUsagePage: (String) -> Void = { _ in }
    var openSettings: () -> Void = {}
    /// Brings forward the app a session's own process runs in. False when
    /// nothing came forward: no process, or it has gone.
    var focusSession: (AgentSession) -> Bool = { _ in false }
    /// Brings a provider's own app forward, opening it where that is its job.
    var openProviderApp: (ProviderApp) -> Bool = { _ in false }
    var saveOffset: (NotchEdge, CGFloat) -> Void = { _, _ in }
    var recentre: () -> Void = {}
    var hideForAnHour: () -> Void = {}
    var toggleDemo: () -> Void = {}
    var isDemo: () -> Bool = { false }
    var ringClickAction: () -> RingClickAction = { .refresh }
    var clickFocusesSession: () -> Bool = { true }
    var adjustManual: (String, String, Double) -> Void = { _, _, _ in }
    var resetManual: (String) -> Void = { _ in }
    var manualConfig: (String) -> ManualProviderConfig? = { _ in nil }
    var usagePage: (String) -> URL? = { _ in nil }
    /// A waiting provider's ring was clicked: it stops asking, on every display.
    var acknowledgeWaiting: (String) -> Void = { _ in }
    /// The waiting session behind a provider's ring, for a double-click to raise.
    var waitingSession: (String) -> AgentSession? = { _ in nil }
    /// One waiting session's row was clicked: that session stops asking.
    var acknowledgeSession: (AgentSession) -> Void = { _ in }
    /// Whether a session's process still runs. Asked at the click, never kept.
    var isProcessRunning: (Int32) -> Bool = { SessionFocus.isRunning($0) }
}

/// One notch on one display: its panel, its hover state, its clicks.
@MainActor
final class NotchController {
    let model = NotchViewModel()
    var screen: NSScreen
    var actions = NotchActions()

    private var panel: NotchPanel?
    private var hosting: NotchHostingView<NotchRootView>?
    private var monitors: [Any] = []
    private var cursorTimer: Timer?
    private var clockTimer: Timer?
    private var fullScreenTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    /// Hover in is quick; hover out waits, because the pointer has to cross
    /// the gap between cell and card without the card vanishing under it.
    static let hoverGrace: TimeInterval = 0.25
    /// Folding shut is a bigger movement than dismissing a card, so it waits
    /// longer before it believes the pointer has gone.
    static let foldGrace: TimeInterval = 0.45

    private var clearHoverWork: DispatchWorkItem?
    private var foldWork: DispatchWorkItem?
    private var peekWork: DispatchWorkItem?
    private var peekUntil: Date?
    private var pendingFocus: (session: AgentSession, until: Date)?
    /// A waiting session holds the notch open, whatever the pointer does,
    /// until its ring is clicked.
    private var attentionHoldsOpen = false
    /// The ring the current click sequence began on, when its latest click
    /// came, and the waiting session its first click acknowledged, so the
    /// second click of a double-click knows where it is.
    private var ringSequence: (providerID: String, at: Date, session: AgentSession?)?
    /// A quiet ring's single-click action, held for the double-click interval
    /// so that the first click of a double-click never refreshes.
    private var heldRingClick: (providerID: String, clickedAt: Date, work: DispatchWorkItem)?
    /// Read at every click, so a change in System Settings applies at once.
    var doubleClickInterval: () -> TimeInterval = { NSEvent.doubleClickInterval }
    /// Folded on purpose under a resting pointer: stays folded until it leaves.
    private var foldedUnderPointer = false
    private var isPointing = false
    private var isDragging = false
    private var dragOffset: CGFloat = 0
    private(set) var alongOffset: CGFloat = 0
    private var hiddenForFullScreen = false
    var foldsForFullScreen = true
    private(set) var isShown = false

    init(screen: NSScreen) {
        self.screen = screen
        model.onOpenSettings = { [weak self] in self?.actions.openSettings() }
        model.onFocusSession = { [weak self] session in self?.focusRow(session) }
    }

    // MARK: - Showing

    func show() {
        guard !isShown else { return }
        isShown = true
        relocate()
        panel?.orderFrontRegardless()
        startWatching()
        if attentionHoldsOpen { holdOpenForAttention() }
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        stopWatching()
        panel?.orderOut(nil)
        setPointing(false)
    }

    func tearDown() {
        hide()
        panel?.close()
        panel = nil
        hosting = nil
        cancellables.removeAll()
    }

    func setAlongOffset(_ offset: CGFloat) {
        alongOffset = offset
        relocate()
    }

    /// Re-sizes and re-places the panel from the model's current geometry.
    func relocate() {
        model.hardwareNotch = screen.hardwareNotch
        model.screenSize = screen.frame.size
        let size = model.panelSize
        let frame = NotchGeometry.panelFrame(for: screen, panelSize: size, edge: model.edge,
                                             alongOffset: alongOffset, slack: model.slack)
        if let panel {
            if panel.frame != frame { panel.setFrame(frame, display: true) }
        } else {
            let panel = NotchPanel(contentRect: frame)
            let hosting = NotchHostingView(rootView: NotchRootView(model: model))
            let container = NotchContainerView(frame: CGRect(origin: .zero, size: frame.size))
            container.autoresizingMask = [.width, .height]
            hosting.frame = container.bounds
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.ignoresMouseEvents = true
            panel.contextMenuProvider = { [weak self] point in self?.contextMenu(at: point) }
            panel.onClick = { [weak self] point, clickCount in self?.handleClick(at: point, clickCount: clickCount) }
            panel.routesToContent = { [weak self] point in self?.isOverTooltip(windowPoint: point) ?? false }
            panel.onDragStart = { [weak self] in self?.beginDrag() }
            panel.onDrag = { [weak self] dx, dy in self?.dragged(dx: dx, dy: dy) }
            panel.onDragEnd = { [weak self] in self?.endDrag() }
            self.panel = panel
            self.hosting = hosting
            if isShown { panel.orderFrontRegardless() }
        }
        if let panel {
            let visible = panel.frame.intersection(screen.frame)
            let range: ClosedRange<CGFloat> = model.edge.isVertical
                ? (panel.frame.maxY - visible.maxY)...(panel.frame.maxY - visible.minY)
                : (visible.minX - panel.frame.minX)...(visible.maxX - panel.frame.minX)
            if !visible.isNull, model.visibleAlongRange != range { model.visibleAlongRange = range }
        }
        updateInteractiveRects()
    }

    // MARK: - Regions (panel space, top-left origin)

    private var placement: NotchPlacement {
        NotchPlacement(edge: model.edge, panelSize: panel?.frame.size ?? model.panelSize)
    }

    private var notchRect: CGRect {
        placement.rect(along: model.slack, across: 0, length: model.shapeLength * model.sizeScale,
                       depth: model.notchDrawnDepth)
    }

    /// The resting pill's wake region: larger than the pill, which is a sliver.
    private var pillRect: CGRect {
        let joined = model.joinedNotch != nil
        let band = joined ? 0 : NotchLayout.pillHotZone
        let length = max(model.restingLength * model.sizeScale, band)
        let depth = model.restingDepth * model.sizeScale + band
        return placement.rect(along: model.slack + (model.shapeLength * model.sizeScale - length) / 2,
                              across: 0, length: length, depth: depth)
    }

    private var orbRect: CGRect {
        let side = NotchLayout.orbHotZone * model.sizeScale
        let centre = placement.point(along: model.slack + model.orbAlong * model.sizeScale,
                                     across: model.orbInset * model.sizeScale)
        return CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side)
    }

    private var liveRect: CGRect {
        model.isExpanded ? notchRect.union(orbRect) : pillRect
    }

    private func tooltipRect(index: Int) -> CGRect? {
        guard model.snapshots.indices.contains(index) else { return nil }
        let height = model.cardHeight(for: model.snapshots[index])
        let across = model.edge.isVertical ? NotchLayout.cardWidth : height
        let along = model.edge.isVertical ? height : NotchLayout.cardWidth
        let centre = model.tooltipAlong(index: index, length: along)
        return placement.rect(along: centre - along / 2, across: model.notchDrawnDepth, length: along,
                              depth: NotchLayout.tailGap + NotchLayout.tailLength + across)
    }

    private func isOverOrb(_ local: CGPoint) -> Bool {
        model.isOnOrb(along: (placement.along(of: local) - model.slack) / model.sizeScale,
                      across: placement.across(of: local) / model.sizeScale)
    }

    private func localCursor() -> CGPoint? {
        guard let frame = panel?.frame else { return nil }
        let mouse = NSEvent.mouseLocation
        return CGPoint(x: mouse.x - frame.minX, y: frame.maxY - mouse.y)
    }

    private func local(fromWindow point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (panel?.frame.height ?? 0) - point.y)
    }

    private func isOverTooltip(windowPoint: CGPoint) -> Bool {
        guard model.isExpanded, let index = model.hoveredIndex, let rect = tooltipRect(index: index) else { return false }
        return rect.contains(local(fromWindow: windowPoint))
    }

    private func updateInteractiveRects() {
        var rects = [liveRect]
        if model.isExpanded, let index = model.hoveredIndex, let card = tooltipRect(index: index) { rects.append(card) }
        hosting?.interactiveRects = rects
        guard let panel else { return }
        let ignores = hiddenForFullScreen || !(localCursor().map { point in rects.contains { $0.contains(point) } } ?? false)
        if panel.ignoresMouseEvents != ignores { panel.ignoresMouseEvents = ignores }
    }

    // MARK: - Watching the pointer

    private func startWatching() {
        let events: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: events, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: events, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.cursorMoved() }
            return event
        }) { monitors.append(local) }

        // A pointer that never moves makes no events; the poll catches a notch
        // that appears or resizes under a parked pointer.
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.cursorMoved() }
        }
        clockTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Every second while a card is open (session timers), every
                // thirty otherwise (reset countdowns).
                if self.model.hoveredIndex != nil || Int(Date().timeIntervalSince1970) % 30 == 0 {
                    self.model.now = Date()
                }
            }
        }
        fullScreenTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkFullScreen() }
        }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            center.publisher(for: name).sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkFullScreen()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self?.checkFullScreen() }
                }
            }.store(in: &cancellables)
        }
        checkFullScreen()
    }

    private func stopWatching() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        cursorTimer?.invalidate()
        clockTimer?.invalidate()
        fullScreenTimer?.invalidate()
        cancellables.removeAll()
    }

    func cursorMoved() {
        guard isShown, !isDragging, !hiddenForFullScreen, let local = localCursor() else { return }
        if foldedUnderPointer {
            guard !liveRect.contains(local) else { return }
            foldedUnderPointer = false
        }
        let overCard = model.hoveredIndex.flatMap(tooltipRect(index:)).map { model.isExpanded && $0.contains(local) } ?? false
        setExpanded(liveRect.contains(local) || overCard)

        var target: Int?
        if model.isExpanded, notchRect.contains(local) {
            target = model.cellIndex(along: placement.along(of: local))
        } else if model.isExpanded, overCard {
            target = model.hoveredIndex
        }

        let overOrb = model.isExpanded && isOverOrb(local)
        if model.isHoveringSettings != overOrb { model.isHoveringSettings = overOrb }
        setPointing((model.isExpanded && target != nil && !overCard) || overOrb)

        if let target {
            clearHoverWork?.cancel()
            clearHoverWork = nil
            if model.hoveredIndex != target {
                withAnimation(NotchMotion.hoverIn) { model.hoveredIndex = target }
            }
        } else if model.hoveredIndex != nil, clearHoverWork == nil, peekUntil.map({ $0 < Date() }) ?? true {
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearHoverWork = nil
                    withAnimation(NotchMotion.hoverOut) { self.model.hoveredIndex = nil }
                    self.updateInteractiveRects()
                }
            }
            clearHoverWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.hoverGrace, execute: work)
        }
        updateInteractiveRects()
    }

    /// Opens on contact, folds after a pause — unless pinned, always shown,
    /// mid-peek, or held open by a waiting session, in which case the pointer
    /// does not decide.
    private func setExpanded(_ wanted: Bool) {
        if wanted {
            foldWork?.cancel()
            foldWork = nil
            guard !model.isExpanded else { return }
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
            relocate()
            return
        }
        if let peekUntil, peekUntil > Date() { return }
        if attentionHoldsOpen { return }
        guard model.isExpanded, foldWork == nil, !model.isPinned, !model.isAlwaysOn else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.foldWork = nil
                guard !self.model.isPinned, !self.model.isAlwaysOn, !self.attentionHoldsOpen else { return }
                withAnimation(NotchMotion.unfold) {
                    self.model.isExpanded = false
                    self.model.hoveredIndex = nil
                    self.model.isHoveringSettings = false
                }
                self.setPointing(false)
                self.updateInteractiveRects()
            }
        }
        foldWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.foldGrace, execute: work)
    }

    func applyAlwaysOn(_ alwaysOn: Bool) {
        model.isAlwaysOn = alwaysOn
        if alwaysOn {
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        } else if !model.isPinned {
            setExpanded(false)
        }
        relocate()
    }

    /// Pushed and popped, so leaving restores whatever cursor the app beneath
    /// had chosen.
    private func setPointing(_ wanted: Bool) {
        guard wanted != isPointing else { return }
        isPointing = wanted
        wanted ? NSCursor.pointingHand.push() : NSCursor.pop()
    }

    // MARK: - Full screen

    private func checkFullScreen() {
        let hide = foldsForFullScreen && isShown && FullScreenDetector.isFullScreenAppFrontmost(on: screen)
        guard hide != hiddenForFullScreen else { return }
        hiddenForFullScreen = hide
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel?.animator().alphaValue = hide ? 0 : 1
        }
        if hide {
            model.isExpanded = model.isAlwaysOn
            model.hoveredIndex = nil
        } else if attentionHoldsOpen {
            holdOpenForAttention()
        }
        updateInteractiveRects()
    }

    // MARK: - Peeking

    /// Opens the notch for a moment to announce a session, showing that
    /// provider's card with the session marked. A click while it is open (or
    /// just after) raises the app the session runs in.
    func peek(for duration: TimeInterval, event: SessionEvent) {
        guard isShown, !hiddenForFullScreen else { return }
        let until = Date().addingTimeInterval(duration)
        peekUntil = until
        pendingFocus = (event.session, until.addingTimeInterval(2))
        model.peekSessionID = event.session.id
        foldWork?.cancel()
        foldWork = nil
        clearHoverWork?.cancel()
        clearHoverWork = nil
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = true
            model.hoveredIndex = model.snapshots.firstIndex { $0.id == event.session.providerID }
        }
        relocate()
        peekWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.peekUntil = nil
                self.peekWork = nil
                self.model.peekSessionID = nil
                // Left open if the pointer is already on it.
                if let local = self.localCursor(), self.liveRect.contains(local) { return }
                self.setExpanded(false)
                if !self.model.isExpanded || self.model.isPinned || self.model.isAlwaysOn || self.attentionHoldsOpen {
                    withAnimation(NotchMotion.hoverOut) { self.model.hoveredIndex = nil }
                }
            }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: work)
    }

    // MARK: - Waiting for you

    /// The rings asking for attention, pushed by the fleet. `open` says asking
    /// has just begun and should unfold the notch. It then stays open, with the
    /// stack showing and no card forced up, until nothing on it is asking.
    func setAttention(_ providers: Set<String>, open: Bool) {
        if model.waitingProviders != providers { model.waitingProviders = providers }
        guard model.isAskingForAttention else {
            guard attentionHoldsOpen else { return }
            attentionHoldsOpen = false
            // Back to ordinary hover: open under the pointer, folding after the
            // usual pause once it is away.
            cursorMoved()
            return
        }
        if open { attentionHoldsOpen = true }
        if attentionHoldsOpen { holdOpenForAttention() }
    }

    private func holdOpenForAttention() {
        guard isShown, !hiddenForFullScreen else { return }
        foldWork?.cancel()
        foldWork = nil
        foldedUnderPointer = false
        guard !model.isExpanded else { return }
        withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        relocate()
    }

    /// Once the session's app is forward the notch gets out of its way, and
    /// stays folded under a resting pointer until the pointer leaves.
    private func foldAfterFocus() {
        guard !model.isPinned, !model.isAlwaysOn, !attentionHoldsOpen else { return }
        foldWork?.cancel()
        foldWork = nil
        clearHoverWork?.cancel()
        clearHoverWork = nil
        foldedUnderPointer = true
        withAnimation(NotchMotion.unfold) {
            model.isExpanded = false
            model.hoveredIndex = nil
            model.isHoveringSettings = false
        }
        setPointing(false)
        updateInteractiveRects()
    }

    // MARK: - Clicks

    private func handleClick(at windowPoint: CGPoint, clickCount: Int) {
        let local = local(fromWindow: windowPoint)
        var ring: String?
        if model.isExpanded, notchRect.contains(local), !isOverOrb(local),
           let index = model.cellIndex(along: placement.along(of: local)), model.snapshots.indices.contains(index) {
            ring = model.snapshots[index].id
        }
        if ringClicked(ring, clickCount: clickCount) { return }

        foldedUnderPointer = false
        if focusPeekedSession(clickedAt: Date()) { return }
        guard model.isExpanded else {
            setExpanded(true)
            return
        }
        if isOverOrb(local) {
            model.settingsSpins += 1
            actions.openSettings()
            return
        }
        togglePinned()
    }

    /// A click as far as the rings go: `ring` is the one under the pointer, nil
    /// when there is none. False when the click is the notch's own business.
    @discardableResult
    func ringClicked(_ ring: String?, clickCount: Int, at now: Date = Date()) -> Bool {
        // A new sequence: a single click still held is final.
        if clickCount == 1 { releaseHeldRingClick() }
        let sequence = ringSequence
        switch RingClick.outcome(ringID: ring, clickCount: clickCount, asking: model.waitingProviders,
                                 sequence: sequence.map { ($0.providerID, $0.at) }, now: now,
                                 doubleClickInterval: doubleClickInterval()) {
        case .acknowledge(let id):
            ringSequence = (id, now, actions.waitingSession(id))
            actions.acknowledgeWaiting(id)
        case .single(let id):
            ringSequence = (id, now, nil)
            holdRingClick(id, clickedAt: now)
        case .focus(let id):
            cancelHeldRingClick()
            ringSequence = (id, now, nil)
            focusRing(id, remembered: sequence?.providerID == id ? sequence?.session : nil)
        case .ignore:
            ringSequence?.at = now
        case .ordinary:
            ringSequence = nil
            return false
        }
        return true
    }

    private func holdRingClick(_ id: String, clickedAt: Date) {
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.releaseHeldRingClick() }
        }
        heldRingClick = (id, clickedAt, work)
        DispatchQueue.main.asyncAfter(deadline: .now() + doubleClickInterval(), execute: work)
    }

    /// Carries out the held single click now: no second click can join it.
    private func releaseHeldRingClick() {
        guard let held = heldRingClick else { return }
        heldRingClick = nil
        held.work.cancel()
        if focusPeekedSession(clickedAt: held.clickedAt) { return }
        switch actions.ringClickAction() {
        case .refresh:       actions.refresh(held.providerID)
        case .openUsagePage: actions.openUsagePage(held.providerID)
        }
    }

    private func cancelHeldRingClick() {
        heldRingClick?.work.cancel()
        heldRingClick = nil
    }

    /// A click while a session peeks goes to that session.
    private func focusPeekedSession(clickedAt: Date) -> Bool {
        guard let pending = pendingFocus, pending.until > clickedAt, actions.clickFocusesSession() else { return false }
        pendingFocus = nil
        peekWork?.cancel()
        peekWork = nil
        peekUntil = nil
        model.peekSessionID = nil
        _ = actions.focusSession(pending.session)
        return true
    }

    /// A ring double-click: the ring stops asking, then its waiting session
    /// comes forward, else its most recently active one, else the provider's
    /// own app. Without any of those it is acknowledged and left open.
    private func focusRing(_ id: String, remembered: AgentSession?) {
        actions.acknowledgeWaiting(id)
        guard actions.clickFocusesSession(), let snapshot = model.snapshots.first(where: { $0.id == id }) else { return }
        let route = FocusRoute.forRing(model.activity(for: snapshot)?.sessions ?? [], preferring: remembered,
                                       app: ProviderApp.of(kind: snapshot.kind, name: snapshot.displayName),
                                       isRunning: actions.isProcessRunning)
        if focus(route) { foldAfterFocus() }
    }

    /// A session row in a card: that session and no other. A waiting one stops
    /// asking; its own process's app comes forward; the notch folds. No refresh.
    func focusRow(_ session: AgentSession) {
        if session.state == .waiting { actions.acknowledgeSession(session) }
        guard actions.clickFocusesSession() else { return }
        if focus(FocusRoute.forRow(session, isRunning: actions.isProcessRunning)) { foldAfterFocus() }
    }

    private func focus(_ route: FocusRoute) -> Bool {
        switch route {
        case .session(let session): return actions.focusSession(session)
        case .app(let app):         return actions.openProviderApp(app)
        case .none:                 return false
        }
    }

    func togglePinned() {
        model.isPinned.toggle()
        if model.isPinned {
            foldWork?.cancel()
            foldWork = nil
            withAnimation(NotchMotion.unfold) { model.isExpanded = true }
        } else {
            cursorMoved()
        }
        updateInteractiveRects()
    }

    // MARK: - ⌥-drag along the edge

    private func beginDrag() {
        isDragging = true
        dragOffset = alongOffset
        clearHoverWork?.cancel()
        withAnimation(NotchMotion.hoverOut) { model.hoveredIndex = nil }
    }

    /// Raw pointer deltas: `dy` positive is the pointer moving down the screen,
    /// which is what a vertical edge's offset measures; `dx` right, for a
    /// horizontal one.
    private func dragged(dx: CGFloat, dy: CGFloat) {
        let limit = NotchGeometry.offsetLimit(for: screen, panelSize: model.panelSize, edge: model.edge, slack: model.slack)
        dragOffset = NotchGeometry.clamp(dragOffset + (model.edge.isVertical ? dy : dx), min: -limit, max: limit)
        alongOffset = dragOffset
        relocate()
    }

    private func endDrag() {
        isDragging = false
        actions.saveOffset(model.edge, alongOffset)
        cursorMoved()
    }

    // MARK: - The menu

    private func contextMenu(at windowPoint: CGPoint) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let local = local(fromWindow: windowPoint)

        if model.isExpanded, notchRect.contains(local), let index = model.cellIndex(along: placement.along(of: local)),
           model.snapshots.indices.contains(index) {
            let snapshot = model.snapshots[index]
            menu.addItem(MenuItem("Refresh \(snapshot.displayName)") { [actions] in actions.refresh(snapshot.id) })
            if actions.usagePage(snapshot.id) != nil {
                menu.addItem(MenuItem("Open \(snapshot.displayName) Usage Page") { [actions] in
                    actions.openUsagePage(snapshot.id)
                })
            }
            if let config = actions.manualConfig(snapshot.id) {
                for window in config.windows {
                    let unit = window.unit.isEmpty ? "" : " \(window.unit)"
                    menu.addItem(MenuItem("Add 1\(unit) to \(window.label)") { [actions] in
                        actions.adjustManual(config.id, window.id, 1)
                    })
                }
                menu.addItem(MenuItem("Reset \(config.name) Counts") { [actions] in actions.resetManual(config.id) })
            }
            menu.addItem(.separator())
        }

        let keepOpen = MenuItem("Keep Open") { [weak self] in self?.togglePinned() }
        keepOpen.state = model.isPinned || model.isAlwaysOn ? .on : .off
        keepOpen.isEnabled = !model.isAlwaysOn
        menu.addItem(keepOpen)
        menu.addItem(MenuItem("Refresh All", key: "r") { [actions] in actions.refreshAll() })
        menu.addItem(MenuItem("Recentre Notch") { [actions] in actions.recentre() })
        menu.addItem(MenuItem("Hide for 1 Hour") { [actions] in actions.hideForAnHour() })
        let demo = MenuItem("Demo Mode") { [actions] in actions.toggleDemo() }
        demo.state = actions.isDemo() ? .on : .off
        menu.addItem(demo)
        menu.addItem(.separator())
        menu.addItem(MenuItem("Settings…", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(MenuItem("Quit Brim", key: "q") { NSApp.terminate(nil) })
        return menu
    }
}

/// An NSMenuItem that runs a closure.
final class MenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        target = self
        isEnabled = true
    }

    required init(coder: NSCoder) { fatalError("unused") }

    @objc private func run() { handler() }
}
