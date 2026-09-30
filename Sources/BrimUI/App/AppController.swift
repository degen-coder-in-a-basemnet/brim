import AppKit
import BrimCore
import Combine
import SwiftUI

/// Wires the store to the notches, the menu bar item, notifications and the
/// settings window. Owns nothing the UI draws; only who talks to whom.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private let environment: ProviderEnvironment
    private let dataDirectory: URL
    private let forceDemo: Bool

    private var settingsStore: SettingsStore!
    private var archive: ReadingArchiveStore!
    private var store: UsageStore!
    private var fleet: NotchFleet!
    private var statusItem: StatusItemController!
    private var notifier: Notifier!
    private var settingsWindow: SettingsWindowController!
    private var cancellables = Set<AnyCancellable>()

    init(demo: Bool) {
        let environment = ProviderEnvironment.current
        self.environment = environment
        // A demo run keeps its own settings and remembers nothing real.
        self.dataDirectory = demo ? environment.applicationSupport.appendingPathComponent("Demo") : environment.applicationSupport
        self.forceDemo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivateFile.prepare(directory: dataDirectory)
        settingsStore = SettingsStore(directory: dataDirectory)
        if forceDemo, !settingsStore.settings.demoMode { settingsStore.update { $0.demoMode = true } }
        archive = forceDemo ? ReadingArchiveStore(inMemory: .init()) : ReadingArchiveStore(directory: dataDirectory)
        store = UsageStore(settingsStore: settingsStore, archive: archive, environment: environment)

        let actions = makeActions()
        fleet = NotchFleet(store: store, settingsStore: settingsStore, actions: actions)
        statusItem = StatusItemController(store: store, settingsStore: settingsStore)
        statusItem.actions = actions
        statusItem.showNotchNow = { [weak self] in self?.fleet.showNow() }
        statusItem.isTemporarilyHidden = { [weak self] in self?.fleet.isTemporarilyHidden ?? false }

        notifier = Notifier()
        notifier.start()
        notifier.focusSession = { [weak self] pid in
            guard self?.settingsStore.settings.clickActivatesSessionApp == true else { return }
            SessionFocus.focus(pid: pid)
        }

        settingsWindow = SettingsWindowController { [unowned self] in
            SettingsView(store: store, settingsStore: settingsStore, actions: SettingsActions(
                recentre: { [weak self] in self?.recentre() },
                revealDataFolder: { [weak self] in
                    guard let self else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([self.dataDirectory])
                },
                forgetReadings: { [weak self] in self?.store.forgetReadings() },
                dataFolder: dataDirectory))
        }

        installMainMenu()
        applyPresence(settingsStore.settings)
        settingsStore.$settings.dropFirst().sink { [weak self] settings in
            MainActor.assumeIsolated { self?.applyPresence(settings) }
        }.store(in: &cancellables)

        store.thresholdAlerts.sink { [weak self] alert in
            MainActor.assumeIsolated { self?.notifier.deliver(alert) }
        }.store(in: &cancellables)
        store.sessionEvents.sink { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, self.settingsStore.settings.sessionNotifications else { return }
                self.notifier.deliver(event)
            }
        }.store(in: &cancellables)

        store.start()
        fleet.start()
        SafeLog.ui.info("Brim started")
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
    }

    /// Opening Brim again while it runs brings Settings back — the way in when
    /// neither a Dock icon nor a menu bar item is shown.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        settingsWindow.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: - Wiring

    private func makeActions() -> NotchActions {
        var actions = NotchActions()
        actions.refresh = { [weak self] id in self?.store.refresh(id) }
        actions.refreshAll = { [weak self] in self?.store.refreshAll() }
        actions.openUsagePage = { [weak self] id in
            guard let url = self?.usagePage(for: id) else { return }
            NSWorkspace.shared.open(url)
        }
        actions.openSettings = { [weak self] in self?.settingsWindow.show() }
        actions.focusSession = { [weak self] session in
            guard self?.settingsStore.settings.clickActivatesSessionApp == true, let pid = session.processID else {
                return false
            }
            return SessionFocus.focus(pid: pid)
        }
        actions.openProviderApp = { [weak self] app in
            guard self?.settingsStore.settings.clickActivatesSessionApp == true else { return false }
            return SessionFocus.open(app)
        }
        actions.recentre = { [weak self] in self?.recentre() }
        actions.hideForAnHour = { [weak self] in self?.fleet.hideForAnHour() }
        actions.toggleDemo = { [weak self] in self?.settingsStore.update { $0.demoMode.toggle() } }
        actions.isDemo = { [weak self] in self?.settingsStore.settings.demoMode ?? false }
        actions.ringClickAction = { [weak self] in self?.settingsStore.settings.ringClickAction ?? .refresh }
        actions.clickFocusesSession = { [weak self] in self?.settingsStore.settings.clickActivatesSessionApp ?? true }
        actions.adjustManual = { [weak self] provider, window, amount in
            self?.store.adjustManual(providerID: provider, windowID: window, by: amount)
        }
        actions.resetManual = { [weak self] provider in self?.store.resetManual(providerID: provider) }
        actions.manualConfig = { [weak self] id in self?.settingsStore.settings.manualProviders.first { $0.id == id } }
        actions.usagePage = { [weak self] id in self?.usagePage(for: id) }
        return actions
    }

    private func usagePage(for id: String) -> URL? {
        if let manual = settingsStore.settings.manualProviders.first(where: { $0.id == id }) {
            return manual.usagePage.flatMap(URL.init(string:)).flatMap { $0.scheme == "https" ? $0 : nil }
        }
        return store.listings.first { $0.id == id }?.kind.usagePageURL
    }

    private func recentre() {
        settingsStore.update { $0.setAlongOffset(0, for: $0.edge) }
    }

    private func applyPresence(_ settings: AppSettings) {
        let policy: NSApplication.ActivationPolicy = settings.appPresence == .dock ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
        statusItem.setVisible(settings.appPresence == .menuBar)
    }

    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(MenuItem("About Brim") { [weak self] in self?.settingsWindow.show() })
        appMenu.addItem(.separator())
        appMenu.addItem(MenuItem("Settings…", key: ",") { [weak self] in self?.settingsWindow.show() })
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Brim", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Brim", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }
}

/// Brim's entry point.
public enum BrimApp {
    private static var controller: AppController?

    @MainActor
    public static func main() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render-snapshots"), index + 1 < arguments.count {
            let output = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
            _ = NSApplication.shared
            SnapshotRenderer.renderAll(to: output)
            exit(0)
        }
        let app = NSApplication.shared
        let demo = arguments.contains("--demo") || ProcessInfo.processInfo.environment["BRIM_DEMO"] == "1"
        let controller = AppController(demo: demo)
        Self.controller = controller
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
