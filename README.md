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
| `query_reminders` | Query reminders by list, filter (all/overdue/today/upcoming), and regex search; supplied constraints are combined |
| `write_reminders` | Create, update, or delete reminders. Uses `upsert` array (no id = create, with id = update) and `delete` array for IDs to remove |
| `get_reminder_lists` | Get all reminder lists |
| `manage_reminder_list` | Create or delete reminder lists (action='create' with title, or action='delete' with id) |
| `overview` | Get a concise dashboard: date/timezone, counts, lists, overdue/today/upcoming reminders |

## Tool Examples

### Query Reminders

```json
// Get all reminders
{ "name": "query_reminders", "arguments": {} }

// Get overdue reminders
{ "name": "query_reminders", "arguments": { "filter": "overdue" } }

// Get upcoming reminders (next 14 days)
{ "name": "query_reminders", "arguments": { "filter": "upcoming", "days": 14 } }

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

### Supported reminder fields

The write and query tools preserve titles, notes, completion state, priority, list,
due date, start date, independent IANA time zones, all-day flags, location text, URL,
RFC 5545 recurrence, and relative, absolute, or geofence alarms.

Updates use three-state patch semantics for nullable fields: omit a property to leave
it unchanged, send JSON `null` to clear it, or send a value to replace it. This applies
to `notes`, `dueDate`, `location`, `url`, `startDate`, `recurrence`, and `alarms`.
URLs must include a scheme, and time zones must be valid IANA identifiers such as
`America/Chicago`.

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

### Manage Lists

```json
// Create a list
{ "name": "manage_reminder_list", "arguments": { "action": "create", "title": "Work" } }

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

## Development

The supported development baseline is Xcode 26 with Swift 6.2 or newer. The runtime
deployment target remains macOS 14. Dependencies are pinned in `Package.resolved`.

```bash
swift build              # Build
swift test               # Run tests
swift build -c release   # Build release

# Interactive debugging with MCP Inspector
npx @modelcontextprotocol/inspector .build/debug/eventkit-mcp-server

# Verify the read-only surface (query, lists, and overview only)
npx @modelcontextprotocol/inspector .build/debug/eventkit-mcp-server --read-only
```

## License

See [LICENSE](LICENSE) for details.
