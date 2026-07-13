# Third-Party Library Evaluation for EventKitMCP

> **Status: IMPLEMENTED** - Option 3 (swift-json-schema with @Schemable) was implemented.
> See `Sources/EventKitMCP/Tools/ToolInputSchemas.swift` for the implementation.

This document evaluates options to reduce custom code by adopting third-party libraries.

## Current State

The project uses 3 official dependencies:
- `swift-sdk` (MCP Swift SDK v0.7.1+) - Official MCP protocol implementation
- `swift-log` (v1.5.0+) - Apple's logging framework
- `swift-argument-parser` (v1.3.0+) - Apple's CLI argument parsing

### Custom Code That Could Be Replaced

| Area | Lines | Description |
|------|-------|-------------|
| Tool Schema Definitions | ~325 | Manual JSON Schema construction in `allTools()` |
| Value Type Extraction | ~22 | Extension methods for `Value` type |
| NoOp Log Handler | ~21 | Custom `SwiftLogNoOpLogHandler` |
| Date Formatting | ~15 | Multiple `DateFormatter` instances |
| Color Conversion | ~27 | Hex to/from CGColor |

**Total: ~410 lines** of custom code potentially reducible.

---

## Option 1: SwiftMCP (Recommended)

**Repository**: https://github.com/Cocoanetics/SwiftMCP

### Overview
SwiftMCP is a macro-based framework that uses `@MCPServer` and `@MCPTool` macros to automatically generate MCP tool definitions from Swift code and DocC comments.

### Benefits
- **Massive boilerplate reduction**: Eliminates ~325 lines of manual schema definitions
- **DocC integration**: Tool descriptions extracted from code comments
- **Type-safe**: Parameters auto-converted to proper Swift types
- **Stdio support**: Native support for stdio transport
- **Active development**: v1.0 released, 521 commits, BSD-2-Clause license

### Before (Current)
```swift
Tool(
    name: "create_reminder",
    description: "Create a new reminder",
    inputSchema: .object([
        "type": .string("object"),
        "properties": .object([
            "title": .object([
                "type": .string("string"),
                "description": .string("The title of the reminder")
            ]),
            // ... 30+ more lines per tool
        ]),
        "required": .array([.string("title")])
    ])
)
```

### After (With SwiftMCP)
```swift
@MCPServer
class EventKitServer {
    /// Create a new reminder
    /// - Parameters:
    ///   - title: The title of the reminder
    ///   - notes: Optional notes for the reminder
    ///   - dueDate: Optional due date in ISO 8601 format
    /// - Returns: The created reminder details
    @MCPTool
    func createReminder(title: String, notes: String? = nil, dueDate: String? = nil) async throws -> String {
        // Implementation
    }
}
```

### Trade-offs
- Replaces official MCP SDK with SwiftMCP's implementation
- Learning curve for macro-based approach
- Dependency on third-party project (though well-maintained)

### Estimated Reduction
**~400 lines removed**, replaced with ~50 lines of macro-annotated code.

---

## Option 2: gsabran/mcp-swift-sdk with @Schemable

**Repository**: https://github.com/gsabran/mcp-swift-sdk

### Overview
An alternative MCP SDK that includes `swift-json-schema` for automatic JSON Schema generation using the `@Schemable` macro.

### Benefits
- **Schema auto-generation**: `@Schemable` macro creates schemas from Swift structs
- **MCP-compatible**: Implements same protocol as official SDK
- **Less invasive**: Keeps similar architecture, just adds schema generation

### Example Usage
```swift
@Schemable
struct CreateReminderInput {
    /// The title of the reminder
    let title: String
    /// Optional notes for the reminder
    let notes: String?
    /// Optional due date in ISO 8601 format
    let dueDate: String?
}

// Schema generated automatically from struct
let tool = Tool(name: "create_reminder") { (input: CreateReminderInput) in
    // Implementation
}
```

### Trade-offs
- Switches from official SDK to community fork
- Still requires some manual tool registration
- Less mature than official SDK

### Estimated Reduction
**~200 lines removed** (schema definitions), tool handlers remain.

---

## Option 3: swift-json-schema Only

**Repository**: https://github.com/ajevans99/swift-json-schema

### Overview
Add only the schema generation library to the current stack, keeping the official MCP SDK.

### Benefits
- **Minimal change**: Keep official SDK, add schema generation
- **Targeted improvement**: Only addresses schema boilerplate
- **Well-documented**: Active project with good documentation

### Example Usage
```swift
import JSONSchemaBuilder

@Schemable
struct CreateReminderInput {
    let title: String
    @SchemaOptions(.description("Optional notes"))
    let notes: String?
}

// Use generated schema with official SDK
Tool(
    name: "create_reminder",
    description: "Create a new reminder",
    inputSchema: CreateReminderInput.schema.asValue() // Convert to MCP Value
)
```

### Trade-offs
- Requires bridging between JSONSchemaBuilder output and MCP's `Value` type
- Still need manual tool registration
- Hybrid approach may be awkward

### Estimated Reduction
**~150 lines removed** with some bridging code added.

---

## Option 4: Keep Current + Minor Improvements

### Changes
1. **Remove NoOp Logger**: Use `LoggingSystem.bootstrap { _ in SwiftLogNoOpLogHandler() }` or a simpler sink
2. **Consolidate DateFormatters**: Create a shared formatter utility
3. **Keep manual schemas**: They provide explicit control and documentation

### Benefits
- No new dependencies
- Maximum control and stability
- Official SDK support guaranteed

### Estimated Reduction
**~40 lines** through refactoring.

---

## Recommendation Matrix

| Option | Lines Saved | Complexity | Risk | Maintenance |
|--------|-------------|------------|------|-------------|
| SwiftMCP | ~400 | Medium | Low | Good (active) |
| gsabran/mcp-sdk | ~200 | Medium | Medium | Moderate |
| swift-json-schema | ~150 | Low | Low | Good |
| Minor Refactor | ~40 | Very Low | None | N/A |

---

## Final Recommendation

### Primary: SwiftMCP

For maximum code reduction, **SwiftMCP** is recommended. It would:
- Eliminate 325+ lines of schema definitions
- Provide better developer experience with macro-based tools
- Auto-extract documentation from DocC comments
- Maintain stdio transport compatibility

### Alternative: Current Stack + swift-json-schema

If staying with the official MCP SDK is preferred:
1. Add `swift-json-schema` dependency
2. Create `@Schemable` input structs for each tool
3. Build a small bridge to convert schemas to MCP `Value` types
4. Keep tool registration but with generated schemas

---

## Other Libraries Considered (Not Recommended)

| Library | Reason Not Recommended |
|---------|----------------------|
| SwiftDate | Foundation's date handling is sufficient |
| ColorKit/DynamicColor | 27 lines of color code doesn't justify a dependency |
| Any HTTP library | Not needed (stdio transport only) |

---

## Next Steps

1. **Choose approach**: SwiftMCP vs. current stack enhancement
2. **Proof of concept**: Migrate 1-2 tools to validate approach
3. **Full migration**: Update all 18 tools
4. **Test**: Ensure all functionality preserved
5. **Document**: Update README with new architecture

---

## References

- [SwiftMCP GitHub](https://github.com/Cocoanetics/SwiftMCP)
- [SwiftMCP Documentation](https://swiftpackageindex.com/Cocoanetics/SwiftMCP)
- [swift-json-schema GitHub](https://github.com/ajevans99/swift-json-schema)
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [gsabran/mcp-swift-sdk](https://github.com/gsabran/mcp-swift-sdk)
