import Foundation
import Testing
@testable import TunnelKit

private let allTools = ToolPaths(searchPath: "/opt/homebrew/bin", overrides: [:], isExecutable: { _ in true })

private func args(_ method: TunnelMethod, port: Int = 3306, tools: ToolPaths = allTools) throws -> [String] {
    try CommandBuilder.invocation(
        for: Tunnel(name: "t", group: "g", localPort: port, method: method), tools: tools
    ).arguments
}

@Test func sshLocal() throws {
    let inv = try CommandBuilder.invocation(
        for: Tunnel(name: "t", group: "g", localPort: 3306, method: .ssh(SSHConfig(
            mode: .local, host: "jump", destination: Endpoint(host: "mysql.internal", port: 3306)))),
        tools: allTools)
    #expect(inv.executable.path == "/opt/homebrew/bin/ssh")
    #expect(inv.arguments == [
        "-N", "-L", "3306:mysql.internal:3306",
        "-o", "ExitOnForwardFailure=yes", "-o", "ServerAliveInterval=30", "-o", "BatchMode=yes",
        "jump",
    ])
}

@Test func sshLocalWithJumpIdentityCompressionExtra() throws {
    let a = try args(.ssh(SSHConfig(
        mode: .local, host: "jump", jump: "bastion", destination: Endpoint(host: "db", port: 5432),
        identityFile: "~/.ssh/id_ed25519", compression: true, extraArgs: #"-v -o "LogLevel=ERROR""#)))
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    #expect(a.last == "jump")
    #expect(a.contains(sequence: ["-J", "bastion"]))
    #expect(a.contains(sequence: ["-i", "\(home)/.ssh/id_ed25519"]))
    #expect(a.contains("-C"))
    #expect(a.contains(sequence: ["-v", "-o", "LogLevel=ERROR", "jump"]))
}

@Test func sshRemote() throws {
    let a = try args(.ssh(SSHConfig(mode: .remote, host: "jump", destination: Endpoint(host: "localhost", port: 3000))), port: 8080)
    #expect(a.contains(sequence: ["-R", "8080:localhost:3000"]))
}

@Test func sshDynamic() throws {
    let a = try args(.ssh(SSHConfig(mode: .dynamic, host: "jump")), port: 1080)
    #expect(a.contains(sequence: ["-D", "1080"]))
    #expect(!a.contains("-L"))
}

@Test func sshKeepAliveAndForwardFailureOverrides() throws {
    let a = try args(.ssh(SSHConfig(mode: .dynamic, host: "jump", keepAlive: 15, exitOnForwardFailure: false)), port: 1080)
    #expect(a.contains("ServerAliveInterval=15"))
    #expect(!a.contains("ExitOnForwardFailure=yes"))
    #expect(a.contains("BatchMode=yes"))
}

@Test func ssmRemoteHost() throws {
    let inv = try CommandBuilder.invocation(
        for: Tunnel(name: "t", group: "g", localPort: 3306, method: .ssm(SSMConfig(
            profile: "prod", region: "ap-southeast-1", target: "i-0a3f",
            forwardTo: .remoteHost(Endpoint(host: "mysql.prod.internal", port: 3306))))),
        tools: allTools)
    #expect(inv.executable.path == "/opt/homebrew/bin/aws")
    #expect(inv.arguments == [
        "ssm", "start-session", "--profile", "prod", "--region", "ap-southeast-1", "--target", "i-0a3f",
        "--document-name", "AWS-StartPortForwardingSessionToRemoteHost",
        "--parameters", "host=mysql.prod.internal,portNumber=3306,localPortNumber=3306",
    ])
}

@Test func ssmInstance() throws {
    let a = try args(.ssm(SSMConfig(profile: "prod", region: "ap-southeast-1", target: "i-0a3f", forwardTo: .instance(port: 22))), port: 2222)
    #expect(a == [
        "ssm", "start-session", "--profile", "prod", "--region", "ap-southeast-1", "--target", "i-0a3f",
        "--document-name", "AWS-StartPortForwardingSession",
        "--parameters", "portNumber=22,localPortNumber=2222",
    ])
}

@Test func kubernetes() throws {
    let a = try args(.kubernetes(KubeConfig(context: "acme-prod", namespace: "monitoring", resource: "svc/grafana", remotePort: 3000)), port: 3000)
    #expect(a == ["--context", "acme-prod", "-n", "monitoring", "port-forward", "svc/grafana", "3000:3000", "--address", "127.0.0.1"])
}

@Test func iap() throws {
    let a = try args(.iap(IAPConfig(project: "proj", zone: "asia-southeast1-a", instance: "pg-1", remotePort: 5432)), port: 5432)
    #expect(a == ["compute", "start-iap-tunnel", "pg-1", "5432", "--local-host-port=localhost:5432", "--zone", "asia-southeast1-a", "--project", "proj"])
}

@Test func cloudflare() throws {
    let a = try args(.cloudflare(CloudflareConfig(hostname: "db.example.com")), port: 5432)
    #expect(a == ["access", "tcp", "--hostname", "db.example.com", "--url", "localhost:5432"])
}

@Test func customReplacesPort() throws {
    let inv = try CommandBuilder.invocation(
        for: Tunnel(name: "t", group: "g", localPort: 5432, method: .custom(CustomConfig(command: "tsh proxy db --port {port} pg"))),
        tools: allTools)
    #expect(inv.executable.path == "/bin/zsh")
    #expect(inv.arguments == ["-c", "tsh proxy db --port 5432 pg"])
}

@Test func missingPluginThrows() throws {
    let tools = ToolPaths(searchPath: "/opt/homebrew/bin", overrides: [:], isExecutable: { $0.hasSuffix("/aws") })
    #expect(throws: ToolMissing(tool: "session-manager-plugin", installHint: "brew install --cask session-manager-plugin")) {
        try args(.ssm(SSMConfig(profile: "p", region: "r", target: "i", forwardTo: .instance(port: 22))), tools: tools)
    }
}

@Test func shellSplitHandlesQuotes() {
    #expect(CommandBuilder.shellSplit(#"-v -o "LogLevel=ERROR" -o 'A B' C\ D"#) == ["-v", "-o", "LogLevel=ERROR", "-o", "A B", "C D"])
    #expect(CommandBuilder.shellSplit("   ") == [])
}

extension Array where Element == String {
    func contains(sequence: [String]) -> Bool {
        guard sequence.count <= count else { return false }
        return (0...(count - sequence.count)).contains { Array(self[$0..<($0 + sequence.count)]) == sequence }
    }
}
