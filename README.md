# mac-apps-mcp

**Let Claude use Calendar, Reminders, Contacts, Mail, Notes, Shortcuts and notifications on your Mac through Apple's own APIs instead of clicking around the screen.**

## Why

Claude's *computer use* works through the GUI: it takes a screenshot, works out where to click, clicks, takes another screenshot, and repeats. Every screenshot is a large image in the context window, and even a simple task ("what's on my calendar Thursday?", "draft a reply to this email") can take many rounds. That's slow, costs a lot of tokens, and breaks when a window looks different.

This MCP server skips the screen entirely. Claude calls a tool such as `calendar_get_events` and gets back a short JSON answer. It talks to the apps through official macOS interfaces:

| App | Interface |
|---|---|
| Calendar, Reminders | **EventKit**, Apple's calendar and reminders framework (the same data Calendar.app shows, including subscribed and Exchange calendars) |
| Contacts | **Contacts framework** |
| Mail, Notes, Messages | **AppleScript**, the apps' official scripting interface |
| Shortcuts | the `shortcuts` command-line tool |

The result: one tool call and a few hundred tokens instead of a chain of screenshots. It's also more reliable, because nothing depends on window positions, and it works while the apps are in the background.

## What Claude can do with it

- **Calendar:** list calendars, read events (recurring events expanded), find free time slots, create events, edit your own events
- **Reminders:** read lists and reminders, create reminders with due dates and alerts, edit them, mark them done
- **Contacts:** search by name, email or phone; create contacts (with a duplicate check); add emails and phone numbers
- **Mail** (every account in Mail.app, e.g. iCloud and Exchange): list mailboxes, search, read messages, create drafts (new, reply, forward, with attachments), send a draft in two steps, mark read or flagged, move or archive, move to Trash, save attachments
- **Notes:** list folders, search, read, create, append or replace, move, create folders, delete (into Recently Deleted)
- **Shortcuts:** list and run your Shortcuts
- **Notifications:** a Mac banner; an iPhone/Watch alert through a "Claude alerts" reminder list; an iMessage to yourself

## Built-in safety

- **No deleting** calendar events, reminders or contacts. The code simply doesn't contain those calls.
- **Two-step sending:** `mail_send_draft` only sends a draft that `mail_create_draft` made, and only if the subject and recipients match. Pair it with an "always ask" permission in Claude so you approve every send.
- **Trash is never emptied.** Deleted notes go to Recently Deleted (restorable for 30 days).
- **Notifications only reach you:** iMessage goes only to the handle you set in your own config.
- **Logging:** every change is written to `~/Library/Logs/mac-apps-mcp.log`.
- **Destructive tools are marked as such** (`mail_send_draft`, `mail_trash`, `notes_delete`, `shortcuts_run`), so clients ask before running them.
- **Local only:** the server talks to Claude over stdin/stdout. There's no network, no open ports, and no third-party dependencies.

## Install

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/sinatooor/mac-apps-mcp.git
cd mac-apps-mcp
./build.sh
./mac-apps-mcp --test     # optional: checks each app (permission prompts here are for Terminal)
```

Add it to the Claude desktop app: Settings → Developer → **Edit Config**.

```json
{
  "mcpServers": {
    "mac-apps": {
      "command": "/Users/YOU/path/to/mac-apps-mcp/mac-apps-mcp",
      "args": ["--self-handle", "+46XXXXXXXXX"]
    }
  }
}
```

- `--self-handle` is your own phone number or Apple ID, used for iMessage notifications. It's optional.
- `--apps calendar,reminders,mail` exposes only some apps. It's also optional.

Quit Claude (Cmd+Q) and reopen it. The first time each app is used, macOS asks once for permission: Calendars, Reminders and Contacts, plus Automation for Mail, Notes and Messages.

## Tools (30)

| App | Tools |
|---|---|
| Calendar | `calendar_list`, `calendar_get_events`, `calendar_free_slots`, `calendar_create_event`, `calendar_update_event` |
| Reminders | `reminders_lists`, `reminders_get`, `reminders_create`, `reminders_update` |
| Contacts | `contacts_search`, `contacts_create`, `contacts_update` |
| Mail | `mail_mailboxes`, `mail_search`, `mail_read`, `mail_create_draft`, `mail_send_draft`, `mail_set_status`, `mail_move`, `mail_trash`, `mail_save_attachments` |
| Notes | `notes_folders`, `notes_search`, `notes_read`, `notes_create`, `notes_update`, `notes_move`, `notes_create_folder`, `notes_delete` |
| Shortcuts | `shortcuts_list`, `shortcuts_run` |
| Notify | `notify` |

## Limits

- **Mail searches** default to each account's inbox and the last 7 days (max 90 days), so large mailboxes stay fast.
- **Forwarding** doesn't carry the original attachments; save them with `mail_save_attachments` and attach them again.
- **Notes:** locked notes can't be read, and images inside notes aren't returned.
- **Mac banners** don't reach the iPhone; use `phone: true`, which creates a synced reminder.
- **After a rebuild**, macOS may ask for permissions again.

## License

MIT
