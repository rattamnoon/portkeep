import Foundation
import Testing
@testable import TunnelKit

private func command(_ text: String) -> RemoteCommand? { URL(string: text).flatMap(RemoteCommand.init(url:)) }

@Test func parsesStartStopToggle() {
    #expect(command("portkeep://start?name=Orders%20MySQL") == .run(.start, .tunnel("Orders MySQL")))
    #expect(command("portkeep://stop?group=Production") == .run(.stop, .group("Production")))
    #expect(command("portkeep://toggle?all") == .run(.toggle, .all))
    #expect(command("PORTKEEP://START?NAME=db") == .run(.start, .tunnel("db")))
    #expect(command("portkeep://open") == .openSettings(tunnel: nil))
    #expect(command("portkeep://open?name=db") == .openSettings(tunnel: "db"))
}

@Test func rejectsUnknownURLs() {
    #expect(command("portkeep://start") == nil, "needs a target")
    #expect(command("portkeep://restart?name=db") == nil)
    #expect(command("https://start?name=db") == nil)
    #expect(command("portkeep://start?name=") == nil)
}

@Test func targetsMatchIgnoringCase() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .dynamic, host: "jump"))
    let a = Tunnel(name: "Orders MySQL", group: "Production", localPort: 3306, method: ssh)
    let b = Tunnel(name: "Orders MySQL", group: "Development", localPort: 3306, method: ssh)
    let c = Tunnel(name: "Redis", group: "Production", localPort: 6379, method: ssh)
    let all = [a, b, c]
    #expect(RemoteCommand.Target.tunnel("orders mysql").tunnels(in: all) == [a, b])
    #expect(RemoteCommand.Target.tunnel(b.id.uuidString).tunnels(in: all) == [b])
    #expect(RemoteCommand.Target.tunnel(b.id.uuidString.lowercased()).tunnels(in: all) == [b])
    #expect(RemoteCommand.Target.group("production").tunnels(in: all) == [a, c])
    #expect(RemoteCommand.Target.all.tunnels(in: all) == all)
    #expect(RemoteCommand.Target.tunnel("nope").tunnels(in: all).isEmpty)
}

@Test func statusSnapshotWritesStateWords() throws {
    let id = UUID()
    let snapshot = StatusSnapshot(pid: 42, running: true, tunnels: [
        .init(id: id, name: "db", group: "UAT", port: 5432, state: StatusSnapshot.stateName(.standingBy), status: "Standing by"),
    ])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try snapshot.write(to: url)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    #expect(try decoder.decode(StatusSnapshot.self, from: Data(contentsOf: url)) == snapshot)
    #expect(StatusSnapshot.stateName(.retrying(.hostUnreachable, attempt: 1, until: .now)) == "reconnecting")
}
