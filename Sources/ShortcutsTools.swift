// ShortcutsTools.swift — list and run the user's Shortcuts via /usr/bin/shortcuts.
// Marked destructive because a Shortcut can do anything, so the Claude app asks before running one.

import Foundation

let shortcutTools: [Tool] = [
    Tool(app: "shortcuts", name: "shortcuts_list",
         description: "List the user's Shortcuts by name.",
         properties: [:], required: [], kind: .read) { _ in
        try runProcess("/usr/bin/shortcuts", ["list"]).components(separatedBy: "\n").filter { !$0.isEmpty }
    },

    Tool(app: "shortcuts", name: "shortcuts_run",
         description: "Run a Shortcut by exact name, with optional text input. Returns its text output.",
         properties: ["name": prop("string"), "input": prop("string", "text passed as Shortcut input")],
         required: ["name"], kind: .destructive) { a in
        let name = try a.req("name")
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("mac-apps-mcp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let outFile = tmp.appendingPathComponent("output.txt")
        var args = ["run", name, "--output-path", outFile.path, "--output-type", "public.plain-text"]
        if let input = a.str("input") {
            let inFile = tmp.appendingPathComponent("input.txt")
            try input.write(to: inFile, atomically: true, encoding: .utf8)
            args += ["--input-path", inFile.path]
        }
        _ = try runProcess("/usr/bin/shortcuts", args, timeout: 300)
        let output = (try? String(contentsOf: outFile, encoding: .utf8)) ?? ""
        audit("shortcuts_run", name)
        return ["ran": name, "output": String(output.prefix(8000))]
    },
]
