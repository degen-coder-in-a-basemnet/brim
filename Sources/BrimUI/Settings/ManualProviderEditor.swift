import BrimCore
import SwiftUI

/// Edits one manual provider in place.
struct ManualProviderEditor: View {
    @ObservedObject var settingsStore: SettingsStore
    let id: String

    private var index: Int? { settingsStore.settings.manualProviders.firstIndex { $0.id == id } }

    private func binding<T>(_ keyPath: WritableKeyPath<ManualProviderConfig, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { index.map { settingsStore.settings.manualProviders[$0][keyPath: keyPath] } ?? fallback },
                set: { value in
                    guard let index else { return }
                    settingsStore.update { $0.manualProviders[index][keyPath: keyPath] = value }
                })
    }

    var body: some View {
        if let index {
            VStack(alignment: .leading, spacing: 10) {
                LabeledContent("Name") {
                    TextField("Name", text: binding(\.name, "")).frame(width: 200)
                }
                LabeledContent("Monogram") {
                    TextField("M", text: Binding(get: { binding(\.monogram, "").wrappedValue },
                                                 set: { binding(\.monogram, "").wrappedValue = String($0.prefix(2)) }))
                        .frame(width: 60)
                }
                ForEach(settingsStore.settings.manualProviders[index].windows) { window in
                    WindowEditor(settingsStore: settingsStore, providerID: id, windowID: window.id)
                }
                HStack {
                    Button {
                        settingsStore.update {
                            $0.manualProviders[index].windows.append(
                                ManualWindow(label: "Limit", limit: 100, used: 0, unit: "requests", schedule: .daily(hour: 0, minute: 0)))
                        }
                    } label: { Label("Add Limit", systemImage: "plus") }
                    Spacer()
                    Button(role: .destructive) {
                        settingsStore.update { settings in
                            settings.manualProviders.removeAll { $0.id == id }
                            settings.enabledProviders.removeValue(forKey: id)
                            settings.providerOrder.removeAll { $0 == id }
                        }
                    } label: { Label("Delete Provider", systemImage: "trash") }
                }
            }
        }
    }
}

private enum ScheduleKind: String, CaseIterable, Identifiable {
    case none, rolling, daily, weekly, monthly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none:    return "Never"
        case .rolling: return "Every N hours"
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        }
    }

    init(_ schedule: ResetSchedule) {
        switch schedule {
        case .none, .once: self = .none
        case .everyHours:  self = .rolling
        case .daily:       self = .daily
        case .weekly:      self = .weekly
        case .monthly:     self = .monthly
        }
    }

    func schedule(from old: ResetSchedule) -> ResetSchedule {
        let (hour, minute) = old.time
        switch self {
        case .none:    return .none
        case .rolling: return .everyHours(5, anchor: Date())
        case .daily:   return .daily(hour: hour, minute: minute)
        case .weekly:  return .weekly(weekday: 2, hour: hour, minute: minute)
        case .monthly: return .monthly(day: 1, hour: hour, minute: minute)
        }
    }
}

private extension ResetSchedule {
    var time: (Int, Int) {
        switch self {
        case .daily(let h, let m), .weekly(_, let h, let m), .monthly(_, let h, let m): return (h, m)
        default: return (0, 0)
        }
    }
}

private struct WindowEditor: View {
    @ObservedObject var settingsStore: SettingsStore
    let providerID: String
    let windowID: String

    private var path: (Int, Int)? {
        guard let p = settingsStore.settings.manualProviders.firstIndex(where: { $0.id == providerID }),
              let w = settingsStore.settings.manualProviders[p].windows.firstIndex(where: { $0.id == windowID })
        else { return nil }
        return (p, w)
    }

    private func binding<T>(_ keyPath: WritableKeyPath<ManualWindow, T>, _ fallback: T) -> Binding<T> {
        Binding(get: { path.map { settingsStore.settings.manualProviders[$0.0].windows[$0.1][keyPath: keyPath] } ?? fallback },
                set: { value in
                    guard let path else { return }
                    settingsStore.update { $0.manualProviders[path.0].windows[path.1][keyPath: keyPath] = value }
                })
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Label", text: binding(\.label, ""))
                    Button(role: .destructive) {
                        guard let path else { return }
                        settingsStore.update { $0.manualProviders[path.0].windows.remove(at: path.1) }
                    } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .help("Remove this limit")
                }
                HStack {
                    TextField("Used", value: binding(\.used, 0), format: .number).frame(width: 80)
                    Text("of")
                    TextField("Limit", value: binding(\.limit, 0), format: .number).frame(width: 80)
                    TextField("unit", text: binding(\.unit, "")).frame(width: 100)
                }
                HStack {
                    let schedule = binding(\.schedule, .none)
                    Picker("Resets", selection: Binding(get: { ScheduleKind(schedule.wrappedValue) },
                                                        set: { schedule.wrappedValue = $0.schedule(from: schedule.wrappedValue) })) {
                        ForEach(ScheduleKind.allCases) { Text($0.title).tag($0) }
                    }
                    .frame(width: 220)
                    ScheduleDetail(schedule: schedule)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct ScheduleDetail: View {
    @Binding var schedule: ResetSchedule

    var body: some View {
        switch schedule {
        case .everyHours(let hours, let anchor):
            Stepper("\(hours) h", value: Binding(get: { hours }, set: { schedule = .everyHours(max(1, $0), anchor: anchor) }),
                    in: 1...168)
        case .daily(let hour, let minute):
            timePicker(hour: hour, minute: minute) { schedule = .daily(hour: $0, minute: $1) }
        case .weekly(let weekday, let hour, let minute):
            Picker("", selection: Binding(get: { weekday }, set: { schedule = .weekly(weekday: $0, hour: hour, minute: minute) })) {
                ForEach(1...7, id: \.self) { Text(Calendar.current.weekdaySymbols[$0 - 1]).tag($0) }
            }
            .labelsHidden().frame(width: 120)
            timePicker(hour: hour, minute: minute) { schedule = .weekly(weekday: weekday, hour: $0, minute: $1) }
        case .monthly(let day, let hour, let minute):
            Stepper("Day \(day)", value: Binding(get: { day }, set: { schedule = .monthly(day: $0, hour: hour, minute: minute) }),
                    in: 1...31)
        default:
            EmptyView()
        }
    }

    private func timePicker(hour: Int, minute: Int, set: @escaping (Int, Int) -> Void) -> some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date() },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                set(parts.hour ?? 0, parts.minute ?? 0)
            }), displayedComponents: .hourAndMinute)
            .labelsHidden()
    }
}
