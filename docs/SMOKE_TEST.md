# Smoke test

Last run: never, against this checklist.

These steps need a real Reminders database, so no test or CI job can run them. Run them
before merging a change to the write path, the allowlist or the release build, and
before a major release. Use a scratch list; step 5 creates and deletes reminders.

1. **Release build.** `swift build -c release`, then run
   `.build/release/eventkit-mcp-server --version`. A local build prints `0.0.0-dev`.
2. **Permission.** On a machine or user without Reminders access, the first tool call
   shows the macOS prompt. Denying it makes every tool fail with an access error.
3. **Tool surface.** In the MCP Inspector, the server lists 5 tools, and 3 with
   `--read-only`. *CI covers both counts through the in-memory server tests.*
4. **Allowlist.** Start with `--allowed-lists "<real id>,stale-id"`. The server warns
   about `stale-id`, starts, and lists only the real list. If the default list is not
   the real one, creating a reminder without `listId` fails with "The default reminder
   list is outside --allowed-lists; pass listId". With only `stale-id`, it refuses to
   start.
5. **Round trip.** Create a reminder with every field: notes, due date with a time zone,
   start date, priority, URL, location, RFC 5545 recurrence, `done: true`, and one alarm
   of each kind.
   Check it in Reminders.app, update each field, clear each with `null`, then delete it.
   *CI covers each EventKit call against unsaved objects. Only the save to the real
   database is checked here.*
6. **Due and start zones.** Create a reminder whose due date is in `Asia/Tokyo` and whose
   start date is in `Europe/Paris`. Unsaved objects show the due date moving to Paris
   with the instant kept. Confirm Reminders.app shows the same.
7. **Completion date.** Mark a reminder done, wait a few seconds, and mark it done again.
   The completion date in Reminders.app must not move. EventKit restamps it on every
   `isCompleted = true`, so the server writes the flag only when it changes. *CI covers
   this against unsaved objects.*
8. **Coloured list.** Create a list with `color: "#FF5733"` and check its colour and
   source in Reminders.app, then delete it.
9. **Overview.** The overview header names the Mac's time zone and today's weekday.
10. **Claude Desktop.** Restart Claude Desktop with the server configured and run one
   query from a chat.

Record the date, the macOS version and the server version in "Last run" above.
