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
    #expect(file.tagColors == [:])
    #expect(file.groupColors == [:])
}

@Test func tagsAndColoursRoundTrip() throws {
    let file = TunnelFile(
        tunnels: [Tunnel(name: "ch", group: "TH", localPort: 8123, method: .custom(CustomConfig(command: "x")), tags: ["db", "olap"])],
        tagColors: ["db": "#112233"], groupColors: ["TH": "#AABBCC"])
    let again = try JSONDecoder().decode(TunnelFile.self, from: JSONEncoder().encode(file))
    #expect(again == file)
    #expect(again.tagColor("db") == "#112233")
    #expect(again.tagColor("olap") == LabelColor.defaultHex(for: "olap"))
    #expect(again.allTags == ["db", "olap"])
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
