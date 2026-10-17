import Foundation

/// `status.json` beside `tunnels.json`: what is running right now, for the `portkeep` command line
/// tool. Rewritten whenever a state changes; nothing reads it back into the app.
public struct StatusSnapshot: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var id: UUID
        public var name: String
        public var group: String
        public var port: Int
        /// One word for scripts: off, connecting, connected, standing-by, reconnecting, blocked, failed.
        public var state: String
        /// The status line shown in the menu, in the app's language, as of the last change.
        public var status: String
        /// When it connected, while connected; the status line's duration goes stale in a file.
        public var connectedSince: Date?

        public init(id: UUID, name: String, group: String, port: Int, state: String, status: String, connectedSince: Date? = nil) {
            self.id = id
            self.name = name
            self.group = group
            self.port = port
            self.state = state
            self.status = status
            self.connectedSince = connectedSince
        }
    }

    /// The app's process, so a reader can tell a file left by a crash from a live one.
    public var pid: Int32
    public var running: Bool
    public var tunnels: [Entry]

    public init(pid: Int32, running: Bool, tunnels: [Entry]) {
        self.pid = pid
        self.running = running
        self.tunnels = tunnels
    }

    public static func stateName(_ state: TunnelState) -> String {
        switch state {
        case .off: "off"
        case .checking, .starting: "connecting"
        case .connected: "connected"
        case .standingBy: "standing-by"
        case .retrying: "reconnecting"
        case .blocked: "blocked"
        case .failed: "failed"
        }
    }

    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
