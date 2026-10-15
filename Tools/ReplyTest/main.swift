// A development tool: posts a chat-style notification with a Reply box (like WhatsApp's) and logs the
// reply it gets back, so Shima's notification replies can be tried without anyone sending a message.
//
//   Tools/ReplyTest/build.sh && open "build/Shima Reply Test.app" --args "Alex Morgan" "Nachos at seven?"
//
// Replies are logged under io.github.vendavalsc.shima.replytest:
//   /usr/bin/log show --last 5m --info --predicate 'subsystem == "io.github.vendavalsc.shima.replytest"'
import AppKit
import UserNotifications
import os

private let log = Logger(subsystem: "io.github.vendavalsc.shima.replytest", category: "reply")

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "reply", title: "Reply", options: [],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Message")
        center.setNotificationCategories([UNNotificationCategory(identifier: "message", actions: [reply],
                                                                 intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            guard granted else {
                log.error("notifications not allowed: \(error?.localizedDescription ?? "denied", privacy: .public)")
                DispatchQueue.main.async { NSApp.terminate(nil) }
                return
            }
            let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
            let content = UNMutableNotificationContent()
            content.title = arguments.first ?? "Alex Morgan"
            content.body = arguments.dropFirst().first ?? "Nachos at seven? I'll bring the cheese."
            content.categoryIdentifier = "message"
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
                log.info("posted: \(error == nil, privacy: .public)")
            }
        }
        // Long enough to reply; then it goes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 180) { NSApp.terminate(nil) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let reply = response as? UNTextInputNotificationResponse {
            log.info("reply: \(reply.userText, privacy: .public)")
        } else {
            log.info("action: \(response.actionIdentifier, privacy: .public)")
        }
        completionHandler()
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
