import Foundation
import Testing
@testable import TunnelKit

private func forwards(_ text: String, files: [String: String] = [:]) -> [SSHConfigForward] {
    SSHConfigParser.forwards(in: text) { pattern in files[pattern].map { [$0] } ?? [] }
}

@Test func localForwardForms() {
    let found = forwards("""
    Host bastion
      HostName 10.0.0.1
      LocalForward 5432 db.internal:5432
      LocalForward 127.0.0.1:3306 mysql.internal:3306
      LocalForward [::1]:6379 redis.internal:6379
      LocalForward=8123 [2001:db8::1]:8123
      LocalForward localhost/9200 search.internal/9200
      LocalForward /tmp/socket db.internal:5432
      DynamicForward 1080
    """)
    #expect(found.map(\.localPort) == [5432, 3306, 6379, 8123, 9200, 1080])
    #expect(found[0].destination == Endpoint(host: "db.internal", port: 5432))
    #expect(found[2].destination == Endpoint(host: "redis.internal", port: 6379))
    #expect(found[3].destination == Endpoint(host: "[2001:db8::1]", port: 8123))
    #expect(found[4].destination == Endpoint(host: "search.internal", port: 9200))
    #expect(found[5].mode == .dynamic && found[5].destination == nil)
    #expect(found.allSatisfy { $0.host == "bastion" && $0.forwardsOnHost == 6 })
    #expect(found[0].name == "bastion 5432")
}

@Test func wildcardHostsAndMatchBlocksAreSkipped() {
    let found = forwards("""
    # comment
    Host *
      LocalForward 1111 a:1
    Host *.internal !bad
      LocalForward 2222 b:2
    Host jump prod-jump
      LocalForward 3333 c:3
    Match host foo
      LocalForward 4444 d:4
    """)
    #expect(found.map(\.host) == ["jump", "prod-jump"])
    #expect(found.map(\.localPort) == [3333, 3333])
}

@Test func includeIsFollowedInPlace() {
    let found = forwards("""
    Include config.d/*
    Host main
      LocalForward 1000 a:1
      Include extra
    """, files: [
        "config.d/*": "Host included\n  DynamicForward 1080\n",
        "extra": "  LocalForward 2000 b:2\n",
    ])
    #expect(found.map(\.name) == ["included 1080", "main 1000", "main 2000"])
}

@Test func includeGlobsAreExpandedFromTheSSHDirectory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir.appendingPathComponent("config.d"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    try "Include config.d/*.conf\n".write(to: dir.appendingPathComponent("config"), atomically: true, encoding: .utf8)
    try "Host b\n  LocalForward 2 x:2\n".write(to: dir.appendingPathComponent("config.d/b.conf"), atomically: true, encoding: .utf8)
    try "Host a\n  LocalForward 1 x:1\n".write(to: dir.appendingPathComponent("config.d/a.conf"), atomically: true, encoding: .utf8)
    try "Host ignored\n  LocalForward 3 x:3\n".write(to: dir.appendingPathComponent("config.d/notes.txt"), atomically: true, encoding: .utf8)

    let found = SSHConfigParser.forwards(fromFile: dir.appendingPathComponent("config"))
    #expect(found.map(\.name) == ["a 1", "b 2"])
}

@Test func selfIncludeStops() {
    let found = forwards("Host h\n  LocalForward 1 x:1\nInclude self\n", files: ["self": "Include self\n"])
    #expect(found.count == 1)
}

@Test func forwardBecomesAnSSHTunnel() {
    let forward = SSHConfigForward(host: "bastion", mode: .local, localPort: 5432, destination: Endpoint(host: "db", port: 5432))
    let tunnel = forward.tunnel(group: "Other")
    #expect(tunnel.name == "bastion 5432")
    #expect(tunnel.method == .ssh(SSHConfig(mode: .local, host: "bastion", destination: Endpoint(host: "db", port: 5432))))
    #expect(forward.matches(tunnel))
}

// MARK: Export / import

private let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump", destination: Endpoint(host: "db", port: 5432)))

@Test func exportLeavesOutToolPaths() throws {
    var file = TunnelFile(tunnels: [Tunnel(name: "db", group: "Production", localPort: 5432, method: ssh)])
    file.toolPaths = ["aws": "/opt/homebrew/bin/aws"]
    let json = String(decoding: try TunnelExport(file).data(), as: UTF8.self)
    #expect(!json.contains("toolPaths") && !json.contains("/opt/homebrew"))
    #expect(try JSONDecoder().decode(TunnelExport.self, from: Data(json.utf8)) == TunnelExport(file))
}

@Test func importAddsNewIdsSkipsDuplicatesAndAddsLabels() throws {
    let existing = Tunnel(name: "db", group: "Production", localPort: 5432, method: ssh, tags: ["db"])
    var mine = TunnelFile(groups: ["Production"], tunnels: [existing], tags: ["db"], tagColors: ["db": "#007AFF"], groupColors: [:])

    let same = Tunnel(name: "db", group: "Production", localPort: 5432, method: ssh, tags: ["db"])
    let new = Tunnel(name: "cache", group: "Edge", localPort: 6379, method: ssh, tags: ["cache"])
    var theirs = TunnelFile(groups: ["Edge", "Production"], tunnels: [same, new], tags: ["db", "cache"],
                            tagColors: ["db": "#FF0000", "cache": "#FF2D55"], groupColors: ["Edge": "#123456"])
    theirs.toolPaths = ["ssh": "/x"]

    let (summary, added) = mine.merge(TunnelExport(theirs))
    #expect(summary == ImportSummary(imported: 1, skipped: 1))
    #expect(added.count == 1 && added[0].id != new.id && added[0].sameSettings(as: new))
    #expect(mine.groups == ["Production", "Edge"])
    #expect(mine.groupColors == ["Edge": "#123456"])
    #expect(mine.tags == ["db", "cache"])
    #expect(mine.tagColors == ["db": "#007AFF", "cache": "#FF2D55"], "keeps my colour for a tag I have")
    #expect(mine.toolPaths.isEmpty)

    // Importing the same file again adds nothing.
    #expect(mine.merge(TunnelExport(theirs)).summary == ImportSummary(imported: 0, skipped: 2))
}

@Test func importReadsAWholeTunnelsFile() throws {
    let file = TunnelFile(tunnels: [Tunnel(name: "db", group: "Production", localPort: 5432, method: ssh)])
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("tunnels-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    try file.save(to: url)
    let export = try JSONDecoder().decode(TunnelExport.self, from: Data(contentsOf: url))
    #expect(export.tunnels == file.tunnels)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(TunnelExport.self, from: Data(#"{"hello": 1}"#.utf8)) }
}
