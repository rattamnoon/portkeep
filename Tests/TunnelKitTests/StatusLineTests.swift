import Foundation
import Testing
@testable import TunnelKit

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let tunnel = Tunnel(name: "ClickHouse", group: "Production", localPort: 8123,
                            method: .ssh(SSHConfig(mode: .local, host: "jump")))

@Test func statusLines() {
    #expect(statusLine(.connected(since: now.addingTimeInterval(-8040)), tunnel: tunnel, now: now) == "Connected · 2h 14m")
    #expect(statusLine(.connected(since: now.addingTimeInterval(-300)), tunnel: tunnel, now: now) == "Connected · 5m")
    #expect(statusLine(.connected(since: now.addingTimeInterval(-10)), tunnel: tunnel, now: now) == "Connected · just now")
    #expect(statusLine(.blocked(PortOwner(pid: 4411, command: "clickhouse-server")), tunnel: tunnel, now: now)
            == "Port 8123 is in use by clickhouse-server")
    #expect(statusLine(.blocked(nil), tunnel: tunnel, now: now, blockedBy: "Analytics") == "Port 8123 is used by Analytics")
    #expect(statusLine(.retrying(.hostUnreachable, attempt: 2, until: now), tunnel: tunnel, now: now)
            == "Reconnecting… can't reach jump")
    #expect(statusLine(.starting, tunnel: tunnel, now: now) == "Connecting…")
    #expect(statusLine(.off, tunnel: tunnel, now: now) == "Off")
    #expect(statusLine(.failed(.ssoExpired(profile: "prod")), tunnel: tunnel, now: now) == "AWS sign-in expired for profile prod.")
}
