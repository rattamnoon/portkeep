import Foundation
import Testing
@testable import TunnelKit

@Test func diagnosticsAreMarkdownForAnIssue() {
    let tools = ToolPaths(searchPath: "/opt/homebrew/bin:/usr/bin", overrides: [:]) { ["/usr/bin/ssh", "/opt/homebrew/bin/aws"].contains($0) }
    let env = Diagnostics.Environment(
        appVersion: "0.4.0", build: "12", macOS: "Version 15.5 (Build 24F74)", architecture: "arm64",
        tools: [("ssh", "/usr/bin/ssh", false), ("aws", "/Users/me/bin/aws", true), ("kubectl", nil, false)],
        toolPaths: tools)
    let ssh = Tunnel(name: "Orders", group: "Staging", localPort: 3306, method: .ssh(SSHConfig(
        mode: .local, host: "app", jump: "bastion", destination: Endpoint(host: "db.internal", port: 3306),
        identityFile: "/Users/me/.ssh/id_ed25519")))
    let ssm = Tunnel(name: "Prod", group: "Production", localPort: 3307, method: .ssm(SSMConfig(
        profile: "prod", region: "ap-southeast-1", target: "i-1", forwardTo: .instance(port: 22))))
    let text = Diagnostics.markdown(env, tunnels: [
        .init(tunnel: ssh, state: .blocked(PortOwner(pid: 9, command: "mysqld")), log: (1...80).map { "line \($0)" }),
        .init(tunnel: ssm, state: .failed(.ssoExpired(profile: "prod")), log: []),
    ], now: Date(timeIntervalSince1970: 0), home: "/Users/me")

    #expect(text.hasPrefix("### Portkeep diagnostics"))
    #expect(text.contains("- Portkeep: 0.4.0 (12)"))
    #expect(text.contains("  - aws: `~/bin/aws` (set on the Tools page)"))
    #expect(text.contains("  - kubectl: not found"))
    #expect(text.contains("#### Orders"))
    #expect(text.contains("(port held by mysqld, pid 9)"))
    #expect(text.contains("`ssoExpired`"))
    #expect(text.contains("- Runs: `/usr/bin/ssh -N -L 3306:db.internal:3306 -J bastion"))
    #expect(text.contains("\"host\" : \"db.internal\""), "hostnames stay")
    #expect(text.contains("~/.ssh/id_ed25519"))
    #expect(!text.contains("/Users/me"), "home folder shortened")
    #expect(!text.contains(ssh.id.uuidString))
    #expect(text.contains("line 80") && text.contains("line 31") && !text.contains("line 30\n"))
    #expect(text.contains("Log (last 0 lines)") && text.contains("(empty)"))
}
