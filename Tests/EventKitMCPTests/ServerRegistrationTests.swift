import MCP
import Testing
@testable import EventKitMCP

@MainActor
@Suite("Server registration tests")
struct ServerRegistrationTests {
    @Test("A read-only server lists only read-only tools and refuses writes")
    func readOnlyServer() async throws {
        let (client, server) = try await connect(readOnly: true)

        let tools = try await client.listTools().tools
        #expect(Set(tools.map(\.name)) == ["query_reminders", "get_reminder_lists", "overview"])

        let result = try await client.callTool(
            name: "write_reminders",
            arguments: ["delete": .array([.string("r1")])]
        )
        #expect(result.isError == true)
        guard case .text(let text, _, _)? = result.content.first else {
            Issue.record("Expected text content")
            return
        }
        #expect(text.contains("not allowed in read-only mode"))

        await client.disconnect()
        await server.stop()
    }

    @Test("A default server lists every tool")
    func defaultServer() async throws {
        let (client, server) = try await connect(readOnly: false)

        let tools = try await client.listTools().tools
        #expect(Set(tools.map(\.name)) == Set(ToolRegistry.allTools().map(\.name)))
        #expect(tools.count == 5)

        await client.disconnect()
        await server.stop()
    }

    private func connect(readOnly: Bool) async throws -> (Client, Server) {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = Server(
            name: "eventkit-mcp-server",
            version: "test",
            capabilities: .init(tools: .init(listChanged: false))
        )
        await ToolRegistry.registerHandlers(
            server: server,
            reminderService: MockReminderService(),
            logger: testLogger,
            readOnly: readOnly
        )
        try await server.start(transport: serverTransport)

        let client = Client(name: "registration-test", version: "1.0")
        try await client.connect(transport: clientTransport)
        return (client, server)
    }
}
