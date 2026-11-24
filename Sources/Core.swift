// Core.swift — shared helpers: tool model, argument parsing, dates, JSON,
// audit log, and running AppleScript / command-line programs safely.

import Foundation

// MARK: - Errors

struct ToolError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Tool model

enum Kind { case read, write, destructive }

struct Tool {
    let app: String            // calendar, reminders, contacts, mail, notes, shortcuts
    let name: String
    let description: String
    let properties: [String: Any]
    let required: [String]
    let kind: Kind
    let handler: (Args) throws -> Any

    var definition: [String: Any] {
        var annotations: [String: Any] = ["openWorldHint": false]
        switch kind {
        case .read:
            annotations["readOnlyHint"] = true
        case .write:
            annotations["readOnlyHint"] = false
            annotations["destructiveHint"] = false
        case .destructive:
            annotations["readOnlyHint"] = false
            annotations["destructiveHint"] = true
        }
        return [
            "name": name,
            "description": description,
            "inputSchema": ["type": "object", "properties": properties, "required": required],
            "annotations": annotations,
        ]
    }
}

/// Small helpers for building JSON schemas.
func prop(_ type: String, _ desc: String? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": type]
    if let d = desc { p["description"] = d }
    return p
}

func listProp(_ desc: String? = nil) -> [String: Any] {
    var p: [String: Any] = ["type": "array", "items": ["type": "string"]]
    if let d = desc { p["description"] = d }
    return p
}

// MARK: - Arguments

struct Args {
    let d: [String: Any]

    func str(_ k: String) -> String? {
        guard let s = d[k] as? String, !s.isEmpty else { return nil }
        return s
    }

    func req(_ k: String) throws -> String {
        guard let v = str(k) else { throw ToolError("Missing required argument: \(k)") }
        return v
    }

    func int(_ k: String) -> Int? {
        if let n = d[k] as? NSNumber { return n.intValue }
        if let s = d[k] as? String { return Int(s) }
        return nil
    }

    func bool(_ k: String) -> Bool? {
        if let n = d[k] as? NSNumber { return n.boolValue }
        if let s = d[k] as? String { return s.lowercased() == "true" }
        return nil
    }

    func list(_ k: String) -> [String] {
        if let a = d[k] as? [Any] {
            return a.compactMap { $0 as? String }.filter { !$0.isEmpty }
        }
        if let s = str(k) {
            return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return []
    }

    func date(_ k: String) throws -> Date? {
        guard let s = str(k) else { return nil }
        guard let dt = parseDate(s) else { throw ToolError("Invalid date for \(k): \(s). Use YYYY-MM-DD or YYYY-MM-DDTHH:mm") }
        return dt
    }

    func has(_ k: String) -> Bool { d[k] != nil && !(d[k] is NSNull) }
}

// MARK: - Dates

let outFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f
}()

let dayFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func parseDate(_ s: String) -> Date? {
    if let d = ISO8601DateFormatter().date(from: s) { return d }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    for p in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
        f.dateFormat = p
        if let d = f.date(from: s) { return d }
    }
    return nil
}

/// True when the string is a plain date without a time (YYYY-MM-DD).
func isDateOnly(_ s: String?) -> Bool {
    guard let s = s else { return false }
    return s.count == 10 && !s.contains("T") && !s.contains(" ")
}

// MARK: - JSON

func toJSON(_ obj: Any) -> String {
    guard JSONSerialization.isValidJSONObject(obj),
          let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
          let s = String(data: d, encoding: .utf8) else { return "\(obj)" }
    return s
}

// MARK: - Logging

func logErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let auditURL: URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/mac-apps-mcp.log")

/// Appends one line per write action. Reads are never logged.
func audit(_ tool: String, _ detail: String) {
    let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(tool)\t\(detail.replacingOccurrences(of: "\n", with: " "))\n"
    guard let data = line.data(using: .utf8) else { return }
    if let h = try? FileHandle(forWritingTo: auditURL) {
        h.seekToEndOfFile()
        h.write(data)
        try? h.close()
    } else {
        try? data.write(to: auditURL)
    }
}

// MARK: - Running programs

/// Runs a program with arguments (no shell), returns stdout. Throws on non-zero exit or timeout.
func runProcess(_ path: String, _ args: [String], timeout: TimeInterval = 90) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()

    var outData = Data(), errData = Data()
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
    group.enter()
    DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }

    if group.wait(timeout: .now() + timeout) == .timedOut {
        p.terminate()
        throw ToolError("Timed out after \(Int(timeout)) seconds")
    }
    p.waitUntilExit()
    if p.terminationStatus != 0 {
        let msg = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw ToolError(msg.isEmpty ? "Exited with status \(p.terminationStatus)" : msg)
    }
    var s = String(data: outData, encoding: .utf8) ?? ""
    while s.hasSuffix("\n") { s.removeLast() }
    return s
}

/// Field and record separators used to pass structured text out of AppleScript.
let US = "\u{1F}"
let RS = "\u{1E}"

/// Runs an AppleScript. User-supplied values are passed as `argv` items to `on run argv`,
/// never pasted into the script text, so they can't inject AppleScript code.
func appleScript(_ source: String, _ args: [String] = [], timeout: TimeInterval = 120) throws -> String {
    do {
        return try runProcess("/usr/bin/osascript", ["-e", source] + args, timeout: timeout)
    } catch let e as ToolError {
        var m = e.message
        if m.contains("-1743") || m.lowercased().contains("not authorized") {
            m += " — Allow Claude to control this app in System Settings > Privacy & Security > Automation."
        }
        throw ToolError("AppleScript: " + m)
    }
}

/// Splits AppleScript output into records (RS) of fields (US).
func records(_ s: String) -> [[String]] {
    s.components(separatedBy: RS)
        .filter { !$0.isEmpty }
        .map { $0.components(separatedBy: US) }
}

/// AppleScript returns dates as "seconds relative to now" (locale-independent); convert back.
func dateFromOffset(_ s: String) -> String {
    guard let secs = Double(s.trimmingCharacters(in: .whitespaces)) else { return "" }
    return outFmt.string(from: Date().addingTimeInterval(secs))
}

/// Shared AppleScript handlers appended to scripts that need them.
let asHelpers = """

on txt(x)
    if x is missing value then return ""
    return x as text
end txt

on splitText(t, d)
    if t is "" then return {}
    set oldTID to AppleScript's text item delimiters
    set AppleScript's text item delimiters to d
    set parts to text items of t
    set AppleScript's text item delimiters to oldTID
    return parts
end splitText

on findMsg(accName, mbName, mid)
    tell application "Mail"
        tell account accName to set mb to first mailbox whose name is mbName
        tell mb to return first message whose id is mid
    end tell
end findMsg
"""
