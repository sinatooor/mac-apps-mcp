// MailTools.swift — Mail.app through AppleScript.
// Read, search, draft, two-step send, read/flag status, move, trash, attachments.
// Never empties Trash. Sending only works for a draft this server created, by its ID,
// after re-checking subject and recipients.
//
// A message is referenced as "account|mailbox|id" (returned by mail_search).

import Foundation

struct MsgRef {
    let account: String, mailbox: String, id: String
    var string: String { "\(account)|\(mailbox)|\(id)" }

    init(account: String, mailbox: String, id: String) {
        self.account = account; self.mailbox = mailbox; self.id = id
    }

    init(_ s: String) throws {
        let parts = s.components(separatedBy: "|")
        guard parts.count >= 3, Int(parts.last!) != nil else {
            throw ToolError("Invalid message ref '\(s)'. Use the ref from mail_search (account|mailbox|id).")
        }
        account = parts.first!
        id = parts.last!
        mailbox = parts[1..<(parts.count - 1)].joined(separator: "|")
    }

    var argv: [String] { [account, mailbox, id] }
}

func refs(_ a: Args, max: Int = 50) throws -> [MsgRef] {
    var list = a.list("refs")
    if let one = a.str("ref") { list.append(one) }
    if list.isEmpty { throw ToolError("Pass ref or refs.") }
    if list.count > max { throw ToolError("Too many messages at once (max \(max)).") }
    return try list.map { try MsgRef($0) }
}

// MARK: - AppleScripts

let asMailboxes = """
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "Mail"
        repeat with acc in accounts
            set accName to name of acc
            repeat with mb in mailboxes of acc
                set out to out & accName & US & (name of mb) & US & ((unread count of mb) as text) & RS
            end repeat
        end repeat
    end tell
    return out
end run
"""

let asSearch = """
on run argv
    set US to character id 31
    set RS to character id 30
    set accFilter to item 1 of argv
    set mbName to item 2 of argv
    set nDays to (item 3 of argv) as integer
    set maxN to (item 4 of argv) as integer
    set nowD to current date
    set cutoff to nowD - (nDays * days)
    set out to ""
    tell application "Mail"
        repeat with acc in accounts
            set accName to name of acc
            if accFilter is "" or accName is accFilter then
                if mbName is "" then
                    set mbs to (mailboxes of acc whose name is "INBOX" or name is "Inkorg")
                else
                    set mbs to (mailboxes of acc whose name is mbName)
                end if
                repeat with mb in mbs
                    set mbFull to name of mb
                    set msgs to (messages of mb whose date received > cutoff)
                    set n to 0
                    repeat with m in msgs
                        set n to n + 1
                        if n > maxN then exit repeat
                        set out to out & accName & US & mbFull & US & ((id of m) as text) & US & my txt(sender of m) & US & my txt(subject of m) & US & (((date received of m) - nowD) as text) & US & ((read status of m) as text) & US & ((flagged status of m) as text) & RS
                    end repeat
                end repeat
            end if
        end repeat
    end tell
    return out
end run
"""

let asRead = """
on run argv
    set US to character id 31
    set m to my findMsg(item 1 of argv, item 2 of argv, (item 3 of argv) as integer)
    tell application "Mail"
        set toList to ""
        repeat with r in to recipients of m
            set toList to toList & (address of r) & ", "
        end repeat
        set ccList to ""
        repeat with r in cc recipients of m
            set ccList to ccList & (address of r) & ", "
        end repeat
        set attList to ""
        repeat with a in mail attachments of m
            set attList to attList & (name of a) & ", "
        end repeat
        set c to my txt(content of m)
        return my txt(subject of m) & US & my txt(sender of m) & US & toList & US & ccList & US & (((date received of m) - (current date)) as text) & US & ((read status of m) as text) & US & ((flagged status of m) as text) & US & attList & US & c
    end tell
end run
"""

let asDraft = """
on run argv
    set US to character id 31
    set mode to item 1 of argv
    set subj to item 2 of argv
    set bodyText to item 3 of argv
    set fromAddr to item 4 of argv
    set toL to my splitText(item 5 of argv, US)
    set ccL to my splitText(item 6 of argv, US)
    set bccL to my splitText(item 7 of argv, US)
    set attL to my splitText(item 8 of argv, US)
    set vis to ((item 9 of argv) is "true")
    tell application "Mail"
        if mode is "new" then
            set om to make new outgoing message with properties {subject:subj, content:bodyText, visible:vis}
        else
            set m to my findMsg(item 10 of argv, item 11 of argv, (item 12 of argv) as integer)
            if mode is "reply" then
                set om to reply m opening window vis reply to all ((item 13 of argv) is "true")
            else
                set om to forward m opening window vis
            end if
            set content of om to bodyText
            if subj is not "" then set subject of om to subj
        end if
        if fromAddr is not "" then set sender of om to fromAddr
        tell om
            repeat with x in toL
                make new to recipient at end of to recipients with properties {address:(x as text)}
            end repeat
            repeat with x in ccL
                make new cc recipient at end of cc recipients with properties {address:(x as text)}
            end repeat
            repeat with x in bccL
                make new bcc recipient at end of bcc recipients with properties {address:(x as text)}
            end repeat
        end tell
        repeat with p in attL
            tell content of om
                make new attachment with properties {file name:(POSIX file (p as text))} at after last paragraph
            end tell
        end repeat
        if (count of attL) > 0 then delay 1
        try
            save om
        end try
        set toOut to ""
        repeat with r in to recipients of om
            set toOut to toOut & (address of r) & ", "
        end repeat
        return ((id of om) as text) & US & (subject of om) & US & toOut
    end tell
end run
"""

let asDraftInfo = """
on run argv
    set US to character id 31
    tell application "Mail"
        set om to first outgoing message whose id is ((item 1 of argv) as integer)
        set toOut to ""
        repeat with r in to recipients of om
            set toOut to toOut & (address of r) & US
        end repeat
        set ccOut to ""
        repeat with r in cc recipients of om
            set ccOut to ccOut & (address of r) & US
        end repeat
        if (item 2 of argv) is "send" then
            send om
            return "sent"
        end if
        return (subject of om) & (character id 30) & toOut & (character id 30) & ccOut
    end tell
end run
"""

let asStatus = """
on run argv
    set readMode to item 1 of argv
    set flagMode to item 2 of argv
    set okN to 0
    set failed to ""
    repeat with i from 3 to (count of argv) by 3
        try
            set m to my findMsg(item i of argv, item (i + 1) of argv, (item (i + 2) of argv) as integer)
            tell application "Mail"
                if readMode is "true" then set read status of m to true
                if readMode is "false" then set read status of m to false
                if flagMode is "true" then set flagged status of m to true
                if flagMode is "false" then set flagged status of m to false
            end tell
            set okN to okN + 1
        on error
            set failed to failed & (item (i + 2) of argv) & " "
        end try
    end repeat
    return (okN as text) & (character id 31) & failed
end run
"""

let asMove = """
on run argv
    set tAcc to item 1 of argv
    set tMb to item 2 of argv
    set okN to 0
    set failed to ""
    repeat with i from 3 to (count of argv) by 3
        try
            set m to my findMsg(item i of argv, item (i + 1) of argv, (item (i + 2) of argv) as integer)
            tell application "Mail"
                if tAcc is "" then
                    set srcAcc to account of (mailbox of m)
                    tell srcAcc to set tgt to first mailbox whose name is tMb
                else
                    tell account tAcc to set tgt to first mailbox whose name is tMb
                end if
                move m to tgt
            end tell
            set okN to okN + 1
        on error
            set failed to failed & (item (i + 2) of argv) & " "
        end try
    end repeat
    return (okN as text) & (character id 31) & failed
end run
"""

let asTrash = """
on run argv
    set okN to 0
    set failed to ""
    repeat with i from 1 to (count of argv) by 3
        try
            set m to my findMsg(item i of argv, item (i + 1) of argv, (item (i + 2) of argv) as integer)
            tell application "Mail" to delete m
            set okN to okN + 1
        on error
            set failed to failed & (item (i + 2) of argv) & " "
        end try
    end repeat
    return (okN as text) & (character id 31) & failed
end run
"""

let asSaveAttachments = """
on run argv
    set US to character id 31
    set m to my findMsg(item 1 of argv, item 2 of argv, (item 3 of argv) as integer)
    set folderPath to item 4 of argv
    set filt to item 5 of argv
    set saved to ""
    tell application "Mail"
        repeat with a in mail attachments of m
            set nm to name of a
            if filt is "" or nm contains filt then
                set p to folderPath & "/" & nm
                save a in (POSIX file p)
                set saved to saved & p & US
            end if
        end repeat
    end tell
    return saved
end run
"""

// MARK: - Helpers

func readMessage(_ r: MsgRef, maxChars: Int) throws -> [String: Any] {
    let out = try appleScript(asRead + asHelpers, r.argv)
    let f = out.components(separatedBy: US)
    guard f.count >= 9 else { throw ToolError("Could not read message \(r.string)") }
    let content = f[8...].joined(separator: US)
    func clean(_ s: String) -> [String] {
        s.components(separatedBy: ", ").filter { !$0.isEmpty }
    }
    var d: [String: Any] = [
        "ref": r.string,
        "subject": f[0], "from": f[1],
        "to": clean(f[2]),
        "date": dateFromOffset(f[4]),
        "unread": f[5] == "false",
        "flagged": f[6] == "true",
        "body": String(content.prefix(maxChars)),
    ]
    let cc = clean(f[3]); if !cc.isEmpty { d["cc"] = cc }
    let att = clean(f[7]); if !att.isEmpty { d["attachments"] = att }
    if content.count > maxChars { d["truncated"] = true }
    return d
}

func quoted(_ orig: [String: Any], forward: Bool) -> String {
    let body = String(((orig["body"] as? String) ?? "").prefix(6000))
    let from = orig["from"] as? String ?? ""
    let date = orig["date"] as? String ?? ""
    if forward {
        let to = (orig["to"] as? [String] ?? []).joined(separator: ", ")
        return "\n\n---------- Forwarded message ----------\nFrom: \(from)\nDate: \(date)\nSubject: \(orig["subject"] as? String ?? "")\nTo: \(to)\n\n\(body)"
    }
    let q = body.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    return "\n\nOn \(date), \(from) wrote:\n\(q)"
}

func batchResult(_ out: String, total: Int) -> [String: Any] {
    let p = out.components(separatedBy: US)
    let ok = Int(p.first ?? "") ?? 0
    var d: [String: Any] = ["done": ok, "requested": total]
    let failed = (p.count > 1 ? p[1] : "").split(separator: " ").map(String.init)
    if !failed.isEmpty { d["failed_ids"] = failed }
    return d
}

// MARK: - Tools

let mailTools: [Tool] = [
    Tool(app: "mail", name: "mail_mailboxes",
         description: "List Mail accounts and mailboxes with unread counts.",
         properties: ["account": prop("string")], required: [], kind: .read) { a in
        var rows = records(try appleScript(asMailboxes)).filter { $0.count >= 3 }
        if let acc = a.str("account") { rows = rows.filter { $0[0] == acc } }
        return rows.map { ["account": $0[0], "mailbox": $0[1], "unread": Int($0[2]) ?? 0] as [String: Any] }
    },

    Tool(app: "mail", name: "mail_search",
         description: "Search messages, newest first. Returns refs for other mail tools.",
         properties: [
            "account": prop("string", "default all accounts"),
            "mailbox": prop("string", "default: each account's inbox (INBOX/Inkorg)"),
            "days": prop("integer", "received in last N days, default 7, max 90"),
            "from": prop("string", "sender contains"),
            "subject": prop("string", "subject contains"),
            "unread_only": prop("boolean"),
            "flagged_only": prop("boolean"),
            "limit": prop("integer", "default 25"),
         ], required: [], kind: .read) { a in
        let days = min(max(a.int("days") ?? 7, 1), 90)
        let out = try appleScript(asSearch + asHelpers, [a.str("account") ?? "", a.str("mailbox") ?? "", String(days), "500"])
        let fromQ = a.str("from")?.lowercased(), subjQ = a.str("subject")?.lowercased()
        var rows: [(Double, [String: Any])] = []
        for f in records(out) where f.count >= 8 {
            if let q = fromQ, !f[3].lowercased().contains(q) { continue }
            if let q = subjQ, !f[4].lowercased().contains(q) { continue }
            let unread = f[6] == "false", flagged = f[7] == "true"
            if a.bool("unread_only") == true && !unread { continue }
            if a.bool("flagged_only") == true && !flagged { continue }
            var d: [String: Any] = [
                "ref": MsgRef(account: f[0], mailbox: f[1], id: f[2]).string,
                "from": f[3], "subject": f[4], "date": dateFromOffset(f[5]),
            ]
            if unread { d["unread"] = true }
            if flagged { d["flagged"] = true }
            rows.append((Double(f[5]) ?? 0, d))
        }
        rows.sort { $0.0 > $1.0 }
        let limit = a.int("limit") ?? 25
        return ["count": rows.count, "messages": rows.prefix(limit).map { $0.1 }] as [String: Any]
    },

    Tool(app: "mail", name: "mail_read",
         description: "Read one message (headers, body, attachment names).",
         properties: ["ref": prop("string"), "max_chars": prop("integer", "default 8000")],
         required: ["ref"], kind: .read) { a in
        try readMessage(try MsgRef(try a.req("ref")), maxChars: a.int("max_chars") ?? 8000)
    },

    Tool(app: "mail", name: "mail_create_draft",
         description: "Create a draft (new, reply or forward) and save it to Drafts. Does not send. Returns draft_id.",
         properties: [
            "to": listProp(), "cc": listProp(), "bcc": listProp(),
            "subject": prop("string", "for reply/forward: default keeps original"),
            "body": prop("string", "plain text"),
            "reply_to": prop("string", "ref of message to reply to"),
            "reply_all": prop("boolean"),
            "forward": prop("string", "ref of message to forward"),
            "from": prop("string", "sender address, default account default"),
            "attachments": listProp("absolute file paths"),
            "open_window": prop("boolean", "show the draft window, default false"),
         ], required: ["body"], kind: .write) { a in
        var body = try a.req("body")
        var mode = "new"
        var src: MsgRef? = nil
        if let r = a.str("reply_to") { mode = "reply"; src = try MsgRef(r) }
        if let f = a.str("forward") { mode = "forward"; src = try MsgRef(f) }
        if let s = src { body += quoted(try readMessage(s, maxChars: 6000), forward: mode == "forward") }
        if mode == "new" && a.list("to").isEmpty { throw ToolError("to is required for a new message.") }
        if mode == "new" && a.str("subject") == nil { throw ToolError("subject is required for a new message.") }
        for p in a.list("attachments") where !FileManager.default.fileExists(atPath: p) {
            throw ToolError("Attachment not found: \(p)")
        }
        var argv = [mode, a.str("subject") ?? "", body, a.str("from") ?? "",
                    a.list("to").joined(separator: US), a.list("cc").joined(separator: US),
                    a.list("bcc").joined(separator: US), a.list("attachments").joined(separator: US),
                    a.bool("open_window") == true ? "true" : "false"]
        if let s = src { argv += s.argv + [a.bool("reply_all") == true ? "true" : "false"] }
        let out = try appleScript(asDraft + asHelpers, argv).components(separatedBy: US)
        guard out.count >= 3 else { throw ToolError("Draft creation returned no ID.") }
        let to = out[2].components(separatedBy: ", ").filter { !$0.isEmpty }
        audit("mail_create_draft", "draft \(out[0]) | \(out[1]) | to \(to.joined(separator: ","))")
        return ["draft_id": out[0], "subject": out[1], "to": to,
                "note": "Saved to Drafts. To send, call mail_send_draft with this draft_id after the user approves."] as [String: Any]
    },

    Tool(app: "mail", name: "mail_send_draft",
         description: "Send a draft made by mail_create_draft. Only after explicit user approval. subject and to must match the draft.",
         properties: [
            "draft_id": prop("string"),
            "subject": prop("string", "must equal the draft subject"),
            "to": listProp("must equal the draft's To addresses"),
         ], required: ["draft_id", "subject", "to"], kind: .destructive) { a in
        let id = try a.req("draft_id")
        guard Int(id) != nil else { throw ToolError("Invalid draft_id.") }
        let info: String
        do { info = try appleScript(asDraftInfo, [id, "check"]) }
        catch { throw ToolError("Draft \(id) not found. It may have been closed or Mail restarted; send it from the Drafts mailbox instead.") }
        let parts = info.components(separatedBy: RS)
        let subject = parts.first ?? ""
        let to = Set((parts.count > 1 ? parts[1] : "").components(separatedBy: US).filter { !$0.isEmpty }.map { $0.lowercased() })
        let expectTo = Set(a.list("to").map { $0.lowercased() })
        let expectSubject = try a.req("subject")
        if subject != expectSubject || to != expectTo {
            throw ToolError("Draft doesn't match. Draft subject: '\(subject)', to: \(to.sorted()). Not sent.")
        }
        _ = try appleScript(asDraftInfo, [id, "send"])
        audit("mail_send_draft", "SENT draft \(id) | \(subject) | to \(to.sorted().joined(separator: ","))")
        return ["sent": true, "subject": subject, "to": to.sorted()] as [String: Any]
    },

    Tool(app: "mail", name: "mail_set_status",
         description: "Mark messages read/unread and/or flagged/unflagged.",
         properties: [
            "refs": listProp(), "ref": prop("string"),
            "read": prop("boolean"), "flagged": prop("boolean"),
         ], required: [], kind: .write) { a in
        let rs = try refs(a)
        let readMode = a.bool("read").map { $0 ? "true" : "false" } ?? ""
        let flagMode = a.bool("flagged").map { $0 ? "true" : "false" } ?? ""
        if readMode.isEmpty && flagMode.isEmpty { throw ToolError("Pass read and/or flagged.") }
        let out = try appleScript(asStatus + asHelpers, [readMode, flagMode] + rs.flatMap { $0.argv })
        audit("mail_set_status", "read=\(readMode) flagged=\(flagMode) | \(rs.map { $0.string }.joined(separator: ", "))")
        return batchResult(out, total: rs.count)
    },

    Tool(app: "mail", name: "mail_move",
         description: "Move messages to a mailbox, e.g. Archive. Default: same account.",
         properties: [
            "refs": listProp(), "ref": prop("string"),
            "to_mailbox": prop("string"), "to_account": prop("string"),
         ], required: ["to_mailbox"], kind: .write) { a in
        let rs = try refs(a)
        let target = try a.req("to_mailbox")
        if target.lowercased().contains("trash") || target.lowercased().contains("deleted") || target.lowercased().contains("papperskorg") {
            throw ToolError("Use mail_trash to move messages to Trash.")
        }
        let out = try appleScript(asMove + asHelpers, [a.str("to_account") ?? "", target] + rs.flatMap { $0.argv })
        audit("mail_move", "-> \(target) | \(rs.map { $0.string }.joined(separator: ", "))")
        return batchResult(out, total: rs.count)
    },

    Tool(app: "mail", name: "mail_trash",
         description: "Move messages to Trash (recoverable). Never empties Trash.",
         properties: ["refs": listProp(), "ref": prop("string")],
         required: [], kind: .destructive) { a in
        let rs = try refs(a)
        let out = try appleScript(asTrash + asHelpers, rs.flatMap { $0.argv })
        audit("mail_trash", rs.map { $0.string }.joined(separator: ", "))
        return batchResult(out, total: rs.count)
    },

    Tool(app: "mail", name: "mail_save_attachments",
         description: "Save a message's attachments to a folder (default ~/Downloads/Mail Attachments).",
         properties: [
            "ref": prop("string"), "folder": prop("string", "absolute path"),
            "name_contains": prop("string", "only matching attachments"),
         ], required: ["ref"], kind: .write) { a in
        let r = try MsgRef(try a.req("ref"))
        let folder = a.str("folder") ?? (NSHomeDirectory() + "/Downloads/Mail Attachments")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let out = try appleScript(asSaveAttachments + asHelpers, r.argv + [folder, a.str("name_contains") ?? ""])
        let saved = out.components(separatedBy: US).filter { !$0.isEmpty }
        audit("mail_save_attachments", "\(r.string) -> \(saved.count) files in \(folder)")
        return ["saved": saved] as [String: Any]
    },
]
