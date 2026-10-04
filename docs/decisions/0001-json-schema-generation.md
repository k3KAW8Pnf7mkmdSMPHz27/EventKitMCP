# 1. Generate tool input schemas with swift-json-schema

Status: Accepted. Implemented in July 2026, recorded October 2026.

## Context

Every MCP tool advertises a JSON Schema for its input. Building those schemas by hand
as `Value` literals took about 325 lines for five tools.

## Decision

Each tool's input is a `@Schemable` struct in `ToolInputSchemas.swift`, and
[swift-json-schema](https://github.com/ajevans99/swift-json-schema) generates its schema.
The server stays on the official MCP Swift SDK.

Rejected alternatives:

- **SwiftMCP.** It cuts the most code but replaces the official SDK.
- **gsabran/mcp-swift-sdk.** It is a fork of the SDK that bundles the same schema library.
- **Decoding inputs through the generated schema.** Error text would come from a pre-1.0
  dependency that changes weekly, and `Decodable` cannot tell an absent field from `null`.

## Consequences

- The structs only generate schemas. Handlers still parse the raw arguments, so a field
  is declared in both places.
- Enumerated inputs are enforced by the advertised schema, not at run time.
- swift-json-schema is pinned with `upToNextMinor` because it is pre-1.0.
- `Tests/EventKitMCPTests/Contract/tool-contract.json` snapshots the generated schemas.
  A dependency bump that changes what clients see fails that test.
