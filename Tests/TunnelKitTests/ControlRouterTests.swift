import Foundation
import Testing
@testable import TunnelKit

/// TunnelStore's part, without processes: switching on connects straight away (or fails as told).
@MainActor
final class FakeBackend: ControlBackend {
    var file = TunnelFile()
    var readOnly = false
    let fakePorts = FakePorts()
    var ports: any PortChecking { fakePorts }
    var states: [UUID: TunnelState] = [:]
    var on: Set<UUID> = []
    /// What switching on (or testing) a tunnel leads to.
    var outcome: TunnelState = .connected(since: Date(timeIntervalSince1970: 0))
    var logs: [UUID: [String]] = [:]

    func state(of id: UUID) -> TunnelState { states[id] ?? .off }
    func isOn(_ id: UUID) -> Bool { on.contains(id) }

    func save(_ tunnel: Tunnel) async {
        if !file.groups.contains(tunnel.group) { file.groups.append(tunnel.group) }
        if let index = file.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            file.tunnels[index] = tunnel
        } else {
            file.tunnels.append(tunnel)
        }
    }

    func delete(_ id: UUID) async {
        on.remove(id)
        states[id] = nil
        file.tunnels.removeAll { $0.id == id }
    }

    func duplicate(_ id: UUID) -> UUID? {
        guard let index = file.tunnels.firstIndex(where: { $0.id == id }) else { return nil }
        let copy = file.tunnels[index].duplicate(named: "\(file.tunnels[index].name) copy")
        file.tunnels.insert(copy, at: index + 1)
        return copy.id
    }

    func switchOn(_ ids: [UUID]) async {
        for id in ids {
            on.insert(id)
            states[id] = outcome
        }
    }

    func turnOff(_ id: UUID) async {
        on.remove(id)
        states[id] = .off
    }

    func test(_ tunnel: Tunnel) async -> (state: TunnelState, log: [String]) { (outcome, ["test of \(tunnel.name)"]) }
    func log(for id: UUID) -> [String] { logs[id] ?? [] }
    func addGroup(_ name: String, hex: String) {
        file.groups.append(name)
        file.groupColors[name] = hex
    }
    func addTag(_ name: String, hex: String) {
        file.tags.append(name)
        file.tagColors[name] = hex
    }
    func discover() async -> Discovery { Discovery(sshHosts: ["bastion"], awsProfiles: [AWSProfile(name: "prod", region: "ap-southeast-1")]) }
}

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private let custom = #"{"name": "Web", "localPort": 8000, "method": {"custom": {"command": "python3 -m http.server {port}"}}}"#

@MainActor
private func router() -> (ControlRouter, FakeBackend) {
    let backend = FakeBackend()
    let router = ControlRouter(backend: backend)
    router.defaultWait = 0.5
    return (router, backend)
}

@MainActor @Test func addListGetUpdateRemove() async throws {
    let (router, backend) = router()
    let added = try await router.call("tunnels.add", json(#"{"tunnel": \#(custom)}"#))
    #expect(added["tunnel"]?["name"] == .string("Web"))
    #expect(added["tunnel"]?["state"] == .string("off"))
    #expect(added["warnings"] == .array([]))
    #expect(backend.file.tunnels.count == 1)

    let list = try await router.call("tunnels.list", .object([:]))
    #expect(list["tunnels"]?.arrayValue?.count == 1)

    let got = try await router.call("tunnels.get", json(#"{"tunnel": "web"}"#))
    #expect(got["localPort"] == .int(8000))

    let updated = try await router.call("tunnels.update", json(#"{"tunnel": "Web", "patch": {"localPort": 8001}}"#))
    #expect(updated["tunnel"]?["localPort"] == .int(8001))
    #expect(backend.file.tunnels[0].localPort == 8001)

    let removed = try await router.call("tunnels.remove", json(#"{"tunnel": "Web"}"#))
    #expect(removed["removed"]?["name"] == .string("Web"))
    #expect(backend.file.tunnels.isEmpty)
}

@MainActor @Test func startWaitsAndReportsHints() async throws {
    let (router, backend) = router()
    _ = try await router.call("tunnels.add", json(#"{"tunnel": \#(custom)}"#))
    let started = try await router.call("tunnels.start", json(#"{"tunnel": "Web"}"#))
    #expect(started["tunnels"]?[0]?["state"] == .string("connected"))
    #expect(started["tunnels"]?[0]?["connectedSince"] != nil)

    backend.outcome = .failed(.ssoExpired(profile: "prod"))
    _ = try await router.call("tunnels.stop", json(#"{"all": true}"#))
    let failed = try await router.call("tunnels.start", json(#"{"group": "other"}"#))
    #expect(failed["tunnels"]?[0]?["reason"] == .string("ssoExpired"))
    #expect(failed["tunnels"]?[0]?["hint"]?.stringValue?.contains("aws sso login --profile prod") == true)

    backend.outcome = .blocked(PortOwner(pid: 42, command: "nginx"))
    _ = try await router.call("tunnels.stop", json(#"{"tunnel": "Web"}"#))
    let blocked = try await router.call("tunnels.toggle", json(#"{"tunnel": "Web"}"#))
    #expect(blocked["tunnels"]?[0]?["blockedBy"]?["command"] == .string("nginx"))
    #expect(blocked["tunnels"]?[0]?["hint"]?.stringValue?.contains("nginx (pid 42)") == true)
}

@MainActor @Test func warnsAboutSharedAndBusyPorts() async throws {
    let (router, backend) = router()
    _ = try await router.call("tunnels.add", json(#"{"tunnel": \#(custom)}"#))
    let shared = try await router.call("tunnels.add", json("""
        {"tunnel": {"name": "Web 2", "localPort": 8000, "method": {"custom": {"command": "x"}}}}
        """))
    #expect(shared["warnings"]?[0]?.stringValue?.contains("shared with Web") == true)

    backend.fakePorts.free = false
    backend.fakePorts.owner = PortOwner(pid: 7, command: "postgres")
    let busy = try await router.call("tunnels.add", json("""
        {"tunnel": {"name": "PG", "localPort": 5432, "method": {"custom": {"command": "x"}}}}
        """))
    #expect(busy["warnings"]?[0]?.stringValue?.contains("postgres (pid 7)") == true)
}

@MainActor @Test func errorsAreReadable() async {
    let (router, backend) = router()
    await #expect(throws: RPCError(RPCError.notFound, "No tunnel named nope. There are no tunnels yet.")) {
        try await router.call("tunnels.get", json(#"{"tunnel": "nope"}"#))
    }
    await #expect(throws: RPCError.self) { try await router.call("tunnels.frobnicate", .object([:])) }
    backend.readOnly = true
    do {
        _ = try await router.call("tunnels.add", json(#"{"tunnel": \#(custom)}"#))
        Issue.record("saved while read-only")
    } catch {
        #expect(error.code == RPCError.readOnly)
    }
}

@MainActor @Test func duplicateTestLogsLabels() async throws {
    let (router, backend) = router()
    _ = try await router.call("tunnels.add", json(#"{"tunnel": \#(custom)}"#))
    let copy = try await router.call("tunnels.duplicate", json(#"{"tunnel": "Web", "name": "Web staging"}"#))
    #expect(copy["tunnel"]?["name"] == .string("Web staging"))
    #expect(backend.file.tunnels.map(\.name) == ["Web", "Web staging"])

    let tested = try await router.call("tunnels.test", json(#"{"config": \#(custom)}"#))
    #expect(tested["ok"] == .bool(true))
    #expect(tested["log"] == .array([.string("test of Web")]))

    backend.logs[backend.file.tunnels[0].id] = (1...80).map { "line \($0)" }
    let logs = try await router.call("tunnels.logs", json(#"{"tunnel": "Web", "lines": 3}"#))
    #expect(logs["lines"] == .array(["line 78", "line 79", "line 80"].map(JSONValue.string)))

    let group = try await router.call("groups.add", json(##"{"name": "QA", "color": "#00ff00"}"##))
    #expect(group["color"] == .string("#00FF00"))
    await #expect(throws: RPCError.self) { try await router.call("groups.add", json(#"{"name": "qa"}"#)) }
    await #expect(throws: RPCError.self) { try await router.call("tags.add", json(#"{"name": "x", "color": "green"}"#)) }
    let tags = try await router.call("tags.list", .object([:]))
    #expect(tags["tags"]?.arrayValue?.isEmpty == false)

    let found = try await router.call("discover", .object([:]))
    #expect(found["sshHosts"] == .array([.string("bastion")]))
    #expect(found["tunnelPorts"]?.arrayValue?.count == 2)

    let methods = try await router.call("methods.describe", json(#"{"method": "ssm"}"#))
    #expect(methods["methods"]?.arrayValue?.count == 1)
}

@MainActor @Test func handlesLinesAndNotifications() async throws {
    let (router, _) = router()
    let reply = await router.handle(Data(#"{"jsonrpc": "2.0", "id": 7, "method": "status"}"#.utf8))
    let response = try JSONDecoder().decode(RPCResponse.self, from: #require(reply))
    #expect(response.id == .int(7))
    #expect(response.result?["running"] == .bool(true))

    #expect(await router.handle(Data(#"{"jsonrpc": "2.0", "method": "status"}"#.utf8)) == nil)

    let junk = try JSONDecoder().decode(RPCResponse.self, from: #require(await router.handle(Data("nope".utf8))))
    #expect(junk.error?.code == RPCError.parseError)
}

@Test func socketRoundTrip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pk-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let path = ControlSocket.path(in: dir)
    // A stale socket file from a crash is replaced.
    let stale = ControlSocketServer(path: path) { _ in nil }
    try stale.start()
    let server = ControlSocketServer(path: path) { line in
        let request = try! JSONDecoder().decode(RPCRequest.self, from: line)
        if request.method == "fail" { return RPCResponse(id: request.id!, error: RPCError(RPCError.notFound, "nope")).line() }
        return RPCResponse(id: request.id!, result: .object(["echo": request.params ?? .null])).line()
    }
    #expect(throws: ControlSocket.Failure.self) { try server.start() }
    stale.stop()
    try server.start()
    defer { server.stop() }

    var info = stat()
    #expect(lstat(path, &info) == 0)
    #expect(info.st_mode & 0o777 == 0o600)

    // The client blocks, as it does in the command line tool, so it runs on a thread of its own
    // rather than holding one of the pool's threads the server's handler needs.
    let results: [Result<JSONValue, RPCError>] = await withCheckedContinuation { done in
        Thread {
            let client = ControlClient(path: path)
            let calls: [(String, JSONValue)] = [("echo", .object(["x": .int(1)])), ("fail", .object([:])), ("echo", .object([:]))]
            done.resume(returning: calls.map { call in Result { () throws(RPCError) in try client.call(call.0, call.1) } })
        }.start()
    }
    #expect(try results[0].get()["echo"]?["x"] == .int(1))
    #expect(throws: RPCError(RPCError.notFound, "nope")) { try results[1].get() }
    // Same connection, still answering.
    #expect(try results[2].get()["echo"] == .object([:]))
}

@Test func clientSaysWhenNothingListens() {
    let client = ControlClient(path: FileManager.default.temporaryDirectory.appendingPathComponent("none-\(UUID().uuidString).sock").path)
    do {
        _ = try client.call("status")
        Issue.record("connected to nothing")
    } catch {
        #expect(error.code == RPCError.unavailable)
    }
}
