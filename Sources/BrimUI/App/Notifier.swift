import AppKit
import BrimCore
import UserNotifications

/// System notifications for limit crossings and, when asked for, sessions.
///
/// Permission is requested on the first real alert, not at launch. Everything
/// shown is Brim's own summary — provider name, a percentage, a folder name —
/// never anything read out of a transcript.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }
    private var authorized: Bool?
    var focusSession: (Int32) -> Void = { _ in }

    func start() {
        center.delegate = self
    }

    private func withAuthorization(_ body: @escaping @MainActor () -> Void) {
        if authorized == true { return body() }
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                self.authorized = granted
                if granted { body() }
            }
        }
    }

    func deliver(_ alert: ThresholdAlert) {
        withAuthorization {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.threadIdentifier = "limits.\(alert.providerID)"
            content.sound = alert.threshold >= 100 ? .default : nil
            let request = UNNotificationRequest(identifier: "limit.\(alert.providerID).\(alert.threshold).\(Int(Date().timeIntervalSince1970))",
                                                content: content, trigger: nil)
            self.center.add(request)
        }
    }

    func deliver(_ event: SessionEvent) {
        withAuthorization {
            let content = UNMutableNotificationContent()
            content.title = event.title
            content.body = event.body
            content.threadIdentifier = "sessions.\(event.session.providerID)"
            content.sound = .default
            if let pid = event.session.processID { content.userInfo = ["pid": Int(pid)] }
            let request = UNNotificationRequest(identifier: "session.\(event.session.id).\(Int(Date().timeIntervalSince1970))",
                                                content: content, trigger: nil)
            self.center.add(request)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let pid = response.notification.request.content.userInfo["pid"] as? Int
        Task { @MainActor in
            if let pid { self.focusSession(Int32(pid)) }
            completionHandler()
        }
    }
}
