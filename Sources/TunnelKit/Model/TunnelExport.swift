import Foundation

/// The file Export Tunnels… writes and Import Tunnels… reads: tunnels, groups, tags and colours,
/// without tool paths or anything about what is running. Import also takes a whole tunnels.json.
public struct TunnelExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var portkeepExport: Int
    public var groups: [String]
    public var tags: [String]
    public var groupColors: [String: String]
    public var tagColors: [String: String]
    public var tunnels: [Tunnel]

    public init(_ file: TunnelFile) {
        portkeepExport = Self.currentVersion
        groups = file.groups
        tags = file.tags
        groupColors = file.groupColors
        tagColors = file.tagColors
        tunnels = file.tunnels
    }

    private enum CodingKeys: String, CodingKey { case portkeepExport, groups, tags, groupColors, tagColors, tunnels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        portkeepExport = try c.decodeIfPresent(Int.self, forKey: .portkeepExport) ?? Self.currentVersion
        groups = try c.decodeIfPresent([String].self, forKey: .groups) ?? []
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        groupColors = try c.decodeIfPresent([String: String].self, forKey: .groupColors) ?? [:]
        tagColors = try c.decodeIfPresent([String: String].self, forKey: .tagColors) ?? [:]
        // Required: anything without it isn't ours.
        tunnels = try c.decode([Tunnel].self, forKey: .tunnels)
    }

    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct ImportSummary: Equatable, Sendable {
    public var imported: Int
    public var skipped: Int
}

extension Tunnel {
    /// Same settings, whatever the id.
    public func sameSettings(as other: Tunnel) -> Bool {
        var copy = self
        copy.id = other.id
        return copy == other
    }
}

extension TunnelFile {
    /// Adds the export's tunnels under new ids, skipping any with the same settings as one already
    /// here, and the groups and tags it has that this file doesn't (with their colours).
    /// Returns what was added.
    public mutating func merge(_ export: TunnelExport) -> (summary: ImportSummary, added: [Tunnel]) {
        var added: [Tunnel] = []
        var skipped = 0
        for tunnel in export.tunnels {
            if tunnels.contains(where: { $0.sameSettings(as: tunnel) }) {
                skipped += 1
                continue
            }
            let copy = tunnel.duplicate(named: tunnel.name)
            tunnels.append(copy)
            added.append(copy)
        }
        for group in export.groups + added.map(\.group) where !groups.contains(group) {
            groups.append(group)
        }
        for (group, hex) in export.groupColors where groupColors[group] == nil && groups.contains(group) {
            groupColors[group] = hex
        }
        for tag in export.tags where !tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
            tags.append(tag)
        }
        for (tag, hex) in export.tagColors where tagColors[tag] == nil && allTags.contains(tag) {
            tagColors[tag] = hex
        }
        return (ImportSummary(imported: added.count, skipped: skipped), added)
    }
}
