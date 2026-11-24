// EventKitTools.swift — Calendar and Reminders through Apple's EventKit.
// Read, create and edit. There is deliberately NO call to store.remove(...) anywhere:
// events and reminders cannot be deleted through this server.

import Foundation
import EventKit

let ekStore = EKEventStore()
var eventAccessOK = false
var reminderAccessOK = false

func ensureEventKitAccess(_ type: EKEntityType) throws {
    if type == .event && eventAccessOK { return }
    if type == .reminder && reminderAccessOK { return }
    let status = EKEventStore.authorizationStatus(for: type)
    var granted = false
    if #available(macOS 14.0, *) {
        granted = (status == .fullAccess)
    } else {
        granted = (status == .authorized)
    }
    let what = type == .event ? "Calendars" : "Reminders"
    if !granted {
        if status == .denied || status == .restricted {
            throw ToolError("\(what) access is denied. Enable it in System Settings > Privacy & Security > \(what).")
        }
        let sem = DispatchSemaphore(value: 0)
        let done: (Bool, Error?) -> Void = { ok, _ in granted = ok; sem.signal() }
        if #available(macOS 14.0, *) {
            if type == .event { ekStore.requestFullAccessToEvents(completion: done) }
            else { ekStore.requestFullAccessToReminders(completion: done) }
        } else {
            ekStore.requestAccess(to: type, completion: done)
        }
        sem.wait()
        if !granted { throw ToolError("\(what) access was not granted.") }
        ekStore.reset()
    }
    if type == .event { eventAccessOK = true } else { reminderAccessOK = true }
}

func calType(_ t: EKCalendarType) -> String {
    switch t {
    case .local: return "local"
    case .calDAV: return "caldav"
    case .exchange: return "exchange"
    case .subscription: return "subscribed"
    case .birthday: return "birthdays"
    @unknown default: return "other"
    }
}

func findCalendar(_ title: String, _ type: EKEntityType) throws -> EKCalendar {
    let all = ekStore.calendars(for: type)
    if let exact = all.first(where: { $0.title.lowercased() == title.lowercased() }) { return exact }
    let partial = all.filter { $0.title.lowercased().contains(title.lowercased()) }
    if partial.count == 1 { return partial[0] }
    if partial.isEmpty { throw ToolError("No \(type == .event ? "calendar" : "reminder list") named '\(title)'.") }
    throw ToolError("'\(title)' matches several: \(partial.map { $0.title }.joined(separator: ", ")). Be more specific.")
}

func writableCheck(_ c: EKCalendar) throws {
    if !c.allowsContentModifications {
        throw ToolError("'\(c.title)' is read-only (subscribed or locked) and can't be changed.")
    }
}

// MARK: - Calendar

func eventDict(_ ev: EKEvent) -> [String: Any] {
    var item: [String: Any] = [
        "id": ev.eventIdentifier ?? "",
        "title": ev.title ?? "",
        "start": ev.isAllDay ? dayFmt.string(from: ev.startDate) : outFmt.string(from: ev.startDate),
        "end": ev.isAllDay ? dayFmt.string(from: ev.endDate) : outFmt.string(from: ev.endDate),
        "calendar": ev.calendar.title,
    ]
    if ev.isAllDay { item["all_day"] = true }
    if let loc = ev.location, !loc.isEmpty { item["location"] = loc }
    if ev.hasRecurrenceRules { item["recurring"] = true }
    if let att = ev.attendees, !att.isEmpty { item["attendees"] = att.count }
    return item
}

func fetchEvents(_ start: Date, _ end: Date, calendar: String?) throws -> [EKEvent] {
    var cals = ekStore.calendars(for: .event)
    if let c = calendar {
        cals = cals.filter { $0.title.lowercased().contains(c.lowercased()) }
        if cals.isEmpty { return [] }
    }
    let pred = ekStore.predicateForEvents(withStart: start, end: end, calendars: cals)
    return ekStore.events(matching: pred).sorted { $0.startDate < $1.startDate }
}

func findEvent(_ a: Args) throws -> EKEvent {
    let id = try a.req("id")
    if let occ = try a.date("occurrence_start") {
        let day = Calendar.current.startOfDay(for: occ)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: day)!
        let evs = ekStore.events(matching: ekStore.predicateForEvents(withStart: day, end: next, calendars: nil))
            .filter { $0.eventIdentifier == id }
        if let ev = evs.first(where: { abs($0.startDate.timeIntervalSince(occ)) < 60 }) ?? evs.first { return ev }
    }
    guard let ev = ekStore.event(withIdentifier: id) else { throw ToolError("Event not found: \(id)") }
    return ev
}

let calendarTools: [Tool] = [
    Tool(app: "calendar", name: "calendar_list",
         description: "List calendars (title, account, type, writable).",
         properties: [:], required: [], kind: .read) { _ in
        try ensureEventKitAccess(.event)
        return ekStore.calendars(for: .event)
            .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            .map { ["title": $0.title, "account": $0.source.title, "type": calType($0.type),
                    "writable": $0.allowsContentModifications] as [String: Any] }
    },

    Tool(app: "calendar", name: "calendar_get_events",
         description: "Events between start and end (max 92 days), recurring expanded.",
         properties: [
            "start": prop("string", "YYYY-MM-DD or YYYY-MM-DDTHH:mm, local time"),
            "end": prop("string", "exclusive"),
            "calendar": prop("string", "calendar title contains"),
            "query": prop("string", "title or location contains"),
            "include_notes": prop("boolean"),
         ], required: ["start", "end"], kind: .read) { a in
        try ensureEventKitAccess(.event)
        guard let s = try a.date("start"), let e = try a.date("end") else { throw ToolError("start and end required") }
        if e.timeIntervalSince(s) > 92 * 86400 { throw ToolError("Range too large (max 92 days).") }
        let q = a.str("query")?.lowercased()
        var out: [[String: Any]] = []
        for ev in try fetchEvents(s, e, calendar: a.str("calendar")) {
            if let q = q, !((ev.title ?? "").lowercased().contains(q) || (ev.location ?? "").lowercased().contains(q)) { continue }
            var d = eventDict(ev)
            if a.bool("include_notes") == true, let n = ev.notes, !n.isEmpty { d["notes"] = String(n.prefix(500)) }
            out.append(d)
        }
        return ["timezone": TimeZone.current.identifier, "events": out] as [String: Any]
    },

    Tool(app: "calendar", name: "calendar_free_slots",
         description: "Free time between start and end (max 31 days) within working hours.",
         properties: [
            "start": prop("string"), "end": prop("string"),
            "day_start": prop("string", "HH:mm, default 08:00"),
            "day_end": prop("string", "HH:mm, default 18:00"),
            "min_minutes": prop("integer", "default 30"),
            "skip_weekends": prop("boolean", "default true"),
         ], required: ["start", "end"], kind: .read) { a in
        try ensureEventKitAccess(.event)
        guard let s = try a.date("start"), let e = try a.date("end") else { throw ToolError("start and end required") }
        if e.timeIntervalSince(s) > 31 * 86400 { throw ToolError("Range too large (max 31 days).") }
        let cal = Calendar.current
        func hm(_ t: String) -> (Int, Int) {
            let p = t.split(separator: ":").compactMap { Int($0) }
            return (p.first ?? 0, p.count > 1 ? p[1] : 0)
        }
        let (sh, sm) = hm(a.str("day_start") ?? "08:00")
        let (eh, em) = hm(a.str("day_end") ?? "18:00")
        let minSecs = Double((a.int("min_minutes") ?? 30) * 60)
        let skipWeekends = a.bool("skip_weekends") ?? true
        let busy = try fetchEvents(s, e, calendar: nil)
            .filter { !$0.isAllDay && $0.availability != .free }
            .map { ($0.startDate!, $0.endDate!) }
        var slots: [[String: String]] = []
        var day = cal.startOfDay(for: s)
        while day < e {
            defer { day = cal.date(byAdding: .day, value: 1, to: day)! }
            if skipWeekends && cal.isDateInWeekend(day) { continue }
            var cursor = max(cal.date(bySettingHour: sh, minute: sm, second: 0, of: day)!, s)
            let windowEnd = min(cal.date(bySettingHour: eh, minute: em, second: 0, of: day)!, e)
            for (bs, be) in busy where be > cursor && bs < windowEnd {
                if bs.timeIntervalSince(cursor) >= minSecs {
                    slots.append(["start": outFmt.string(from: cursor), "end": outFmt.string(from: bs)])
                }
                cursor = max(cursor, be)
            }
            if windowEnd.timeIntervalSince(cursor) >= minSecs {
                slots.append(["start": outFmt.string(from: cursor), "end": outFmt.string(from: windowEnd)])
            }
        }
        return ["timezone": TimeZone.current.identifier, "free_slots": slots] as [String: Any]
    },

    Tool(app: "calendar", name: "calendar_create_event",
         description: "Create an event. Default calendar if none given.",
         properties: [
            "title": prop("string"),
            "start": prop("string", "YYYY-MM-DDTHH:mm, or YYYY-MM-DD for all-day"),
            "end": prop("string", "default start + 1h (all-day: + 1 day)"),
            "calendar": prop("string"),
            "location": prop("string"),
            "notes": prop("string"),
            "url": prop("string"),
            "alert_minutes": prop("integer", "alert N minutes before"),
         ], required: ["title", "start"], kind: .write) { a in
        try ensureEventKitAccess(.event)
        guard let start = try a.date("start") else { throw ToolError("start required") }
        let allDay = isDateOnly(a.str("start"))
        let ev = EKEvent(eventStore: ekStore)
        ev.title = try a.req("title")
        ev.isAllDay = allDay
        ev.startDate = start
        ev.endDate = try a.date("end") ?? start.addingTimeInterval(allDay ? 86400 : 3600)
        if ev.endDate < ev.startDate { throw ToolError("end is before start") }
        if let c = a.str("calendar") { ev.calendar = try findCalendar(c, .event) }
        else if let def = ekStore.defaultCalendarForNewEvents { ev.calendar = def }
        else { throw ToolError("No default calendar; pass calendar.") }
        try writableCheck(ev.calendar)
        if let l = a.str("location") { ev.location = l }
        if let n = a.str("notes") { ev.notes = n }
        if let u = a.str("url") { ev.url = URL(string: u) }
        if let m = a.int("alert_minutes") { ev.addAlarm(EKAlarm(relativeOffset: TimeInterval(-m * 60))) }
        try ekStore.save(ev, span: .thisEvent, commit: true)
        audit("calendar_create_event", "\(ev.title ?? "") | \(outFmt.string(from: ev.startDate)) | \(ev.calendar.title)")
        return ["created": eventDict(ev)]
    },

    Tool(app: "calendar", name: "calendar_update_event",
         description: "Edit an event you own. For one occurrence of a recurring event pass occurrence_start.",
         properties: [
            "id": prop("string"),
            "occurrence_start": prop("string", "start of the occurrence to edit"),
            "span": prop("string", "this (default) or future"),
            "title": prop("string"), "start": prop("string"), "end": prop("string"),
            "location": prop("string"), "notes": prop("string"),
            "calendar": prop("string", "move to this calendar"),
         ], required: ["id"], kind: .write) { a in
        try ensureEventKitAccess(.event)
        let ev = try findEvent(a)
        try writableCheck(ev.calendar)
        if let org = ev.organizer, !org.isCurrentUser {
            throw ToolError("You're not the organizer of '\(ev.title ?? "")', so it can't be edited here.")
        }
        let before = "\(ev.title ?? "") @ \(outFmt.string(from: ev.startDate))"
        let duration = ev.endDate.timeIntervalSince(ev.startDate)
        if let t = a.str("title") { ev.title = t }
        if let s = try a.date("start") {
            ev.startDate = s
            if !a.has("end") { ev.endDate = s.addingTimeInterval(duration) }
        }
        if let e = try a.date("end") { ev.endDate = e }
        if ev.endDate < ev.startDate { throw ToolError("end is before start") }
        if a.has("location") { ev.location = a.str("location") }
        if a.has("notes") { ev.notes = a.str("notes") }
        if let c = a.str("calendar") {
            let target = try findCalendar(c, .event)
            try writableCheck(target)
            ev.calendar = target
        }
        let span: EKSpan = a.str("span") == "future" ? .futureEvents : .thisEvent
        try ekStore.save(ev, span: span, commit: true)
        audit("calendar_update_event", "\(before) -> \(ev.title ?? "") @ \(outFmt.string(from: ev.startDate))")
        return ["updated": eventDict(ev)]
    },
]

// MARK: - Reminders

func fetchReminders(_ pred: NSPredicate) -> [EKReminder] {
    let sem = DispatchSemaphore(value: 0)
    var result: [EKReminder] = []
    ekStore.fetchReminders(matching: pred) { r in result = r ?? []; sem.signal() }
    sem.wait()
    return result
}

func dueDate(_ r: EKReminder) -> Date? {
    guard let c = r.dueDateComponents else { return nil }
    return Calendar.current.date(from: c)
}

func reminderDict(_ r: EKReminder) -> [String: Any] {
    var d: [String: Any] = [
        "id": r.calendarItemIdentifier,
        "title": r.title ?? "",
        "list": r.calendar.title,
    ]
    if let c = r.dueDateComponents, let due = Calendar.current.date(from: c) {
        d["due"] = (c.hour == nil) ? dayFmt.string(from: due) : outFmt.string(from: due)
    }
    if r.isCompleted { d["completed"] = true }
    if r.priority > 0 { d["priority"] = r.priority }
    if let n = r.notes, !n.isEmpty { d["notes"] = String(n.prefix(200)) }
    return d
}

func setDue(_ r: EKReminder, _ raw: String) throws {
    guard let d = parseDate(raw) else { throw ToolError("Invalid due date: \(raw)") }
    if isDateOnly(raw) {
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: d)
    } else {
        r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        r.alarms?.forEach { r.removeAlarm($0) }   // removes the old alert, not the reminder
        r.addAlarm(EKAlarm(absoluteDate: d))
    }
}

let reminderTools: [Tool] = [
    Tool(app: "reminders", name: "reminders_lists",
         description: "List reminder lists.",
         properties: [:], required: [], kind: .read) { _ in
        try ensureEventKitAccess(.reminder)
        return ekStore.calendars(for: .reminder).map {
            ["title": $0.title, "account": $0.source.title, "writable": $0.allowsContentModifications] as [String: Any]
        }
    },

    Tool(app: "reminders", name: "reminders_get",
         description: "Reminders, open ones by default, sorted by due date.",
         properties: [
            "list": prop("string"),
            "query": prop("string", "title contains"),
            "due_before": prop("string"),
            "include_completed": prop("boolean"),
            "limit": prop("integer", "default 50"),
         ], required: [], kind: .read) { a in
        try ensureEventKitAccess(.reminder)
        var cals: [EKCalendar]? = nil
        if let l = a.str("list") { cals = [try findCalendar(l, .reminder)] }
        let dueBefore = try a.date("due_before")
        let pred: NSPredicate = (a.bool("include_completed") == true)
            ? ekStore.predicateForReminders(in: cals)
            : ekStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: dueBefore, calendars: cals)
        var rs = fetchReminders(pred)
        if let q = a.str("query")?.lowercased() { rs = rs.filter { ($0.title ?? "").lowercased().contains(q) } }
        rs.sort { (dueDate($0) ?? .distantFuture) < (dueDate($1) ?? .distantFuture) }
        return Array(rs.prefix(a.int("limit") ?? 50)).map(reminderDict)
    },

    Tool(app: "reminders", name: "reminders_create",
         description: "Create a reminder. due: YYYY-MM-DD or YYYY-MM-DDTHH:mm (time adds an alert).",
         properties: [
            "title": prop("string"), "list": prop("string"), "due": prop("string"),
            "notes": prop("string"), "priority": prop("integer", "1 high, 5 medium, 9 low"),
         ], required: ["title"], kind: .write) { a in
        try ensureEventKitAccess(.reminder)
        let r = EKReminder(eventStore: ekStore)
        r.title = try a.req("title")
        if let l = a.str("list") { r.calendar = try findCalendar(l, .reminder) }
        else if let def = ekStore.defaultCalendarForNewReminders() { r.calendar = def }
        else { throw ToolError("No default reminder list; pass list.") }
        try writableCheck(r.calendar)
        if let d = a.str("due") { try setDue(r, d) }
        if let n = a.str("notes") { r.notes = n }
        if let p = a.int("priority") { r.priority = p }
        try ekStore.save(r, commit: true)
        audit("reminders_create", "\(r.title ?? "") | \(r.calendar.title)")
        return ["created": reminderDict(r)]
    },

    Tool(app: "reminders", name: "reminders_update",
         description: "Edit a reminder or mark it done/undone.",
         properties: [
            "id": prop("string"), "title": prop("string"), "due": prop("string"),
            "notes": prop("string"), "priority": prop("integer"),
            "completed": prop("boolean"), "list": prop("string", "move to list"),
         ], required: ["id"], kind: .write) { a in
        try ensureEventKitAccess(.reminder)
        let id = try a.req("id")
        guard let r = ekStore.calendarItem(withIdentifier: id) as? EKReminder else { throw ToolError("Reminder not found: \(id)") }
        try writableCheck(r.calendar)
        if let t = a.str("title") { r.title = t }
        if let d = a.str("due") { try setDue(r, d) }
        if a.has("notes") { r.notes = a.str("notes") }
        if let p = a.int("priority") { r.priority = p }
        if let c = a.bool("completed") { r.isCompleted = c }
        if let l = a.str("list") {
            let target = try findCalendar(l, .reminder)
            try writableCheck(target)
            r.calendar = target
        }
        try ekStore.save(r, commit: true)
        audit("reminders_update", "\(r.title ?? "") | completed=\(r.isCompleted)")
        return ["updated": reminderDict(r)]
    },
]
