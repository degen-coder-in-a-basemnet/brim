import AppKit
import BrimCore
import SwiftUI

extension SettingsStore {
    func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] },
                set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

/// What the settings window can ask the app to do.
@MainActor
struct SettingsActions {
    var recentre: () -> Void = {}
    var revealDataFolder: () -> Void = {}
    var forgetReadings: () -> Void = {}
    var dataFolder: URL = URL(fileURLWithPath: NSHomeDirectory())
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, appearance, providers, alerts, privacy, about

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general:    return "gearshape"
        case .appearance: return "paintpalette"
        case .providers:  return "circle.dashed.inset.filled"
        case .alerts:     return "bell.badge"
        case .privacy:    return "lock.shield"
        case .about:      return "info.circle"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    let actions: SettingsActions
    @State private var pane: SettingsPane? = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: $pane) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            Group {
                switch pane ?? .general {
                case .general:    GeneralPane(settingsStore: settingsStore)
                case .appearance: AppearancePane(settingsStore: settingsStore, recentre: actions.recentre)
                case .providers:  ProvidersPane(store: store, settingsStore: settingsStore)
                case .alerts:     AlertsPane(store: store, settingsStore: settingsStore)
                case .privacy:    PrivacyPane(store: store, settingsStore: settingsStore, actions: actions)
                case .about:      AboutPane()
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("Notch") {
                Picker("Visibility", selection: settingsStore.binding(\.visibility)) {
                    ForEach(NotchVisibility.allCases) { Text($0.title).tag($0) }
                }
                Text(visibilityExplanation).font(.callout).foregroundStyle(.secondary)
                Toggle("Hide in full-screen apps", isOn: settingsStore.binding(\.foldsForFullScreen))
                Picker("Clicking a ring", selection: settingsStore.binding(\.ringClickAction)) {
                    ForEach(RingClickAction.allCases) { Text($0.title).tag($0) }
                }
                Text("Click the notch's body to keep it open; ⌥-drag it to slide it along the edge.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("App") {
                Picker("Show Brim in", selection: settingsStore.binding(\.appPresence)) {
                    ForEach(AppPresence.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Show readings in the menu bar", isOn: settingsStore.binding(\.menuBarShowsReadings))
                    .disabled(settingsStore.settings.appPresence != .menuBar)
                if settingsStore.settings.appPresence == .neither {
                    Text("With no icon anywhere, open Brim again from Finder to bring Settings back.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Readings") {
                Picker("Refresh every", selection: settingsStore.binding(\.refreshInterval)) {
                    ForEach(AppSettings.refreshChoices, id: \.self) { seconds in
                        Text(seconds < 60 * 2 ? "\(Int(seconds)) seconds" : "\(Int(seconds / 60)) minutes").tag(seconds)
                    }
                }
                Toggle("Demo mode", isOn: settingsStore.binding(\.demoMode))
                Text("Shows fixed sample data and reads nothing on this Mac. Your providers are left as they are.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private var visibilityExplanation: String {
        switch settingsStore.settings.visibility {
        case .alwaysShow: return "The notch stays open with every reading visible."
        case .onHover:    return "A small pill at the screen edge that opens when the pointer reaches it."
        case .hidden:     return "Nothing on screen. Readings stay in the menu bar menu if it is shown."
        }
    }
}

// MARK: - Appearance

private struct AppearancePane: View {
    @ObservedObject var settingsStore: SettingsStore
    let recentre: () -> Void

    var body: some View {
        Form {
            Section("Placement") {
                Picker("Screen edge", selection: settingsStore.binding(\.edge)) {
                    ForEach(NotchEdge.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(settingsStore.settings.edge.explanation).font(.callout).foregroundStyle(.secondary)
                Picker("Display", selection: settingsStore.binding(\.displayScope)) {
                    ForEach(DisplayScope.allCases) { Text($0.title).tag($0) }
                }
                if settingsStore.settings.displayScope == .specific {
                    Picker("Chosen display", selection: settingsStore.binding(\.chosenDisplayID)) {
                        ForEach(NSScreen.screens, id: \.self) { screen in
                            Text(screen.localizedName).tag(screen.displayIdentifier)
                        }
                    }
                }
                HStack {
                    Text("Position along the edge")
                    Spacer()
                    Button("Recentre", action: recentre)
                        .disabled(settingsStore.settings.alongOffset(for: settingsStore.settings.edge) == 0)
                }
            }
            Section("Look") {
                Picker("Size", selection: settingsStore.binding(\.size)) {
                    ForEach(NotchSize.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                AccentPicker(selection: settingsStore.binding(\.accent))
                Picker("Reset time", selection: settingsStore.binding(\.resetTimeFormat)) {
                    ForEach(ResetTimeFormat.allCases) { Text($0.title).tag($0) }
                }
                Text(settingsStore.settings.resetTimeFormat == .automatic
                     ? "Minutes under an hour, otherwise the reset's day and time."
                     : "A countdown, such as 3 Days 3h or 3h 20m.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Appearance")
    }
}

private struct AccentPicker: View {
    @Binding var selection: AccentChoice

    var body: some View {
        LabeledContent("Ring colour") {
            HStack(spacing: 8) {
                ForEach(AccentChoice.allCases) { choice in
                    Button {
                        selection = choice
                    } label: {
                        Circle()
                            .fill(choice.color)
                            .frame(width: 18, height: 18)
                            .overlay(Circle().strokeBorder(Color.primary.opacity(selection == choice ? 0.9 : 0.15),
                                                           lineWidth: selection == choice ? 2 : 1))
                            .padding(2)
                    }
                    .buttonStyle(.plain)
                    .help(choice.title)
                    .accessibilityLabel(choice.title)
                    .accessibilityAddTraits(selection == choice ? .isSelected : [])
                }
            }
        }
    }
}

// MARK: - Alerts

private struct AlertsPane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section {
                Toggle("Notify at 80% and 100%", isOn: settingsStore.binding(\.thresholdAlerts))
                Text("Once per crossing, and again only after the window rolls over. macOS asks for permission on the first real alert.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(store.snapshots) { snapshot in
                    Toggle("Alert for \(snapshot.displayName)", isOn: Binding(
                        get: { !settingsStore.settings.isMuted(snapshot.id) },
                        set: { on in
                            settingsStore.update { settings in
                                settings.mutedProviders.removeAll { $0 == snapshot.id }
                                if !on { settings.mutedProviders.append(snapshot.id) }
                            }
                        }))
                    .disabled(!settingsStore.settings.thresholdAlerts)
                }
            } header: {
                Text("Limits")
            }
            Section("Sessions") {
                Toggle("Open the notch when a session finishes", isOn: settingsStore.binding(\.peekOnFinish))
                Toggle("Open the notch when a session waits for you, until you click its ring",
                       isOn: settingsStore.binding(\.peekOnWaiting))
                Picker("Show a finished session for", selection: settingsStore.binding(\.peekDuration)) {
                    Text("3 seconds").tag(3.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                Toggle("Clicking it brings that session's app forward", isOn: settingsStore.binding(\.clickActivatesSessionApp))
                Text("Double-click a ring, or click a session in its card, to go to that session. In Terminal and iTerm2 its tab is selected too, once you allow Brim when macOS asks.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Also send a notification", isOn: settingsStore.binding(\.sessionNotifications))
                Toggle("Show session titles", isOn: settingsStore.binding(\.showSessionTitles))
                Text("Titles are generated from your conversation, so they are off by default; the folder name is shown instead.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Alerts")
    }
}

// MARK: - Privacy

private struct PrivacyPane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    let actions: SettingsActions

    private var networked: [(String, String)] {
        let settings = settingsStore.settings
        guard !settings.demoMode else { return [] }
        var result: [(String, String)] = []
        if settings.isEnabled("claudeCode", kind: .claudeCode), settings.claude.useUsageCommand {
            result.append(("Claude Code /usage", "Runs the installed claude binary; Claude Code contacts api.anthropic.com with its own login."))
        }
        if settings.isEnabled("ollama", kind: .ollama) {
            result.append(("Ollama", "http://127.0.0.1:\(settings.ollama.port) — this Mac only."))
        }
        if settings.isEnabled("lmStudio", kind: .lmStudio) {
            result.append(("LM Studio", "http://127.0.0.1:\(settings.lmStudio.port) — this Mac only."))
        }
        return result
    }

    var body: some View {
        Form {
            Section("Network") {
                if networked.isEmpty {
                    Label("Brim is making no network connections.", systemImage: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                } else {
                    ForEach(networked, id: \.0) { name, detail in
                        LabeledContent(name) { Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.trailing) }
                    }
                }
                Text("Every networked source is off until you switch it on in Providers.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Never") {
                ForEach(["Reads the keychain or any credential file",
                         "Asks for API keys, cookies or passwords",
                         "Sends prompts, code, logs or readings anywhere",
                         "Analytics, telemetry, crash uploads or remote configuration",
                         "Checks for updates"], id: \.self) { item in
                    Label(item, systemImage: "xmark.circle").foregroundStyle(.secondary)
                }
            }
            Section("Read on this Mac") {
                ForEach(store.listings.filter { settingsStore.settings.isEnabled($0.id, kind: $0.kind) }) { listing in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(listing.name).font(.headline)
                        ForEach(listing.kind.dataAccess, id: \.self) { line in
                            Text(line).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            Section("Saved on this Mac") {
                LabeledContent("Folder") {
                    Text(actions.dataFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .textSelection(.enabled).foregroundStyle(.secondary)
                }
                Text("settings.json holds your preferences and manual limits; last-readings.json holds the last percentages and reset times, so the notch has something to show at launch. Nothing else is stored.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    Button("Show in Finder", action: actions.revealDataFolder)
                    Button("Forget Saved Readings", role: .destructive, action: actions.forgetReadings)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Privacy")
    }
}

// MARK: - About

private struct AboutPane: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Brim").font(.title2.weight(.semibold))
                        Text("Version \(version)").foregroundStyle(.secondary)
                        Text("A private, local usage notch for coding assistants.").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 8)
            }
            Section("Credits") {
                Text("Brim's notch geometry, motion and layout are adapted from Codenotch by Vinz, used under the MIT License. The full notice ships in THIRD_PARTY_NOTICES.md inside the app.")
                    .font(.callout)
                Text("Brim is an independent project and is not affiliated with Codenotch, Anthropic, OpenAI, Ollama or LM Studio.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("About")
    }
}
