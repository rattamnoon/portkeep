import Foundation
import Testing
@testable import TunnelKit

private final class Calls {
    var made: [(String, JSONValue)] = []
}

private func server(_ calls: Calls = Calls()) -> MCPServer {
    MCPServer(version: "0.4.0") { method, params throws(RPCError) in
        calls.made.append((method, params))
        switch method {
        case "tunnels.list": return .object(["tunnels": .array([.object(["name": .string("Web"), "state": .string("off")])])])
        case "tunnels.remove": throw RPCError(RPCError.notFound, "No tunnel named Nope.")
        default: return .object([:])
        }
    }
}

private func send(_ server: MCPServer, _ text: String) throws -> JSONValue {
    let line = try #require(server.handle(text))
    #expect(!line.contains("\n"), "one message per line")
    return try JSONDecoder().decode(JSONValue.self, from: Data(line.utf8))
}

@Test func initializeNegotiatesTheVersion() throws {
    let mcp = server()
    let reply = try send(mcp, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#)
    #expect(reply["jsonrpc"] == .string("2.0"))
    #expect(reply["id"] == .int(1))
    #expect(reply["result"]?["protocolVersion"] == .string("2025-06-18"))
    #expect(reply["result"]?["capabilities"]?["tools"] != nil)
    #expect(reply["result"]?["serverInfo"]?["name"] == .string("portkeep"))

    let older = try send(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#)
    #expect(older["result"]?["protocolVersion"] == .string("2024-11-05"))
    let future = try send(server(), #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
    #expect(future["result"]?["protocolVersion"] == .string(MCPServer.protocolVersions[0]))
}

@Test func notificationsGetNoReply() {
    #expect(server().handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
}

@Test func listsToolsWithSchemasAndHints() throws {
    let reply = try send(server(), #"{"jsonrpc":"2.0","id":"a","method":"tools/list"}"#)
    #expect(reply["id"] == .string("a"))
    let tools = try #require(reply["result"]?["tools"]?.arrayValue)
    let names = tools.compactMap { $0["name"]?.stringValue }
    for expected in ["list_tunnels", "get_tunnel", "add_tunnel", "update_tunnel", "remove_tunnel", "duplicate_tunnel",
                     "start_tunnel", "stop_tunnel", "test_tunnel", "tunnel_logs", "list_groups", "list_tags",
                     "describe_methods", "discover"] {
        #expect(names.contains(expected), "\(expected)")
    }
    for tool in tools {
        #expect(tool["inputSchema"]?["type"] == .string("object"))
        #expect(tool["description"]?.stringValue?.isEmpty == false)
    }
    let remove = try #require(tools.first { $0["name"] == .string("remove_tunnel") })
    #expect(remove["annotations"]?["destructiveHint"] == .bool(true))
    let list = try #require(tools.first { $0["name"] == .string("list_tunnels") })
    #expect(list["annotations"]?["readOnlyHint"] == .bool(true))
    let add = try #require(tools.first { $0["name"] == .string("add_tunnel") })
    #expect(add["inputSchema"]?["properties"]?["tunnel"]?["properties"]?["method"] != nil)
}

@Test func toolsCallForwardsToTheApp() throws {
    let calls = Calls()
    let mcp = server(calls)
    _ = try send(mcp, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#)
    _ = mcp.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
    let reply = try send(mcp, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_tunnels","arguments":{"group":"Prod"}}}"#)
    #expect(calls.made.count == 1)
    #expect(calls.made[0].0 == "tunnels.list")
    #expect(calls.made[0].1 == .object(["group": .string("Prod")]))
    #expect(reply["result"]?["isError"] == .bool(false))
    #expect(reply["result"]?["structuredContent"]?["tunnels"]?[0]?["name"] == .string("Web"))
    let text = try #require(reply["result"]?["content"]?[0]?["text"]?.stringValue)
    #expect(text.contains("\"Web\""))
}

@Test func toolErrorsAreResultsTheModelCanRead() throws {
    let reply = try send(server(), #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"remove_tunnel","arguments":{"tunnel":"Nope"}}}"#)
    #expect(reply["error"] == nil)
    #expect(reply["result"]?["isError"] == .bool(true))
    #expect(reply["result"]?["content"]?[0]?["text"] == .string("No tunnel named Nope."))

    let unknown = try send(server(), #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"rm_rf"}}"#)
    #expect(unknown["error"]?["code"] == .int(RPCError.invalidParams))
}

@Test func pingAndUnknownMethods() throws {
    #expect(try send(server(), #"{"jsonrpc":"2.0","id":5,"method":"ping"}"#)["result"] == .object([:]))
    #expect(try send(server(), #"{"jsonrpc":"2.0","id":6,"method":"sampling/createMessage"}"#)["error"]?["code"]
            == .int(RPCError.methodNotFound))
    #expect(try send(server(), "{not json")["error"]?["code"] == .int(RPCError.parseError))
}

extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        if case .array(let items) = self, items.indices.contains(index) { return items[index] }
        return nil
    }
}
