import Foundation
import Combine
import UserNotifications

@MainActor
final class ReminderService: ObservableObject {
    @Published private(set) var statusText = "提醒尚未开启"
    private let center = UNUserNotificationCenter.current()
    private let identifier = "three-moments.evening"

    func refresh() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .denied: statusText = "系统通知未允许，可前往系统设置开启。"
        case .notDetermined: statusText = "开启时会请求系统通知权限。"
        case .authorized, .provisional, .ephemeral:
            let requests = await center.pendingNotificationRequests()
            statusText = requests.contains { $0.identifier == identifier } ? "晚间提醒已安排" : "通知权限已允许，提醒尚未开启。"
        @unknown default: statusText = "请在系统设置中查看通知权限。"
        }
    }

    func apply(enabled: Bool, time: String) async throws {
        if !enabled {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            statusText = "提醒已关闭"
            return
        }
        let allowed = try await center.requestAuthorization(options: [.alert, .sound])
        guard allowed else {
            statusText = "系统通知未允许，可前往系统设置开启。"
            throw ReminderError.permission
        }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { throw ReminderError.invalidTime }
        let content = UNMutableNotificationContent()
        content.title = "三件事日记"
        content.body = "有想留下的事，可以记一句。今天不写也没关系。"
        content.sound = .default
        // Never put an entry, a speaker's name, or a count on the lock screen.
        var components = DateComponents()
        components.hour = parts[0]
        components.minute = parts[1]
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        try await center.add(request)
        statusText = "每天 \(time) 提醒，可随时关闭。"
    }

    func removeAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
        statusText = "提醒已关闭"
    }
}

enum ReminderError: LocalizedError {
    case permission, invalidTime
    var errorDescription: String? {
        switch self {
        case .permission: return "请先在系统设置中允许通知，其他记录功能可以照常使用。"
        case .invalidTime: return "提醒时间无效，请重新选择。"
        }
    }
}
