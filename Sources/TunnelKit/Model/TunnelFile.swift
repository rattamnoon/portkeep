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
    public var groups: [String]
    public var tunnels: [Tunnel]
    public var toolPaths: [String: String]
    /// Top-level keys from a newer or foreign writer, written back unchanged.
    public var extra: [String: JSONValue]

    public init(
        schemaVersion: Int = TunnelFile.currentSchemaVersion,
        groups: [String] = ["UAT", "Production", "Other"],
        tunnels: [Tunnel] = [], toolPaths: [String: String] = [:], extra: [String: JSONValue] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.groups = groups
        self.tunnels = tunnels
        self.toolPaths = toolPaths
        self.extra = extra
    }

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private static let knownKeys: Set<String> = ["schemaVersion", "groups", "tunnels", "toolPaths"]

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        schemaVersion = try c.decode(Int.self, forKey: AnyKey("schemaVersion"))
        groups = try c.decodeIfPresent([String].self, forKey: AnyKey("groups")) ?? []
        tunnels = try c.decodeIfPresent([Tunnel].self, forKey: AnyKey("tunnels")) ?? []
        toolPaths = try c.decodeIfPresent([String: String].self, forKey: AnyKey("toolPaths")) ?? [:]
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
