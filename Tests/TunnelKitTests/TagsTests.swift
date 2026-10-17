import Foundation
import Testing
@testable import TunnelKit

@Test func oldFilesWithoutTagsStillLoad() throws {
    let json = """
    {"schemaVersion":1,"tunnels":[{"id":"6F1C2B8E-3D4A-4E5F-8A9B-0C1D2E3F4A5B","name":"db","group":"g","localPort":1,
     "connectAtLogin":false,"method":{"custom":{"command":"x"}}}]}
    """
    let file = try JSONDecoder().decode(TunnelFile.self, from: Data(json.utf8))
    #expect(file.tunnels[0].tags == [])
    #expect(file.tags == TunnelFile.defaultTags, "old files get the starter tags")
    #expect(file.tagColors == TunnelFile.defaultTagColors)
    #expect(file.groupColors == [:], "no starter group here, so no starter colour")
}

@Test func tagsAndColoursRoundTrip() throws {
    let file = TunnelFile(
        tunnels: [Tunnel(name: "ch", group: "TH", localPort: 8123, method: .custom(CustomConfig(command: "x")), tags: ["db", "olap"])],
        tags: [], tagColors: ["db": "#112233"], groupColors: ["TH": "#AABBCC"])
    let again = try JSONDecoder().decode(TunnelFile.self, from: JSONEncoder().encode(file))
    #expect(again == file)
    #expect(again.tagColor("db") == "#112233")
    #expect(again.tagColor("olap") == LabelColor.defaultHex(for: "olap"))
    #expect(again.allTags == ["db", "olap"])
}

@Test func newFileStartsWithDefaultsAndDefinedTagsStayWithoutTunnels() throws {
    var file = TunnelFile()
    #expect(file.groups == ["Production", "Staging", "Development", "Local", "Other"])
    #expect(file.groupColors["Production"] == "#FF3B30")
    #expect(file.tags.contains("db"))
    #expect(file.usedTags.isEmpty, "defined but unused tags aren't 'used'")
    file.tunnels = [Tunnel(name: "x", group: "Local", localPort: 1, method: .custom(CustomConfig(command: "x")), tags: ["db", "extra"])]
    #expect(file.usedTags == ["db", "extra"])
    #expect(file.allTags.last == "extra", "typed tags join the defined ones")
    let again = try JSONDecoder().decode(TunnelFile.self, from: JSONEncoder().encode(file))
    #expect(again.tags == file.tags)
}

@Test func parseTagsTrimsAndDeduplicates() {
    #expect(Tunnel.parseTags(" db, readonly ,DB,, olap ") == ["db", "readonly", "olap"])
    #expect(Tunnel.parseTags("") == [])
}

@Test func hexConversion() {
    let c = LabelColor.components("#FF8000")!
    #expect(c.0 == 1 && abs(c.1 - 128.0 / 255) < 0.0001 && c.2 == 0)
    #expect(LabelColor.components("nope") == nil)
    #expect(LabelColor.hex(red: 1, green: 0.5, blue: 0) == "#FF8000")
    #expect(LabelColor.presets.contains(LabelColor.defaultHex(for: "anything")))
}

@Test func duplicateKeepsEverythingButIdAndName() {
    let original = Tunnel(name: "Redis", group: "Staging", localPort: 16379, connectAtLogin: true,
                          method: .ssh(SSHConfig(mode: .local, host: "jump", destination: Endpoint(host: "redis", port: 6379))),
                          tags: ["cache"], startsOnConnect: true, idleMinutes: 5)
    let copy = original.duplicate(named: "Redis copy")
    #expect(copy.id != original.id)
    #expect(copy.name == "Redis copy")
    var renamed = copy
    renamed.id = original.id
    renamed.name = original.name
    #expect(renamed == original)
}

@Test func copyNamesCountUp() {
    let label: (Int) -> String = { $0 == 1 ? "Redis copy" : "Redis copy \($0)" }
    #expect(Tunnel.copyName(taken: ["Redis"], label: label) == "Redis copy")
    #expect(Tunnel.copyName(taken: ["Redis", "redis COPY"], label: label) == "Redis copy 2")
    #expect(Tunnel.copyName(taken: ["Redis", "Redis copy", "Redis copy 2"], label: label) == "Redis copy 3")
}
