import Foundation
import Testing
@testable import TunnelKit

private func json(_ text: String) -> JSONValue {
    try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

private func rejects(_ text: String, field: String, in file: TunnelFile = TunnelFile()) {
    do {
        _ = try TunnelInput.newTunnel(from: json(text), in: file)
        Issue.record("accepted \(text)")
    } catch {
        #expect(error.data?["field"]?.stringValue == field, "\(error.message)")
    }
}

@Test func newTunnelFillsDefaults() throws {
    let tunnel = try TunnelInput.newTunnel(from: json("""
        {"name": " Orders ", "localPort": 3306,
         "method": {"ssh": {"host": "app", "jump": "bastion", "destination": {"host": "db.internal", "port": 3306}}}}
        """), in: TunnelFile())
    #expect(tunnel.name == "Orders")
    #expect(tunnel.group == "Other")
    #expect(tunnel.tags == [])
    #expect(tunnel.idleMinutes == Tunnel.defaultIdleMinutes)
    #expect(tunnel.method == .ssh(SSHConfig(mode: .local, host: "app", jump: "bastion",
                                            destination: Endpoint(host: "db.internal", port: 3306))))
}

@Test func ssmAndKubeDefaults() throws {
    let ssm = try TunnelInput.newTunnel(from: json("""
        {"name": "Prod", "localPort": 3307, "method": {"ssm": {"region": "ap-southeast-1", "target": "i-1",
         "forwardTo": {"instance": {"port": 22}}}}}
        """), in: TunnelFile())
    #expect(ssm.method == .ssm(SSMConfig(profile: "default", region: "ap-southeast-1", target: "i-1", forwardTo: .instance(port: 22))))
    let kube = try TunnelInput.newTunnel(from: json("""
        {"name": "Grafana", "localPort": 3000, "method": {"kubernetes": {"context": "prod", "resource": "svc/grafana", "remotePort": 3000}}}
        """), in: TunnelFile())
    #expect(kube.method == .kubernetes(KubeConfig(context: "prod", namespace: "default", resource: "svc/grafana", remotePort: 3000)))
}

@Test func rejectsWhatTheEditorRejects() {
    rejects(#"{"localPort": 1, "method": {"custom": {"command": "x"}}}"#, field: "name")
    rejects(#"{"name": "a", "localPort": 70000, "method": {"custom": {"command": "x"}}}"#, field: "localPort")
    rejects(#"{"name": "a", "localPort": "3306", "method": {"custom": {"command": "x"}}}"#, field: "localPort")
    rejects(#"{"name": "a", "localPort": 1, "method": {"custom": {"command": "  "}}}"#, field: "method.custom.command")
    rejects(#"{"name": "a", "localPort": 1, "method": {"ssh": {"host": "h"}}}"#, field: "method.ssh.destination")
    rejects(#"{"name": "a", "localPort": 1, "method": {"ssm": {"target": "i-1", "forwardTo": {"instance": {"port": 1}}}}}"#,
            field: "method.ssm.region")
    rejects(#"{"name": "a", "localPort": 1, "method": {"ssh": {"host": "h"}, "custom": {"command": "x"}}}"#, field: "method")
    rejects(#"{"name": "a", "localPort": 1, "method": {"telnet": {}}}"#, field: "method.telnet")
    rejects(#"{"name": "a", "localPort": 1, "tags": ["db", "web"], "method": {"custom": {"command": "x"}}}"#, field: "tags")
    rejects(#"{"name": "a", "localPort": 1, "startsOnConnect": true, "method": {"custom": {"command": "x"}}}"#,
            field: "startsOnConnect")
}

@Test func unknownFieldsAreErrorsNotIgnored() {
    rejects(#"{"name": "a", "port": 1, "localPort": 1, "method": {"custom": {"command": "x"}}}"#, field: "port")
    rejects(#"{"name": "a", "localPort": 1, "method": {"ssh": {"host": "h", "mode": "dynamic", "password": "x"}}}"#,
            field: "method.ssh.password")
}

@Test func dynamicSSHDropsDestination() throws {
    let tunnel = try TunnelInput.newTunnel(from: json("""
        {"name": "SOCKS", "localPort": 1080, "method": {"ssh": {"mode": "dynamic", "host": "jump", "destination": {"host": "x", "port": 1}}}}
        """), in: TunnelFile())
    guard case .ssh(let c) = tunnel.method else { Issue.record("not ssh"); return }
    #expect(c.destination == nil)
}

@Test func namesMustBeUnique() {
    let existing = Tunnel(name: "Redis", group: "Other", localPort: 6379, method: .custom(CustomConfig(command: "x")))
    do {
        _ = try TunnelInput.newTunnel(from: json(#"{"name": "redis", "localPort": 1, "method": {"custom": {"command": "x"}}}"#),
                                      in: TunnelFile(tunnels: [existing]))
        Issue.record("accepted a duplicate name")
    } catch {
        #expect(error.code == RPCError.conflict)
    }
}

@Test func patchChangesOnlyWhatItNames() throws {
    let tunnel = Tunnel(name: "Orders", group: "Staging", localPort: 3306,
                        method: .ssh(SSHConfig(mode: .local, host: "app", destination: Endpoint(host: "db", port: 3306))),
                        tags: ["db"])
    let file = TunnelFile(tunnels: [tunnel])
    let moved = try TunnelInput.updated(tunnel, patch: json(#"{"localPort": 3307, "method": {"ssh": {"jump": "bastion"}}}"#), in: file)
    #expect(moved.id == tunnel.id)
    #expect(moved.localPort == 3307)
    #expect(moved.group == "Staging")
    #expect(moved.tags == ["db"])
    #expect(moved.method == .ssh(SSHConfig(mode: .local, host: "app", jump: "bastion", destination: Endpoint(host: "db", port: 3306))))

    // Another method replaces the old one rather than adding a second key.
    let kube = try TunnelInput.updated(tunnel, patch: json("""
        {"method": {"kubernetes": {"context": "c", "resource": "svc/db", "remotePort": 3306}}}
        """), in: file)
    #expect(kube.method == .kubernetes(KubeConfig(context: "c", namespace: "default", resource: "svc/db", remotePort: 3306)))

    // null removes an optional field.
    let noJump = try TunnelInput.updated(moved, patch: json(#"{"method": {"ssh": {"jump": null}}}"#), in: file)
    guard case .ssh(let c) = noJump.method else { Issue.record("not ssh"); return }
    #expect(c.jump == nil)

    #expect(throws: RPCError.self) {
        try TunnelInput.updated(tunnel, patch: json(#"{"id": "\#(UUID().uuidString)"}"#), in: file)
    }
}

@Test func ssmForwardToSwitchesKind() throws {
    let tunnel = Tunnel(name: "Prod", group: "Production", localPort: 3307, method: .ssm(SSMConfig(
        profile: "prod", region: "r", target: "i-1", forwardTo: .instance(port: 22))))
    let changed = try TunnelInput.updated(tunnel, patch: json("""
        {"method": {"ssm": {"forwardTo": {"remoteHost": {"host": "db", "port": 3306}}}}}
        """), in: TunnelFile(tunnels: [tunnel]))
    guard case .ssm(let c) = changed.method else { Issue.record("not ssm"); return }
    #expect(c.forwardTo == .remoteHost(Endpoint(host: "db", port: 3306)))
    #expect(c.profile == "prod")
}

@Test func mergePatchFollowsRFC7396() {
    let base = json(#"{"a": 1, "b": {"c": 2, "d": 3}}"#)
    #expect(base.merging(json(#"{"b": {"c": null, "e": 4}, "f": "x"}"#)) == json(#"{"a": 1, "b": {"d": 3, "e": 4}, "f": "x"}"#))
}

@Test func catalogExamplesAreValidTunnels() throws {
    for method in MethodCatalog.methods {
        let tunnel = try TunnelInput.newTunnel(from: method.example, in: TunnelFile())
        #expect(tunnel.methodName.isEmpty == false, "\(method.key)")
        guard case .object(let object) = method.example["method"] ?? .null else { Issue.record("no method"); continue }
        #expect(object.keys.first == method.key)
    }
}

@Test func schemaListsEveryMethod() {
    let schema = MethodCatalog.tunnelSchema()
    let methods = schema["properties"]?["method"]?["properties"]?.objectValue?.keys.sorted()
    #expect(methods == ["cloudflare", "custom", "iap", "kubernetes", "ssh", "ssm"])
    #expect(schema["required"] == .array([.string("name"), .string("localPort"), .string("method")]))
    #expect(schema["properties"]?["localPort"]?["maximum"] == .int(65535))
}
