import Foundation

/// Any JSON value, used to carry top-level keys this version does not know about.
public enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

public enum LoadResult: Sendable {
    case loaded(TunnelFile)
    case missing
    case newerSchema(TunnelFile)
    case broken(backup: URL)
}

/// The on-disk envelope of `tunnels.json` (spec §8).
public struct TunnelFile: Codable, Hashable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    /// Groups the user has, used or not, in display order.
    public var groups: [String]
    public var tunnels: [Tunnel]
    public var toolPaths: [String: String]
    /// Tags the user has defined, used or not. Tags typed on a tunnel count too (`allTags`).
    public var tags: [String]
    /// Tag name → "#RRGGBB". A tag without an entry uses `LabelColor.defaultHex(for:)`.
    public var tagColors: [String: String]
    /// Group name → "#RRGGBB". A group without an entry has no colour.
    public var groupColors: [String: String]
    /// Top-level keys from a newer or foreign writer, written back unchanged.
    public var extra: [String: JSONValue]

    /// What a new install starts with.
    public static let defaultGroups = ["Production", "Staging", "Development", "Local", "Other"]
    public static let defaultGroupColors = [
        "Production": "#FF3B30", "Staging": "#FF9500", "Development": "#34C759", "Local": "#007AFF", "Other": "#8E8E93",
    ]
    public static let defaultTags = ["db", "cache", "analytics", "web", "internal", "readonly"]
    public static let defaultTagColors = [
        "db": "#007AFF", "cache": "#FF2D55", "analytics": "#AF52DE",
        "web": "#00C7BE", "internal": "#FF9500", "readonly": "#8E8E93",
    ]

    public init(
        schemaVersion: Int = TunnelFile.currentSchemaVersion,
        groups: [String] = TunnelFile.defaultGroups,
        tunnels: [Tunnel] = [], toolPaths: [String: String] = [:],
        tags: [String] = TunnelFile.defaultTags,
        tagColors: [String: String] = TunnelFile.defaultTagColors,
        groupColors: [String: String] = TunnelFile.defaultGroupColors,
        extra: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.tunnels = tunnels
        self.toolPaths = toolPaths
        self.tags = tags
        self.tagColors = tagColors
        self.groupColors = groupColors
        self.extra = extra
    }

    /// Defined tags, then any typed on a tunnel that aren't defined, without duplicates.
    public var allTags: [String] {
        var seen = Set<String>()
        return (tags + tunnels.flatMap(\.tags)).filter { seen.insert($0.lowercased()).inserted }
    }

    /// Tags at least one tunnel carries, in `allTags` order.
    public var usedTags: [String] {
        let used = Set(tunnels.flatMap(\.tags).map { $0.lowercased() })
        return allTags.filter { used.contains($0.lowercased()) }
    }

    public func tagColor(_ tag: String) -> String {
        tagColors[tag] ?? LabelColor.defaultHex(for: tag)
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let knownKeys: Set<String> = ["schemaVersion", "groups", "tunnels", "toolPaths", "tags", "tagColors", "groupColors"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        schemaVersion = try c.decode(Int.self, forKey: AnyKey("schemaVersion"))
        groups = try c.decodeIfPresent([String].self, forKey: AnyKey("groups")) ?? []
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: AnyKey("tunnels")) ?? []
        toolPaths = try c.decodeIfPresent([String: String].self, forKey: AnyKey("toolPaths")) ?? [:]
        // Files from before tags existed get the starter tags and colours.
        let hadTags = c.contains(AnyKey("tags"))
        tags = try c.decodeIfPresent([String].self, forKey: AnyKey("tags")) ?? Self.defaultTags
        tagColors = try c.decodeIfPresent([String: String].self, forKey: AnyKey("tagColors"))
            ?? (hadTags ? [:] : Self.defaultTagColors)
        let loadedGroups = groups
        groupColors = try c.decodeIfPresent([String: String].self, forKey: AnyKey("groupColors"))
            ?? Self.defaultGroupColors.filter { loadedGroups.contains($0.key) }
        var extra: [String: JSONValue] = [:]
        for key in c.allKeys where !Self.knownKeys.contains(key.stringValue) {
            extra[key.stringValue] = try c.decode(JSONValue.self, forKey: key)
        }
        self.extra = extra
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in extra { try c.encode(value, forKey: AnyKey(key)) }
        try c.encode(schemaVersion, forKey: AnyKey("schemaVersion"))
        try c.encode(groups, forKey: AnyKey("groups"))
        try c.encode(tunnels, forKey: AnyKey("tunnels"))
        try c.encode(toolPaths, forKey: AnyKey("toolPaths"))
        try c.encode(tags, forKey: AnyKey("tags"))
        try c.encode(tagColors, forKey: AnyKey("tagColors"))
        try c.encode(groupColors, forKey: AnyKey("groupColors"))
    }

    public static func load(from url: URL, now: Date) -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .missing }
        guard let file = try? JSONDecoder().decode(TunnelFile.self, from: data) else {
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).broken-\(backupStamp(now))")
            // Never overwrite what the user wrote: move it aside, even if that fails we don't save over it.
            try? FileManager.default.moveItem(at: url, to: backup)
            return .broken(backup: backup)
        }
        return file.schemaVersion > currentSchemaVersion ? .newerSchema(file) : .loaded(file)
    }

    public func save(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(self).write(to: url, options: .atomic)
    }

    private static func backupStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // Users on a Buddhist or other calendar still get a sortable Gregorian stamp.
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}
