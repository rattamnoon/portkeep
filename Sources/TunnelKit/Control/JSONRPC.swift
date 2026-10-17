import Foundation

/// A JSON-RPC 2.0 request or notification (no `id`), one per line on the control socket and on the
/// MCP server's stdin.
public struct RPCRequest: Codable, Sendable {
    public var jsonrpc: String
    public var id: JSONValue?
    public var method: String
    public var params: JSONValue?

    public init(id: JSONValue?, method: String, params: JSONValue? = nil) {
        jsonrpc = "2.0"
        self.id = id
        self.method = method
        self.params = params
    }
}

/// A JSON-RPC error. `message` is a sentence a person (or an agent) can act on.
public struct RPCError: Error, Codable, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?

    public init(_ code: Int, _ message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    // Standard codes.
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    // Portkeep's own.
    /// No tunnel, group or tag by that name.
    public static let notFound = -32001
    /// A field is missing or has a bad value; `data.field` names it.
    public static let validationFailed = -32002
    /// Clashes with what is already there (a name taken, two tunnels with one name).
    public static let conflict = -32003
    /// tunnels.json was written by a newer Portkeep, so nothing is saved.
    public static let readOnly = -32004
    /// Portkeep isn't running and couldn't be started (command line tool only).
    public static let unavailable = -32005

    public static func invalid(_ message: String, field: String? = nil) -> RPCError {
        RPCError(validationFailed, message, data: field.map { .object(["field": .string($0)]) })
    }
}

/// A response to a request, either `result` or `error`.
public struct RPCResponse: Codable, Sendable {
    public var id: JSONValue
    public var result: JSONValue?
    public var error: RPCError?

    public init(id: JSONValue, result: JSONValue) {
        self.id = id
        self.result = result
    }

    public init(id: JSONValue, error: RPCError) {
        self.id = id
        self.error = error
    }

    private enum CodingKeys: String, CodingKey { case jsonrpc, id, result, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(JSONValue.self, forKey: .id) ?? .null
        result = try c.decodeIfPresent(JSONValue.self, forKey: .result)
        error = try c.decodeIfPresent(RPCError.self, forKey: .error)
        // `"result": null` is a result, not a missing one.
        if result == nil, error == nil, c.contains(.result) { result = .null }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode("2.0", forKey: .jsonrpc)
        try c.encode(id, forKey: .id)
        if let error { try c.encode(error, forKey: .error) } else { try c.encode(result ?? .null, forKey: .result) }
    }

    /// One line of JSON, without the newline.
    public func line() -> Data { JSONValue.lineEncoder.encodeOrEmpty(self) }
}

// MARK: JSONValue helpers

extension JSONValue {
    /// Compact, sorted, `/` unescaped: what goes on the wire.
    static let lineEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let prettyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Any Encodable as a JSON value (dates as ISO 8601).
    public init(encoding value: some Encodable) throws {
        let data = try Self.lineEncoder.encode(value)
        self = try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Decodes this value as `T` (dates as ISO 8601).
    public func decode<T: Decodable>(as type: T.Type) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: Self.lineEncoder.encode(self))
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    public var intValue: Int? {
        if case .number(let v) = self, v == v.rounded(), abs(v) < 1e15 { return Int(v) }
        return nil
    }

    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public static func int(_ value: Int) -> JSONValue { .number(Double(value)) }

    /// Pretty-printed text, for people.
    public func prettyText() -> String {
        String(decoding: Self.prettyEncoder.encodeOrEmpty(self), as: UTF8.self)
    }

    /// One line of JSON.
    public func lineText() -> String {
        String(decoding: Self.lineEncoder.encodeOrEmpty(self), as: UTF8.self)
    }

    /// RFC 7396 merge patch: objects merge key by key, `null` removes a key, anything else replaces.
    /// A key in `unions` names a one-key object such as `method` (`{"ssh": …}`): a patch naming a
    /// different key replaces the whole object instead of adding a second key.
    public func merging(_ patch: JSONValue, unions: Set<String> = [], path: String = "") -> JSONValue {
        guard case .object(let patchObject) = patch else { return patch }
        guard case .object(var base) = self else {
            return JSONValue.object([:]).merging(patch, unions: unions, path: path)
        }
        if unions.contains(path), !Set(patchObject.keys).isSubset(of: base.keys) {
            return JSONValue.object([:]).merging(patch, unions: unions.subtracting([path]), path: path)
        }
        for (key, value) in patchObject {
            let child = path.isEmpty ? key : "\(path).\(key)"
            if value == .null {
                base[key] = nil
            } else {
                base[key] = (base[key] ?? .object([:])).merging(value, unions: unions, path: child)
            }
        }
        return .object(base)
    }
}

extension JSONEncoder {
    func encodeOrEmpty(_ value: some Encodable) -> Data {
        (try? encode(value)) ?? Data("{}".utf8)
    }
}
