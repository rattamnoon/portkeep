import Foundation

/// What a `portkeep://` URL asks for, from the `portkeep` command line tool or anything else:
///
///     portkeep://start?name=Orders%20MySQL   (a name or an id; names match ignoring case)
///     portkeep://stop?group=Production
///     portkeep://toggle?all
///     portkeep://open                        (Settings; ?name= selects that tunnel)
public enum RemoteCommand: Equatable, Sendable {
    public enum Action: String, Sendable {
        case start, stop, toggle
    }

    public enum Target: Equatable, Sendable {
        case tunnel(String)
        case group(String)
        case all
    }

    case run(Action, Target)
    case openSettings(tunnel: String?)

    public static let scheme = "portkeep"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let verb = components.host?.lowercased() else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }

        if verb == "open" {
            self = .openSettings(tunnel: query["name"].flatMap { $0.isEmpty ? nil : $0 })
            return
        }
        guard let action = Action(rawValue: verb) else { return nil }
        if let name = query["name"], !name.isEmpty {
            self = .run(action, .tunnel(name))
        } else if let group = query["group"], !group.isEmpty {
            self = .run(action, .group(group))
        } else if query["all"] != nil {
            self = .run(action, .all)
        } else {
            return nil
        }
    }
}

extension RemoteCommand.Target {
    /// The tunnels this names, in list order. A tunnel name or id, a group name; names ignore case.
    public func tunnels(in tunnels: [Tunnel]) -> [Tunnel] {
        switch self {
        case .all:
            return tunnels
        case .group(let group):
            return tunnels.filter { $0.group.caseInsensitiveCompare(group) == .orderedSame }
        case .tunnel(let name):
            if let id = UUID(uuidString: name), let match = tunnels.first(where: { $0.id == id }) { return [match] }
            return tunnels.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }
}
