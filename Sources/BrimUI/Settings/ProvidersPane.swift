import AppKit
import BrimCore
import SwiftUI

/// Every provider Brim can show, in notch order, each with exactly what it
/// reads and whether it touches the network.
struct ProvidersPane: View {
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    @State private var expanded: Set<String> = []

    var body: some View {
        List {
            Section {
                ForEach(store.listings) { listing in
                    ProviderRow(listing: listing, store: store, settingsStore: settingsStore,
                                isExpanded: Binding(
                                    get: { expanded.contains(listing.id) },
                                    set: { open in
                                        if open { expanded.insert(listing.id) } else { expanded.remove(listing.id) }
                                    }))
                }
                .onMove { offsets, destination in
                    store.moveProviders(fromOffsets: offsets, toOffset: destination)
                }
            } header: {
                Text("On the notch — drag to reorder")
            } footer: {
                Text("Networked sources start switched off. A provider switched back on joins the end of the list.")
                    .foregroundStyle(.secondary)
            }

            if !settingsStore.settings.demoMode {
                Section {
                    Button {
                        let config = ManualProviderConfig(name: "New provider", windows: [
                            ManualWindow(label: "Requests", limit: 500, used: 0, unit: "requests",
                                         schedule: .monthly(day: 1, hour: 0, minute: 0)),
                        ])
                        settingsStore.update {
                            $0.manualProviders.append(config)
                            $0.enabledProviders[config.id] = true
                        }
                        expanded.insert(config.id)
                    } label: {
                        Label("Add a Manual Provider", systemImage: "plus.circle")
                    }
                } footer: {
                    Text("For any service Brim cannot read: enter its limits and reset schedule, and count usage from the ring's menu.")
                        .foregroundStyle(.secondary)
                }

                Section("Not supported") {
                    ForEach(UnsupportedProvider.all) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name)
                            Text(item.reason).font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .navigationTitle("Providers")
    }
}

private struct ProviderRow: View {
    let listing: ProviderListing
    @ObservedObject var store: UsageStore
    @ObservedObject var settingsStore: SettingsStore
    @Binding var isExpanded: Bool

    private var enabled: Binding<Bool> {
        Binding(get: { settingsStore.settings.isEnabled(listing.id, kind: listing.kind) },
                set: { store.setEnabled($0, id: listing.id) })
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(listing.kind.dataAccess, id: \.self) { line in
                    Label(line, systemImage: "doc.text.magnifyingglass")
                        .font(.callout).foregroundStyle(.secondary)
                }
                switch listing.kind {
                case .claudeCode: ClaudeSettingsView(settingsStore: settingsStore, store: store)
                case .ollama:     RuntimeSettingsView(name: "Ollama", runtime: settingsStore.binding(\.ollama))
                case .lmStudio:   RuntimeSettingsView(name: "LM Studio", runtime: settingsStore.binding(\.lmStudio))
                case .manual:     ManualProviderEditor(settingsStore: settingsStore, id: listing.id)
                default:          EmptyView()
                }
            }
            .padding(.vertical, 6)
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.black)
                    ProviderGlyphView(glyph: listing.glyph, size: 14).foregroundStyle(.white)
                }
                .frame(width: 24, height: 24)
                Text(listing.name)
                Badge(text: listing.kind.fidelity.title, color: badgeColor)
                if listing.kind.network.isNetworked || (listing.kind == .claudeCode && claudeUsesNetwork) {
                    Badge(text: listing.kind == .claudeCode ? "Network: Anthropic" : "Loopback only", color: .orange)
                }
                Spacer()
                Toggle("Show \(listing.name)", isOn: enabled).labelsHidden().toggleStyle(.switch)
            }
        }
    }

    private var claudeUsesNetwork: Bool {
        settingsStore.settings.claude.useUsageCommand || settingsStore.settings.claude.refreshWhileClosed
    }

    private var badgeColor: Color {
        switch listing.kind.fidelity {
        case .official:    return .green
        case .derived:     return .yellow
        case .manual:      return .blue
        case .local:       return .gray
        case .unsupported: return .red
        }
    }
}

private struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

private struct ClaudeSettingsView: View {
    @ObservedObject var settingsStore: SettingsStore
    @ObservedObject var store: UsageStore
    private var calibration: ClaudeCalibration? { store.claudeCalibration }
    private var sources: ClaudeSourceStatus { store.claudeSources }

    private func openKeychainAccess() {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess") {
            NSWorkspace.shared.open(app)
        }
    }

    private func budgetBinding(_ keyPath: WritableKeyPath<ClaudeSettings, Double?>) -> Binding<String> {
        Binding(get: { settingsStore.settings.claude[keyPath: keyPath].map { String(Int($0)) } ?? "" },
                set: { text in
                    let digits = text.filter(\.isNumber)
                    settingsStore.update { $0.claude[keyPath: keyPath] = Double(digits).flatMap { $0 > 0 ? $0 : nil } }
                })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Anthropic's own percentages are shown as they are. Anything Brim works out from the logs is marked ~.")
                .font(.callout)
            Toggle("Read the usage figures Claude Code caches", isOn: settingsStore.binding(\.claude.readUsageCache))
            Text("Each time Claude Code fetches your usage (running /usage does), it keeps Anthropic's answer in ~/.claude.json. Brim cuts out that one entry and decodes nothing else in the file. Local, no network.")
                .font(.caption).foregroundStyle(.secondary)
            LabeledContent("Status-line handoff") {
                Text(sources.statuslineReportedAt.map { "Last report \($0.formatted(.relative(presentation: .named)))" }
                     ?? "Not set up")
                    .foregroundStyle(.secondary)
            }
            Text("After every reply, Claude Code hands Anthropic's figures to your status-line command. A few lines there pass just the percentages and reset times on to Brim, so the notch matches Anthropic exactly. Local, no network.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Copy the lines for a JavaScript status line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ClaudeStatuslineHandoff.nodeSnippet, forType: .string)
            }
            Toggle("Size the budget from Anthropic's figures",
                   isOn: settingsStore.binding(\.claude.calibrateFromLimitHits))
            if let budget = calibration?.sessionBudget, let at = calibration?.sessionMeasuredAt {
                Text("Last measured: \(CountFormat.compact(budget)) weighted tokens per 5 hours, on \(at.formatted(date: .abbreviated, time: .shortened)).")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("No limit hit or reported percentage to measure against yet.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            LabeledContent("Session budget (5 h)") {
                TextField("measured", text: budgetBinding(\.sessionBudget)).frame(width: 140).multilineTextAlignment(.trailing)
            }
            LabeledContent("Weekly budget") {
                TextField("measured", text: budgetBinding(\.weeklyBudget)).frame(width: 140).multilineTextAlignment(.trailing)
            }
            Text("Weighted tokens: input + output × 5 + cache writes × 1.25 + cache reads × 0.1. A budget you type overrides the measured one.")
                .font(.caption).foregroundStyle(.secondary)

            Divider()
            Toggle("Ask claude /usage for official figures", isOn: settingsStore.binding(\.claude.useUsageCommand))
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Network: off unless switched on here", systemImage: "network")
                        .font(.callout.weight(.semibold))
                    Text("Runs the installed claude binary as `claude --print --safe-mode --no-session-persistence --strict-mcp-config /usage`. Claude Code then contacts api.anthropic.com with its own login. Brim never reads its token or the keychain, and only the “Current …” lines of the output are read.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("Ask every", selection: settingsStore.binding(\.claude.usageCommandInterval)) {
                Text("5 minutes").tag(300.0)
                Text("10 minutes").tag(600.0)
                Text("15 minutes").tag(900.0)
                Text("30 minutes").tag(1800.0)
            }
            .disabled(!settingsStore.settings.claude.useUsageCommand)

            Divider()
            Toggle("Refresh while Claude Code is closed", isOn: settingsStore.binding(\.claude.refreshWhileClosed))
            GroupBox {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Network and keychain: off unless switched on here", systemImage: "key")
                        .font(.callout.weight(.semibold))
                    Text("When nothing on this Mac has reported Anthropic's figures for 10 minutes, Brim asks Anthropic itself: GET https://api.anthropic.com/api/oauth/usage, signed with Claude Code's own sign-in. That sign-in comes from your login keychain (the item “Claude Code-credentials”: its access token and expiry, never the refresh token). It's read only when you click, after macOS asks you, and kept in memory only: never saved, logged or sent anywhere else. Switching this off drops it.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if settingsStore.settings.claude.refreshWhileClosed {
                HStack(alignment: .firstTextBaseline) {
                    Text(sources.fallback.message).font(.callout)
                    Spacer()
                    if sources.fallback.needsAccess {
                        Button("Allow access…") { store.allowClaudeKeychainAccess() }
                    }
                }
                Picker("Ask at most every", selection: settingsStore.binding(\.claude.refreshWhileClosedInterval)) {
                    Text("5 minutes").tag(300.0)
                    Text("10 minutes").tag(600.0)
                    Text("15 minutes").tag(900.0)
                    Text("30 minutes").tag(1800.0)
                }
                HStack {
                    Button("Switch off and forget the sign-in") { store.forgetClaudeKeychainAccess() }
                    Button("Open Keychain Access") { openKeychainAccess() }
                }
                Text("If you chose “Always Allow”, revoke it in Keychain Access: open “Claude Code-credentials”, then Access Control, and remove Brim. Claude Code files a new item whenever it renews its sign-in, so an allowance also lapses by itself.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct RuntimeSettingsView: View {
    let name: String
    @Binding var runtime: LocalRuntimeSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Port on 127.0.0.1") {
                TextField("port", value: $runtime.port, format: .number.grouping(.never))
                    .frame(width: 90).multilineTextAlignment(.trailing)
            }
            Toggle("Read request counts and timings from \(name)'s logs", isOn: $runtime.readLogs)
            GroupBox {
                Label("Loopback only: connects to http://127.0.0.1:\(runtime.port) and nothing else. Never sends or captures prompts or replies.",
                      systemImage: "network")
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
