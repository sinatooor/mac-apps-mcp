// NotifyTools.swift — notifications to the user only.
//  - Mac banner via AppleScript `display notification`.
//  - phone=true: a reminder due in 1 minute in the "Claude alerts" list (created if missing);
//    Reminders syncs through iCloud, so iPhone/Watch alert too.
//  - imessage=true: an iMessage to the user's OWN handle, set with `--self-handle` in the config.
//    The tool has no way to message anyone else.

import Foundation
import EventKit

let alertListName = "Claude alerts"

/// The user's own iMessage handle (phone or Apple ID), from `--self-handle <handle>`.
let selfHandle: String? = {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--self-handle"), i + 1 < args.count { return args[i + 1] }
    return nil
}()

let asNotify = """
on run argv
    if (item 3 of argv) is "" then
        display notification (item 2 of argv) with title (item 1 of argv)
    else
        display notification (item 2 of argv) with title (item 1 of argv) sound name (item 3 of argv)
    end if
    return "ok"
end run
"""

let asIMessage = """
on run argv
    tell application "Messages"
        set svc to 1st account whose service type = iMessage
        set target to participant (item 1 of argv) of svc
        send (item 2 of argv) to target
    end tell
    return "ok"
end run
"""

/// Finds the "Claude alerts" reminder list, creating it in the default account if needed.
func alertList() throws -> EKCalendar {
    if let existing = ekStore.calendars(for: .reminder).first(where: { $0.title == alertListName }) {
        return existing
    }
    guard let source = ekStore.defaultCalendarForNewReminders()?.source else {
        throw ToolError("No default Reminders account to create '\(alertListName)' in.")
    }
    let cal = EKCalendar(for: .reminder, eventStore: ekStore)
    cal.title = alertListName
    cal.source = source
    try ekStore.saveCalendar(cal, commit: true)
    audit("notify", "created reminder list '\(alertListName)'")
    return cal
}

let notifyTools: [Tool] = [
    Tool(app: "notify", name: "notify",
         description: "Notify the user (only the user). Mac banner always; phone=true adds a reminder alert in 'Claude alerts' (iPhone/Watch); imessage=true sends an iMessage to the user's own number.",
         properties: [
            "title": prop("string"),
            "message": prop("string"),
            "sound": prop("boolean", "default true"),
            "phone": prop("boolean", "iPhone alert via Reminders, default false"),
            "imessage": prop("boolean", "iMessage to self, default false"),
         ], required: ["title", "message"], kind: .write) { a in
        let title = try a.req("title")
        let message = try a.req("message")
        var result: [String: Any] = [:]

        do {
            _ = try appleScript(asNotify, [title, message, (a.bool("sound") ?? true) ? "Glass" : ""])
            result["mac"] = true
        } catch {
            result["mac_error"] = error.localizedDescription
        }

        if a.bool("phone") == true {
            try ensureEventKitAccess(.reminder)
            let r = EKReminder(eventStore: ekStore)
            r.title = "\(title): \(message)"
            r.calendar = try alertList()
            let due = Date().addingTimeInterval(60)
            r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            r.addAlarm(EKAlarm(absoluteDate: due))
            try ekStore.save(r, commit: true)
            result["phone"] = true
        }

        if a.bool("imessage") == true {
            guard let handle = selfHandle else {
                throw ToolError("iMessage needs your own number or Apple ID: add \"--self-handle\", \"<it>\" to args in the Claude config.")
            }
            _ = try appleScript(asIMessage, [handle, "\(title): \(message)"])
            result["imessage"] = true
        }

        audit("notify", "\(title) | phone=\(a.bool("phone") == true) imessage=\(a.bool("imessage") == true)")
        return result
    },
]
