import AppKit
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    private let movedLock = NSLock()
    private var moved: [String: String] = [:]

    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func setup() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert]) { _, _ in }
    }

    func post(_ title: String, body: String? = nil, open url: URL? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        if let body { content.body = body }
        if let url { content.userInfo = ["path": url.path] }
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    func moved(from old: String, to new: String) {
        movedLock.lock()
        defer { movedLock.unlock() }
        for (key, value) in moved where value == old { moved[key] = new }
        moved[old] = new
    }

    private func current(_ url: URL) -> URL {
        movedLock.lock()
        defer { movedLock.unlock() }
        guard let dir = moved[url.deletingLastPathComponent().path] else { return url }
        return URL(fileURLWithPath: dir).appendingPathComponent(url.lastPathComponent)
    }

    func play(_ name: String) {
        NSSound(named: name)?.play()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.open(current(URL(fileURLWithPath: path)))
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner])
    }
}
