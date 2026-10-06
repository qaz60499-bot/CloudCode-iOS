import Foundation
import UserNotifications

@MainActor
enum ErrorNotificationCoordinator {
    static let preferenceKey = "error.notifications.background.enabled"

    static func requestAuthorization() async -> Bool {
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    static func postIfEnabled(_ message: String) {
        guard UserDefaults.standard.bool(forKey: preferenceKey) else { return }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Cloud Code 需要处理"
            content.body = String(trimmed.prefix(240))
            content.sound = .default
            content.threadIdentifier = "cloudcode-errors"
            let request = UNNotificationRequest(identifier: "cloudcode-error-\(UUID().uuidString)", content: content, trigger: nil)
            center.add(request)
        }
    }
}
