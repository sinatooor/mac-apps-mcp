// NotesTools.swift — Notes.app through AppleScript.
// Folders, search, read, create, edit (replace/append), move, create folder, delete.
// Delete moves a note to "Recently Deleted" (restorable for 30 days). Locked notes are skipped.

import Foundation

func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}

/// Plain text → Notes HTML (one <div> per line). format "html" passes through unchanged.
func notesHTML(_ text: String, format: String?) -> String {
    if format == "html" { return text }
    return text.components(separatedBy: "\n")
        .map { $0.isEmpty ? "<div><br></div>" : "<div>\(htmlEscape($0))</div>" }
        .joined()
}

func titleHTML(_ title: String) -> String { "<div><h1>\(htmlEscape(title))</h1></div>" }

let asNotesFolders = """
on run argv
    set US to character id 31
    set RS to character id 30
    set out to ""
    tell application "Notes"
        repeat with acc in accounts
            set an to name of acc
            repeat with f in folders of acc
                set out to out & an & US & (name of f) & US & ((count of notes of f) as text) & RS
            end repeat
        end repeat
    end tell
    return out
end run
"""

let asNotesSearch = """
on run argv
    set US to character id 31
    set RS to character id 30
    set q to item 1 of argv
    set fName to item 2 of argv
    set aName to item 3 of argv
    set nowD to current date
    tell application "Notes"
        if fName is not "" then
            if aName is "" then
                set fl to first folder whose name is fName
            else
                tell account aName to set fl to first folder whose name is fName
            end if
            if q is "" then
                set src to a reference to (notes of fl)
            else
                set src to a reference to (notes of fl whose name contains q or plaintext contains q)
            end if
        else if aName is not "" then
            if q is "" then
                set src to a reference to (notes of account aName)
            else
                set src to a reference to (notes of account aName whose name contains q or plaintext contains q)
            end if
        else
            if q is "" then
                set src to a reference to notes
            else
                set src to a reference to (notes whose name contains q or plaintext contains q)
            end if
        end if
        set ids to id of src
        set nms to name of src
        set mds to modification date of src
        set lks to {}
        try
            set lks to password protected of src
        end try
        -- Notes doesn't report a note's folder directly, so list each folder's note ids instead.
        set mapOut to ""
        repeat with f in folders
            set fn to name of f
            try
                set fids to id of notes of f
                repeat with x in fids
                    set mapOut to mapOut & (contents of x) & US & fn & RS
                end repeat
            end try
        end repeat
    end tell
    set n to count of ids
    set out to ""
    repeat with i from 1 to n
        set lk to "false"
        if (count of lks) is n then set lk to (item i of lks) as text
        set out to out & (item i of ids) & US & my txt(item i of nms) & US & "" & US & (((item i of mds) - nowD) as text) & US & lk & RS
    end repeat
    return out & (character id 29) & mapOut
end run
"""

let asNotesRead = """
on run argv
    set US to character id 31
    tell application "Notes"
        set nt to note id (item 1 of argv)
        set fld to ""
        try
            set fld to name of container of nt
        end try
        set offs to ((modification date of nt) - (current date)) as text
        if password protected of nt then
            return my txt(name of nt) & US & fld & US & offs & US & "true" & US & "" & US & ""
        end if
        return my txt(name of nt) & US & fld & US & offs & US & "false" & US & my txt(plaintext of nt) & US & my txt(body of nt)
    end tell
end run
"""

let asNotesFolderRef = """

on getFolder(fName, aName)
    tell application "Notes"
        if aName is "" then
            set acc to default account
        else
            set acc to account aName
        end if
        if fName is "" then
            try
                return default folder of acc
            on error
                return first folder of acc
            end try
        end if
        tell acc to return first folder whose name is fName
    end tell
end getFolder
"""

let asNotesCreate = """
on run argv
    set US to character id 31
    set fl to my getFolder(item 2 of argv, item 3 of argv)
    tell application "Notes"
        set nt to make new note at fl with properties {body:(item 1 of argv)}
        return (id of nt) & US & my txt(name of nt)
    end tell
end run
"""

let asNotesUpdate = """
on run argv
    set US to character id 31
    tell application "Notes"
        set nt to note id (item 1 of argv)
        if password protected of nt then error "This note is locked and can't be edited."
        if (item 3 of argv) is "append" then
            set body of nt to (body of nt) & (item 2 of argv)
        else
            set body of nt to (item 2 of argv)
        end if
        return (id of nt) & US & my txt(name of nt)
    end tell
end run
"""

let asNotesMove = """
on run argv
    set US to character id 31
    set fl to my getFolder(item 2 of argv, item 3 of argv)
    tell application "Notes"
        set nt to note id (item 1 of argv)
        move nt to fl
        return my txt(name of nt) & US & (name of fl)
    end tell
end run
"""

let asNotesNewFolder = """
on run argv
    tell application "Notes"
        if (item 2 of argv) is "" then
            set acc to default account
        else
            set acc to account (item 2 of argv)
        end if
        set fl to make new folder at acc with properties {name:(item 1 of argv)}
        return (name of fl) & (character id 31) & (name of acc)
    end tell
end run
"""

let asNotesDelete = """
on run argv
    tell application "Notes"
        set nt to note id (item 1 of argv)
        set nm to my txt(name of nt)
        delete nt
        return nm
    end tell
end run
"""

func readNote(_ id: String, html: Bool, maxChars: Int) throws -> [String: Any] {
    let f = try appleScript(asNotesRead + asHelpers, [id]).components(separatedBy: US)
    guard f.count >= 6 else { throw ToolError("Could not read note \(id)") }
    var d: [String: Any] = ["id": id, "title": f[0], "folder": f[1], "modified": dateFromOffset(f[2])]
    if f[3] == "true" { d["locked"] = true; return d }
    let content = html ? f[5...].joined(separator: US) : f[4]
    d[html ? "html" : "text"] = String(content.prefix(maxChars))
    if content.count > maxChars { d["truncated"] = true }
    return d
}

let notesTools: [Tool] = [
    Tool(app: "notes", name: "notes_folders",
         description: "List Notes accounts and folders with note counts.",
         properties: [:], required: [], kind: .read) { _ in
        records(try appleScript(asNotesFolders)).filter { $0.count >= 3 }
            .map { ["account": $0[0], "folder": $0[1], "notes": Int($0[2]) ?? 0] as [String: Any] }
    },

    Tool(app: "notes", name: "notes_search",
         description: "Search notes by title/text, or list most recently edited if no query. Returns ids; use notes_read for content.",
         properties: [
            "query": prop("string"), "folder": prop("string"), "account": prop("string"),
            "limit": prop("integer", "default 20"),
         ], required: [], kind: .read) { a in
        let limit = a.int("limit") ?? 20
        let out = try appleScript(asNotesSearch + asHelpers,
                                  [a.str("query") ?? "", a.str("folder") ?? "", a.str("account") ?? ""], timeout: 240)
        let sections = out.components(separatedBy: "\u{1D}")
        var folderOf: [String: String] = [:]
        if sections.count > 1 {
            for m in records(sections[1]) where m.count >= 2 { folderOf[m[0]] = m[1] }
        }
        var rows: [(Double, [String: Any])] = []
        var seen = Set<String>()
        for f in records(sections[0]) where f.count >= 5 {
            if seen.contains(f[0]) { continue }
            seen.insert(f[0])
            let folder = folderOf[f[0]] ?? a.str("folder")
            // A note in no listed folder is in Recently Deleted: skip it.
            guard let fld = folder, fld != "Recently Deleted", fld != "Nyligen raderade" else { continue }
            var d: [String: Any] = ["id": f[0], "title": f[1], "folder": fld, "modified": dateFromOffset(f[3])]
            if f[4] == "true" { d["locked"] = true }
            rows.append((Double(f[3]) ?? 0, d))
        }
        rows.sort { $0.0 > $1.0 }
        return rows.prefix(limit).map { $0.1 }
    },

    Tool(app: "notes", name: "notes_read",
         description: "Read a note's full text (or HTML).",
         properties: ["id": prop("string"), "html": prop("boolean"), "max_chars": prop("integer", "default 20000")],
         required: ["id"], kind: .read) { a in
        try readNote(try a.req("id"), html: a.bool("html") == true, maxChars: a.int("max_chars") ?? 20000)
    },

    Tool(app: "notes", name: "notes_create",
         description: "Create a note. body is plain text unless format=html.",
         properties: [
            "title": prop("string"), "body": prop("string"),
            "format": prop("string", "text (default) or html"),
            "folder": prop("string", "default folder if omitted"), "account": prop("string"),
         ], required: ["title"], kind: .write) { a in
        let title = try a.req("title")
        let html = titleHTML(title) + notesHTML(a.str("body") ?? "", format: a.str("format"))
        let f = try appleScript(asNotesCreate + asNotesFolderRef + asHelpers,
                                [html, a.str("folder") ?? "", a.str("account") ?? ""]).components(separatedBy: US)
        audit("notes_create", "\(title) | folder \(a.str("folder") ?? "default")")
        return ["id": f.first ?? "", "title": f.count > 1 ? f[1] : title] as [String: Any]
    },

    Tool(app: "notes", name: "notes_update",
         description: "Edit a note: mode append (default) adds to the end; replace rewrites the body (keeps title unless title given).",
         properties: [
            "id": prop("string"), "body": prop("string"),
            "mode": prop("string", "append (default) or replace"),
            "title": prop("string", "new title (replace mode)"),
            "format": prop("string", "text (default) or html"),
         ], required: ["id", "body"], kind: .write) { a in
        let id = try a.req("id")
        let mode = a.str("mode") == "replace" ? "replace" : "append"
        var html = notesHTML(try a.req("body"), format: a.str("format"))
        if mode == "replace" {
            let title = try a.str("title") ?? ((readNote(id, html: false, maxChars: 1)["title"] as? String) ?? "")
            html = titleHTML(title) + html
        }
        let f = try appleScript(asNotesUpdate + asHelpers, [id, html, mode]).components(separatedBy: US)
        audit("notes_update", "\(mode) | \(f.count > 1 ? f[1] : id)")
        return ["id": id, "title": f.count > 1 ? f[1] : "", "mode": mode] as [String: Any]
    },

    Tool(app: "notes", name: "notes_move",
         description: "Move a note to another folder.",
         properties: ["id": prop("string"), "folder": prop("string"), "account": prop("string")],
         required: ["id", "folder"], kind: .write) { a in
        let f = try appleScript(asNotesMove + asNotesFolderRef + asHelpers,
                                [try a.req("id"), try a.req("folder"), a.str("account") ?? ""]).components(separatedBy: US)
        audit("notes_move", f.joined(separator: " -> "))
        return ["moved": f.first ?? "", "folder": f.count > 1 ? f[1] : ""]
    },

    Tool(app: "notes", name: "notes_create_folder",
         description: "Create a Notes folder.",
         properties: ["name": prop("string"), "account": prop("string")],
         required: ["name"], kind: .write) { a in
        let f = try appleScript(asNotesNewFolder, [try a.req("name"), a.str("account") ?? ""]).components(separatedBy: US)
        audit("notes_create_folder", f.joined(separator: " | "))
        return ["folder": f.first ?? "", "account": f.count > 1 ? f[1] : ""]
    },

    Tool(app: "notes", name: "notes_delete",
         description: "Delete a note (goes to Recently Deleted, restorable for 30 days).",
         properties: ["id": prop("string")],
         required: ["id"], kind: .destructive) { a in
        let name = try appleScript(asNotesDelete + asHelpers, [try a.req("id")])
        audit("notes_delete", name)
        return ["deleted": name, "note": "Restorable from Recently Deleted for 30 days."]
    },
]
