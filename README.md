# EventKit MCP Server

A Swift-based [Model Context Protocol (MCP)](https://modelcontextprotocol.io) server that exposes Apple Reminders via the EventKit framework. Built using the [official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk).

## Overview

This MCP server allows AI assistants to interact with Apple Reminders, enabling them to:

- List, create, update, and delete reminders
- Manage reminder lists (calendars)
- Search reminders by content
- Filter reminders (overdue, today, upcoming)
- Restrict access to specific lists for security

> **Scope:** Reminders only. Calendar events are not currently supported, despite EventKit covering both.

## Requirements

- macOS 14.0 or later
- Swift 6.2 or later for development
- Xcode 26 or later for development

## Installation

### Using Homebrew (Recommended)

The easiest way to install EventKit MCP Server is via Homebrew:

```bash
brew install k3KAW8Pnf7mkmdSMPHz27/mcp/eventkit-mcp-server
```

This taps [`k3KAW8Pnf7mkmdSMPHz27/homebrew-mcp`](https://github.com/k3KAW8Pnf7mkmdSMPHz27/homebrew-mcp) automatically and builds from source on your machine (no prebuilt binaries are distributed).

### Building from Source

```bash
# Clone the repository
git clone https://github.com/k3KAW8Pnf7mkmdSMPHz27/EventKitMCP.git
cd EventKitMCP

# Build the project
swift build -c release

# The executable will be at .build/release/eventkit-mcp-server
```

### Running the Server

```bash
# Run directly
swift run eventkit-mcp-server

# Or run the built executable
.build/release/eventkit-mcp-server

# Run in read-only mode (no create/update/delete)
.build/release/eventkit-mcp-server --read-only

# Restrict to specific reminder lists only
.build/release/eventkit-mcp-server --allowed-lists "list-id-1,list-id-2"
```

## Configuration

### Claude Desktop

Add this to your Claude Desktop configuration file (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "eventkit": {
      "command": "/opt/homebrew/bin/eventkit-mcp-server"
    }
  }
}
```

With list restrictions:

```json
{
  "mcpServers": {
    "eventkit": {
      "command": "/opt/homebrew/bin/eventkit-mcp-server",
      "args": ["--allowed-lists", "list-id-1,list-id-2"]
    }
  }
}
```

### Permissions

The server requires access to Reminders. On first run, macOS will prompt you to grant permission. You can also grant access manually in:

**System Settings → Privacy & Security → Reminders**

EventKit grants reminder access to the server process. If the prompt was dismissed or
denied, enable the terminal or host application that launches the server, then restart it.
Location alarms can include precise coordinates and are returned only through this
already-authorized Reminders tool surface.

## Available Tools

| Tool | Description |
|------|-------------|
| `query_reminders` | Query reminders by list, filter (all/overdue/today/upcoming), and regex search; supplied constraints are combined and results are paginated |
| `write_reminders` | Create, update, or delete reminders. Uses `upsert` array (no id = create, with id = update) and `delete` array for IDs to remove |
| `get_reminder_lists` | Get all reminder lists |
| `manage_reminder_list` | Create or delete reminder lists (action='create' with title and optional hex color, or action='delete' with id) |
| `overview` | Get a concise dashboard: date/timezone, counts, lists, overdue/today/upcoming reminders; the structured output carries the same sections |

## Tool Examples

### Query Reminders

```json
// Get all reminders
{ "name": "query_reminders", "arguments": {} }

// Get overdue reminders
{ "name": "query_reminders", "arguments": { "filter": "overdue" } }

// Get upcoming reminders (next 14 days)
{ "name": "query_reminders", "arguments": { "filter": "upcoming", "days": 14 } }

// Retrieve up to 25 reminders by default; request subsequent pages with offset
{ "name": "query_reminders", "arguments": { "limit": 25, "offset": 25 } }

// Search by regex
{ "name": "query_reminders", "arguments": { "search": "grocery|shopping" } }

// Search within overdue reminders in one list
{
  "name": "query_reminders",
  "arguments": {
    "listId": "list-id",
    "filter": "overdue",
    "search": "invoice|renewal"
  }
}

// Match one or more IDs with the regex search field
{ "name": "query_reminders", "arguments": { "search": "id1|id2" } }
```

Query responses include `count`, `totalCount`, `offset`, and `hasMore` so clients can
continue without placing the entire reminders database in one model context.

`filter` defaults to `all`, and `days` sets the `upcoming` window: 1 through 3650,
default 7. Completed reminders are left out unless `includeDone` is `true`. `limit`
takes 1 through 100 and defaults to 25; `offset` defaults to 0.

### Write Reminders (Create/Update/Delete)

```json
// Create a new reminder (no id in upsert item)
{
  "name": "write_reminders",
  "arguments": {
    "upsert": [{
      "title": "Buy groceries",
      "notes": "Milk, eggs, bread",
      "dueDate": "2024-12-25T10:00:00Z",
      "priority": "high"
    }]
  }
}

// Update existing reminder (include id in upsert item)
{
  "name": "write_reminders",
  "arguments": {
    "upsert": [{
      "id": "reminder-id",
      "done": true
    }]
  }
}

// Delete reminders
{
  "name": "write_reminders",
  "arguments": {
    "delete": ["reminder-id-1", "reminder-id-2"]
  }
}

// Mixed operations in single call
{
  "name": "write_reminders",
  "arguments": {
    "upsert": [
      { "title": "New task" },
      { "id": "existing-id", "done": true }
    ],
    "delete": ["old-task-id"]
  }
}
```

One call carries at most 100 operations, counting `upsert` and `delete` together.

### Supported reminder fields

The write and query tools preserve titles, notes, completion state, priority, list,
due date, start date, IANA time zones, all-day flags, URL,
RFC 5545 recurrence, and relative, absolute, or geofence alarms.

Dates are ISO 8601: with an offset (`2026-01-06T10:00:00-06:00`), as wall-clock time
(`2026-01-06T10:00:00`), or date-only for an all-day reminder (`2026-01-06`).
`dueTimeZone` and `startTimeZone` anchor the wall-clock and date-only forms; without
one, the date floats in the Mac's local time. A time-zone key is read only together with
its date. EventKit keeps one time zone and one all-day form per reminder, so when the due
and start dates disagree, the start date's apply to both. Reminders also gives a timed due
date a matching start date, and a start date with no due date loses its time zone.

Marking a recurring reminder done, on create or update, works as in Reminders.app: the
current occurrence becomes a separate done reminder, and the reminder moves to its next
occurrence.

Updates use three-state patch semantics for nullable fields: omit a property to leave
it unchanged, send JSON `null` to clear it, or send a value to replace it. This applies
to `notes`, `dueDate`, `url`, `startDate`, `recurrence`, and `alarms`.
URLs must include a scheme, and time zones must be valid IANA identifiers such as
`America/Chicago`. Integer parameters (`days`, `limit`, `offset`, `minutesBefore`) take
JSON integers, so `15.5` is rejected; coordinates and `radius` take any number.

Alarms use one of these tagged object shapes:

```json
{ "kind": "relative", "minutesBefore": 15 }
{ "kind": "absolute", "absoluteDate": "2026-09-03T17:00:00Z" }
{
  "kind": "location",
  "proximity": "enter",
  "title": "Office",
  "latitude": 41.8781,
  "longitude": -87.6298,
  "radius": 100
}
```

An `absoluteDate` without an offset is read in `startTimeZone`, else `dueTimeZone`, else
the Mac's local time. Relative alarms count back from the due date, so they need one.

A location alarm is what Reminders.app shows as a reminder's location. Reminders keeps no
separate location text, so there is no `location` field.

### Manage Lists

```json
// Create a list, optionally with a hex color
{ "name": "manage_reminder_list", "arguments": { "action": "create", "title": "Work", "color": "#FF5733" } }

// Delete a list
{ "name": "manage_reminder_list", "arguments": { "action": "delete", "id": "list-id" } }
```

## Command-Line Options

| Flag | Description |
|------|-------------|
| `--verbose`, `-v` | Enable verbose logging |
| `--log-to-stderr` | Send logs to stderr (default: suppressed for MCP) |
| `--read-only` | Disable all mutating operations |
| `--allowed-lists <ids>` | Comma-separated list IDs to restrict access to |
| `--version` | Print the version and exit |

With `--allowed-lists`, a reminder in any other list looks exactly like a missing one, and creating a
reminder without `listId` fails unless the default list is one of the allowed lists. The server
refuses to start when none of the IDs match an existing list.

## Development

The supported development baseline is Xcode 26 with Swift 6.2 or newer. The runtime
deployment target remains macOS 14. Dependencies are pinned in `Package.resolved`.
Debug builds treat warnings as errors; release builds only report them. CI runs the
two lints, `swift build -c release` and `swift test`, nothing else. SwiftLint is
pinned in CI (`brew install swiftlint` locally); `swift format` ships with Xcode.

```bash
swift build              # Build (warnings are errors)
swift test               # Run tests (what CI runs)
swift build -c release   # Build release (what CI and Homebrew run)

swift format format --in-place --recursive --parallel Sources Tests Package.swift
swift format lint --strict --recursive --parallel Sources Tests Package.swift
swiftlint lint --strict  # size and complexity ceilings; lower them when a maximum shrinks

# Interactive debugging with MCP Inspector
npx @modelcontextprotocol/inspector .build/debug/eventkit-mcp-server

# Verify the read-only surface (query, lists, and overview only)
npx @modelcontextprotocol/inspector .build/debug/eventkit-mcp-server --read-only
```

### Releases

Every merge to `main` is squashed, so the PR title becomes the commit subject, and
titles must be [conventional commits](https://www.conventionalcommits.org/). When CI
passes on `main`, [semantic-release](https://semantic-release.org) tags a new version
from the commits since the last tag and publishes a GitHub Release with generated notes:

| Title | Release |
|---|---|
| `feat: ...` | minor |
| `fix: ...`, `perf: ...`, `revert: ...` | patch |
| `feat!: ...`, or a `BREAKING CHANGE:` footer | major |
| `docs:`, `ci:`, `chore:`, `refactor:`, `test:`, ... | none |

The version string in the source is a placeholder; Homebrew builds write the tag's
version into it.

## License

See [LICENSE](LICENSE) for details.
