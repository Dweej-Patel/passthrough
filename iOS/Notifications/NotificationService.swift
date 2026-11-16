import UserNotifications
import PassthroughCore

/// Opens a notice a Mac sealed for this phone (`PushBox`) and shows what it
/// says in place of the placeholder Apple carried. A notice it can't open
/// (no key for that Mac, a box for another phone) shows the placeholder,
/// which says nothing about what happened.
final class NotificationService: UNNotificationServiceExtension {
    private var deliver: ((UNNotificationContent) -> Void)?
    private var placeholder: UNNotificationContent?

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        deliver = contentHandler
        placeholder = request.content
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else { return contentHandler(request.content) }
        if let sealed = content.userInfo[PushBox.payloadKey] as? [String: Any],
           let mac = sealed["m"] as? String, let box = sealed["b"] as? String,
           let key = PushKeys.key(for: mac, in: PushKeys.store()),
           let notice = PushBox.open(box, key: key, macID: mac) {
            content.title = notice.title
            content.subtitle = notice.macName
            content.body = notice.body
            content.threadIdentifier = mac + "/" + notice.session
            // What a tap opens; the box itself goes no further.
            content.userInfo = ["mac": mac, "session": notice.session, "state": notice.state]
        }
        contentHandler(content)
        deliver = nil
    }

    override func serviceExtensionTimeWillExpire() {
        if let deliver, let placeholder { deliver(placeholder) }
        deliver = nil
    }
}
