// mac-apps-mcp — one MCP server for Calendar, Reminders, Contacts, Mail, Notes, Shortcuts and notifications.
//
//   mac-apps-mcp                      run as an MCP server (stdin/stdout), all apps
//   mac-apps-mcp --apps mail,notes    only expose some apps
//   mac-apps-mcp --test               quick check from Terminal
//
// Transport: JSON-RPC 2.0, one message per line on stdin/stdout. No network, no ports.

import Foundation

let allApps = ["calendar", "reminders", "contacts", "mail", "notes", "shortcuts", "notify"]

func enabledApps() -> Set<String> {
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--apps"), i + 1 < args.count {
        return Set(args[i + 1].lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
    }
    return Set(allApps)
}

let apps = enabledApps()
let tools: [Tool] = (calendarTools + reminderTools + contactTools + mailTools + notesTools + shortcutTools + notifyTools)
    .filter { apps.contains($0.app) }
let toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })

func callTool(_ name: String, _ args: [String: Any]) -> [String: Any] {
    guard let tool = toolsByName[name] else {
        return ["content": [["type": "text", "text": "Unknown tool: \(name)"]], "isError": true]
    }
    do {
        let result = try tool.handler(Args(d: args))
        return ["content": [["type": "text", "text": toJSON(result)]]]
    } catch {
        return ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
    }
}

// MARK: - Terminal test

if CommandLine.arguments.contains("--test") {
    print("mac-apps-mcp: \(tools.count) tools for \(apps.sorted().joined(separator: ", "))\n")
    let checks: [(String, String, [String: Any])] = [
        ("calendar", "calendar_list", [:]),
        ("reminders", "reminders_lists", [:]),
        ("contacts", "contacts_search", ["query": "a", "limit": 1]),
        ("mail", "mail_mailboxes", [:]),
        ("notes", "notes_folders", [:]),
        ("shortcuts", "shortcuts_list", [:]),
    ]
    for (app, tool, args) in checks where apps.contains(app) {
        let r = callTool(tool, args)
        let text = ((r["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        let ok = (r["isError"] as? Bool) != true
        print("\(ok ? "OK  " : "FAIL") \(app): \(String(text.prefix(300)))\n")
    }
    exit(0)
}

// MARK: - MCP loop

func send(_ obj: [String: Any]) {
    guard let d = try? JSONSerialization.data(withJSONObject: obj) else { return }
    FileHandle.standardOutput.write(d)
    FileHandle.standardOutput.write("\n".data(using: .utf8)!)
}

logErr("mac-apps-mcp started with \(tools.count) tools")

while let line = readLine(strippingNewline: true) {
    guard let data = line.data(using: .utf8),
          let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { continue }
    guard let id = msg["id"] else { continue }   // notifications need no reply
    let method = msg["method"] as? String ?? ""
    let params = msg["params"] as? [String: Any] ?? [:]
    var reply: [String: Any] = ["jsonrpc": "2.0", "id": id]
    switch method {
    case "initialize":
        reply["result"] = [
            "protocolVersion": (params["protocolVersion"] as? String) ?? "2025-06-18",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "mac-apps", "version": "1.0.0"],
        ] as [String: Any]
    case "ping":
        reply["result"] = [String: Any]()
    case "tools/list":
        reply["result"] = ["tools": tools.map { $0.definition }]
    case "tools/call":
        reply["result"] = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
    default:
        reply["error"] = ["code": -32601, "message": "Method not found: \(method)"] as [String: Any]
    }
    send(reply)
}
