import Darwin
import Foundation

public enum SSHConfigParser {
    /// Concrete `Host` aliases, in file order; patterns (`*`, `?`, `!`) are skipped. `Include` is not followed.
    public static func hosts(in text: String) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let keyword = words.first, keyword.lowercased() == "host" else { continue }
            for name in words.dropFirst() where !isPattern(name) {
                let alias = String(name)
                if !result.contains(alias) { result.append(alias) }
            }
        }
        return result
    }

    private static func isPattern<S: StringProtocol>(_ name: S) -> Bool {
        name.contains(where: { "*?!".contains($0) })
    }

    // MARK: Forwards

    /// `LocalForward` and `DynamicForward` lines of `~/.ssh/config` (or `file`), following `Include`.
    public static func forwards(fromFile file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config")) -> [SSHConfigForward] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        let sshDirectory = file.deletingLastPathComponent()
        return forwards(in: text) { pattern in
            includedFiles(pattern, sshDirectory: sshDirectory).compactMap { try? String(contentsOfFile: $0, encoding: .utf8) }
        }
    }

    /// Forwards under concrete `Host` aliases, in file order. Wildcard hosts and `Match` blocks are
    /// skipped. `include` returns the text of each file an `Include` pattern names.
    public static func forwards(in text: String, include: (String) -> [String]) -> [SSHConfigForward] {
        var found: [SSHConfigForward] = []
        var hosts: [String] = []
        collect(text, hosts: &hosts, into: &found, include: include, depth: 0)
        // How many forwards each host has: ssh opens all of them, whichever one is asked for.
        var counts: [String: Int] = [:]
        for forward in found { counts[forward.host, default: 0] += 1 }
        return found.map {
            var forward = $0
            forward.forwardsOnHost = counts[forward.host] ?? 1
            return forward
        }
    }

    private static func collect(_ text: String, hosts: inout [String], into found: inout [SSHConfigForward],
                                include: (String) -> [String], depth: Int) {
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (keyword, args) = directive(line) else { continue }
            switch keyword {
            case "host":
                hosts = args.filter { !isPattern($0) }
            case "match":
                hosts = []
            case "include":
                // ssh's own limit, and a guard against a file including itself.
                guard depth < 16 else { continue }
                for pattern in args {
                    for included in include(pattern) {
                        collect(included, hosts: &hosts, into: &found, include: include, depth: depth + 1)
                    }
                }
            case "localforward":
                guard args.count >= 2, let port = listenPort(args[0]), let destination = endpoint(args[1]) else { continue }
                for host in hosts {
                    found.append(SSHConfigForward(host: host, mode: .local, localPort: port, destination: destination))
                }
            case "dynamicforward":
                guard let first = args.first, let port = listenPort(first) else { continue }
                for host in hosts {
                    found.append(SSHConfigForward(host: host, mode: .dynamic, localPort: port, destination: nil))
                }
            default:
                continue
            }
        }
    }

    /// `Keyword value…` or `Keyword=value…`, lowercased keyword; nil for blanks and comments.
    static func directive<S: StringProtocol>(_ line: S) -> (String, [String])? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
        guard let end = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            return (trimmed.lowercased(), [])
        }
        var rest = trimmed[end...].drop(while: { $0 == " " || $0 == "\t" })
        if rest.first == "=" { rest = rest.dropFirst() }
        return (trimmed[..<end].lowercased(), CommandBuilder.shellSplit(String(rest)))
    }

    /// The port of `[bind:]port`, `[::1]:port` or `bind/port`; nil for a Unix socket path.
    static func listenPort(_ text: String) -> Int? {
        if text.hasPrefix("/") { return nil }
        let portText: Substring
        if text.hasPrefix("["), let close = text.range(of: "]:") {
            portText = text[close.upperBound...]
        } else if let slash = text.lastIndex(of: "/") {
            portText = text[text.index(after: slash)...]
        } else {
            portText = text.split(separator: ":", omittingEmptySubsequences: false).last ?? ""
        }
        guard let port = Int(portText), (1...65535).contains(port) else { return nil }
        return port
    }

    /// `host:port`, `[v6]:port` (brackets kept, as `-L` needs them) or `host/port`.
    static func endpoint(_ text: String) -> Endpoint? {
        let host: Substring, portText: Substring
        if text.hasPrefix("["), let close = text.range(of: "]:") {
            host = text[..<close.lowerBound].dropFirst()
            portText = text[close.upperBound...]
            guard let port = Int(portText), (1...65535).contains(port), !host.isEmpty else { return nil }
            return Endpoint(host: "[\(host)]", port: port)
        }
        guard let separator = text.lastIndex(where: { $0 == ":" || $0 == "/" }) else { return nil }
        host = text[..<separator]
        portText = text[text.index(after: separator)...]
        guard let port = Int(portText), (1...65535).contains(port), !host.isEmpty else { return nil }
        return Endpoint(host: String(host), port: port)
    }

    /// Paths an `Include` pattern names, sorted: `~` expanded, relative ones under `sshDirectory`, globs matched.
    public static func includedFiles(_ pattern: String, sshDirectory: URL) -> [String] {
        var path = (pattern as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = sshDirectory.appendingPathComponent(path).path }
        var matches = glob_t()
        defer { globfree(&matches) }
        guard glob(path, 0, nil, &matches) == 0 else { return [] }
        return (0..<Int(matches.gl_pathc)).compactMap { matches.gl_pathv[$0].map { String(cString: $0) } }.sorted()
    }
}

/// One `LocalForward` or `DynamicForward` from ~/.ssh/config, offered as a tunnel to add.
public struct SSHConfigForward: Hashable, Sendable, Identifiable {
    public var host: String
    public var mode: SSHMode
    public var localPort: Int
    public var destination: Endpoint?
    /// Forwards the host's blocks have in all, this one included.
    public var forwardsOnHost = 1

    public var id: String { "\(host)|\(localPort)|\(destination.map { "\($0.host):\($0.port)" } ?? "socks")" }

    public init(host: String, mode: SSHMode, localPort: Int, destination: Endpoint?) {
        self.host = host
        self.mode = mode
        self.localPort = localPort
        self.destination = destination
    }

    /// "<alias> <port>", e.g. "bastion 5432".
    public var name: String { "\(host) \(localPort)" }

    public func tunnel(group: String) -> Tunnel {
        Tunnel(name: name, group: group, localPort: localPort,
               method: .ssh(SSHConfig(mode: mode, host: host, destination: destination)))
    }

    /// Whether `tunnel` already opens this forward.
    public func matches(_ tunnel: Tunnel) -> Bool {
        guard case .ssh(let c) = tunnel.method else { return false }
        return c.host == host && c.mode == mode && tunnel.localPort == localPort && c.destination == destination
    }
}
