import AppKit
import BrimCore
import Combine
import SwiftUI

/// Every notch on every display it should be on, fed from one store.
@MainActor
final class NotchFleet {
    private let store: UsageStore
    private let settingsStore: SettingsStore
    private var baseActions: NotchActions
    private(set) var controllers: [String: NotchController] = [:]
    private var cancellables = Set<AnyCancellable>()
    private var hiddenUntil: Date?
    private var unhideWork: DispatchWorkItem?
    private var settings: AppSettings
    /// One record of who is waiting for the person, shared by every display, so
    /// acknowledging on one screen clears it on all.
    private var attention = WaitingAttention()
    private var activity: [String: ActivitySummary] = [:]

    init(store: UsageStore, settingsStore: SettingsStore, actions: NotchActions) {
        self.store = store
        self.settingsStore = settingsStore
        self.baseActions = actions
        self.settings = settingsStore.settings
    }

    func start() {
        rebuildScreens()
        store.$snapshots.sink { [weak self] snapshots in
            MainActor.assumeIsolated { self?.push { $0.snapshots = snapshots } }
        }.store(in: &cancellables)
        store.$activity.sink { [weak self] activity in
            MainActor.assumeIsolated {
                self?.push { $0.activity = activity }
                self?.observeAttention(activity)
            }
        }.store(in: &cancellables)
        store.$refreshing.sink { [weak self] refreshing in
            MainActor.assumeIsolated { self?.push(relocating: false) { $0.refreshing = refreshing } }
        }.store(in: &cancellables)
        // `@Published` announces before it stores: use the value it hands over.
        settingsStore.$settings.dropFirst().sink { [weak self] settings in
            MainActor.assumeIsolated { self?.apply(settings) }
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.rebuildScreens() } }
            .store(in: &cancellables)
        store.sessionEvents.sink { [weak self] event in
            MainActor.assumeIsolated { self?.announce(event) }
        }.store(in: &cancellables)
    }

    private func push(relocating: Bool = true, _ change: (NotchViewModel) -> Void) {
        for controller in controllers.values {
            change(controller.model)
            if relocating { controller.relocate() }
        }
    }

    // MARK: - Screens

    private func key(for screen: NSScreen) -> String {
        screen.displayIdentifier ?? "screen-\(Int(screen.frame.minX))-\(Int(screen.frame.minY))"
    }

    func rebuildScreens() {
        let screens = NSScreen.screens
        let main = screens.first
        let targets = NotchGeometry.targetScreens(from: screens, scope: settings.displayScope,
                                                  chosenID: settings.chosenDisplayID, main: main)
        let wanted = Dictionary(targets.map { (key(for: $0), $0) }, uniquingKeysWith: { first, _ in first })
        for (key, controller) in controllers where wanted[key] == nil {
            controller.tearDown()
            controllers.removeValue(forKey: key)
        }
        var added: [NotchController] = []
        for (key, screen) in wanted {
            if let existing = controllers[key] {
                existing.screen = screen
            } else {
                let controller = NotchController(screen: screen)
                controller.model.snapshots = store.snapshots
                controller.model.activity = store.activity
                controllers[key] = controller
                added.append(controller)
            }
        }
        apply(settings)
        // A display arriving mid-wait asks too.
        let open = Self.attentionOpens(started: !attention.providers.isEmpty, settings: settings,
                                       temporarilyHidden: isTemporarilyHidden)
        for controller in added { controller.setAttention(attention.providers, open: open) }
    }

    // MARK: - Settings

    func apply(_ settings: AppSettings) {
        let scopeChanged = settings.displayScope != self.settings.displayScope
            || settings.chosenDisplayID != self.settings.chosenDisplayID
        self.settings = settings
        if scopeChanged {
            rebuildScreens()
            return
        }
        for controller in controllers.values {
            var actions = baseActions
            actions.saveOffset = { [weak self] edge, offset in
                self?.settingsStore.update { $0.setAlongOffset(Double(offset), for: edge) }
            }
            actions.acknowledgeWaiting = { [weak self] id in self?.acknowledgeWaiting(providerID: id) }
            actions.waitingSession = { [weak self] id in
                self.flatMap { WaitingAttention.focusTarget(providerID: id, in: $0.activity) }
            }
            actions.acknowledgeSession = { [weak self] session in self?.acknowledgeWaiting(sessionID: session.id) }
            controller.actions = actions
            let model = controller.model
            if model.edge != settings.edge {
                model.isExpanded = settings.visibility == .alwaysShow
                model.hoveredIndex = nil
                model.edge = settings.edge
            }
            model.sizeScale = CGFloat(settings.size.scale)
            model.accent = settings.accent.color
            model.resetFormat = settings.resetTimeFormat
            controller.foldsForFullScreen = settings.foldsForFullScreen
            controller.setAlongOffset(CGFloat(settings.alongOffset(for: settings.edge)))
            controller.applyAlwaysOn(settings.visibility == .alwaysShow)
        }
        applyVisibility()
    }

    private func applyVisibility() {
        let hiddenByTimer = hiddenUntil.map { $0 > Date() } ?? false
        for controller in controllers.values {
            if settings.visibility == .hidden || hiddenByTimer {
                controller.hide()
            } else {
                controller.show()
            }
        }
    }

    func hideForAnHour() {
        hiddenUntil = Date().addingTimeInterval(3600)
        applyVisibility()
        unhideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.hiddenUntil = nil
                self?.applyVisibility()
            }
        }
        unhideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600, execute: work)
    }

    func showNow() {
        hiddenUntil = nil
        unhideWork?.cancel()
        applyVisibility()
    }

    var isTemporarilyHidden: Bool { hiddenUntil.map { $0 > Date() } ?? false }

    func togglePinned() {
        controllers.values.forEach { $0.togglePinned() }
    }

    var isPinned: Bool { controllers.values.contains { $0.model.isPinned } }

    // MARK: - Sessions

    private func announce(_ event: SessionEvent) {
        guard let duration = Self.peekDuration(for: event, settings: settings) else { return }
        for controller in controllers.values {
            controller.peek(for: duration, event: event)
        }
    }

    /// A finished session peeks for the set time. A waiting one doesn't: it
    /// asks for attention instead, and that lasts until it is acknowledged.
    nonisolated static func peekDuration(for event: SessionEvent, settings: AppSettings) -> TimeInterval? {
        guard event.kind == .finished, settings.peekOnFinish else { return nil }
        return settings.peekDuration
    }

    /// Whether sessions that have just started waiting may unfold the notch.
    /// Never a hidden one: "Hide" and "Hide for 1 Hour" stay in charge.
    nonisolated static func attentionOpens(started: Bool, settings: AppSettings, temporarilyHidden: Bool) -> Bool {
        started && settings.peekOnWaiting && settings.visibility != .hidden && !temporarilyHidden
    }

    private func observeAttention(_ activity: [String: ActivitySummary]) {
        self.activity = activity
        let started = attention.observe(activity)
        publishAttention(started: !started.isEmpty)
    }

    private func publishAttention(started: Bool) {
        let open = Self.attentionOpens(started: started, settings: settings, temporarilyHidden: isTemporarilyHidden)
        for controller in controllers.values {
            controller.setAttention(attention.providers, open: open)
        }
    }

    /// A waiting ring was clicked on some display: that provider stops asking
    /// everywhere. Others keep asking.
    func acknowledgeWaiting(providerID: String) {
        attention.acknowledge(providerID: providerID)
        publishAttention(started: false)
    }

    /// One waiting session was clicked in a card: it stops asking everywhere.
    /// Its provider's other waiting sessions keep asking.
    func acknowledgeWaiting(sessionID: String) {
        attention.acknowledge(sessionID: sessionID)
        publishAttention(started: false)
    }
}
