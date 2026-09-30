import AppKit
import BrimCore
import Combine

/// The optional menu bar item: Brim's mark, or the readings themselves, and a
/// menu with every provider's figures.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let store: UsageStore
    private let settingsStore: SettingsStore
    private var item: NSStatusItem?
    private var cancellables = Set<AnyCancellable>()
    var actions = NotchActions()
    var isPinned: () -> Bool = { false }
    var showNotchNow: () -> Void = {}
    var isTemporarilyHidden: () -> Bool = { false }

    init(store: UsageStore, settingsStore: SettingsStore) {
        self.store = store
        self.settingsStore = settingsStore
    }

    func setVisible(_ visible: Bool) {
        if visible, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = Self.icon
            item.button?.imagePosition = .imageLeading
            item.button?.setAccessibilityLabel("Brim")
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
            store.$snapshots.sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateTitle() }
            }.store(in: &cancellables)
            settingsStore.$settings.sink { [weak self] settings in
                MainActor.assumeIsolated { self?.updateTitle(settings) }
            }.store(in: &cancellables)
            updateTitle()
        } else if !visible, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
            cancellables.removeAll()
        }
    }

    /// "73% · 51m | 21%" when readings are asked for; the mark alone otherwise.
    private func updateTitle(_ settings: AppSettings? = nil) {
        guard let button = item?.button else { return }
        let settings = settings ?? settingsStore.settings
        guard settings.menuBarShowsReadings else {
            button.title = ""
            return
        }
        let now = Date()
        let parts = store.snapshots.compactMap { snapshot -> String? in
            guard let headline = snapshot.headline, let fraction = headline.usedFraction,
                  snapshot.fidelity != .local else { return nil }
            var text = snapshot.headlineFidelity.qualifier + Percent.text(for: fraction)
            if let reset = headline.resetsAt, let countdown = ResetCopy.countdown(to: reset, now: now) {
                text += " · \(countdown)"
            }
            return text
        }
        button.title = parts.isEmpty ? "" : " " + parts.joined(separator: " | ")
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let now = Date()
        if store.snapshots.isEmpty {
            let empty = NSMenuItem(title: "No providers switched on", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for snapshot in store.snapshots {
            let header = NSMenuItem(title: snapshot.displayName, action: nil, keyEquivalent: "")
            header.isEnabled = false
            header.attributedTitle = NSAttributedString(string: snapshot.displayName, attributes: [
                .font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
            menu.addItem(header)
            if let message = snapshot.status.message, snapshot.windows.isEmpty {
                menu.addItem(line("  \(message)"))
            }
            for window in snapshot.windows {
                var text = "  \(window.label): "
                if let fraction = window.usedFraction {
                    text += (window.fidelity ?? snapshot.fidelity).qualifier + Percent.text(for: fraction)
                } else {
                    text += window.detail ?? "—"
                }
                if let reset = window.resetsAt { text += " · " + ResetCopy.text(for: reset, now: now) }
                menu.addItem(line(text))
            }
            if let since = snapshot.status.staleSince {
                menu.addItem(line("  as of \(ElapsedCopy.ago(since: since, now: now))"))
            }
        }
        menu.addItem(.separator())
        if isTemporarilyHidden() {
            menu.addItem(MenuItem("Show Notch Now") { [weak self] in self?.showNotchNow() })
        }
        menu.addItem(MenuItem("Refresh All", key: "r") { [actions] in actions.refreshAll() })
        let demo = MenuItem("Demo Mode") { [actions] in actions.toggleDemo() }
        demo.state = actions.isDemo() ? .on : .off
        menu.addItem(demo)
        menu.addItem(MenuItem("Settings…", key: ",") { [actions] in actions.openSettings() })
        menu.addItem(.separator())
        menu.addItem(MenuItem("Quit Brim", key: "q") { NSApp.terminate(nil) })
    }

    private func line(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// A small open ring with a notch cut in it, as a template image.
    static let icon: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let ring = NSBezierPath()
            let centre = NSPoint(x: rect.midX, y: rect.midY)
            ring.appendArc(withCenter: centre, radius: 6.5, startAngle: 90 - 30, endAngle: 90 - 330, clockwise: true)
            ring.lineWidth = 2.2
            ring.lineCapStyle = .round
            NSColor.black.setStroke()
            ring.stroke()
            let track = NSBezierPath()
            track.appendArc(withCenter: centre, radius: 6.5, startAngle: 90 - 330, endAngle: 90 - 390, clockwise: true)
            track.lineWidth = 2.2
            NSColor.black.withAlphaComponent(0.35).setStroke()
            track.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: centre.x - 1.6, y: centre.y - 1.6, width: 3.2, height: 3.2)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }()
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        NSFont.systemFont(ofSize: pointSize, weight: weight)
    }
}
