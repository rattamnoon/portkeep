import Foundation

/// Copy Diagnostics: what a bug report needs, as Markdown to paste into a GitHub issue. Versions,
/// tool paths, and per tunnel its settings, the command it runs, its state and the end of its log.
/// Portkeep stores no secrets, so settings go in whole; the home folder is shortened to ~.
public enum Diagnostics {
    public struct Environment: Sendable {
        public var appVersion: String
        public var build: String
        public var macOS: String
        public var architecture: String
        /// Tool name → resolved path (nil when not found), and whether the user set it on the Tools page.
        public var tools: [(name: String, path: String?, custom: Bool)]
        public var toolPaths: ToolPaths

        public init(appVersion: String, build: String, macOS: String, architecture: String,
                    tools: [(name: String, path: String?, custom: Bool)], toolPaths: ToolPaths) {
            self.appVersion = appVersion
            self.build = build
            self.macOS = macOS
            self.architecture = architecture
            self.tools = tools
            self.toolPaths = toolPaths
        }
    }

    public struct Entry: Sendable {
        public var tunnel: Tunnel
        public var state: TunnelState
        public var log: [String]

        public init(tunnel: Tunnel, state: TunnelState, log: [String]) {
            self.tunnel = tunnel
            self.state = state
            self.log = log
        }
    }

    public static let logLines = 50

    /// This Mac's CPU, e.g. arm64.
    public static var machine: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    public static func markdown(_ env: Environment, tunnels: [Entry], now: Date = .now,
                                home: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        func short(_ text: String) -> String {
            home.count > 1 ? text.replacingOccurrences(of: home, with: "~") : text
        }
        var out = ["### Portkeep diagnostics", ""]
        out.append("- Portkeep: \(env.appVersion) (\(env.build))")
        out.append("- macOS: \(env.macOS), \(env.architecture)")
        out.append("- Generated: \(now.formatted(.iso8601))")
        out.append("- Tools:")
        for tool in env.tools {
            let where_ = tool.path.map { "`\(short($0))`" } ?? "not found"
            out.append("  - \(tool.name): \(where_)\(tool.custom ? " (set on the Tools page)" : "")")
        }
        for entry in tunnels {
            let t = entry.tunnel
            out += ["", "#### \(t.name)", ""]
            out.append("- Method: \(t.methodName), local port \(t.localPort)\(t.runsOnDemand ? ", on demand" : "")")
            var state = "- State: \(StatusSnapshot.stateName(entry.state))"
            switch entry.state {
            case .failed(let reason), .retrying(let reason, _, _): state += " (`\(ControlRouter.code(reason))`)"
            case .blocked(let owner): state += owner.map { " (port held by \($0.command), pid \($0.pid))" } ?? ""
            default: break
            }
            out.append(state + " — " + short(statusLine(entry.state, tunnel: t, now: now)))
            if let invocation = try? CommandBuilder.invocation(for: t, tools: env.toolPaths) {
                let command = ([invocation.executable.path] + invocation.arguments).map { $0.contains(" ") ? "'\($0)'" : $0 }
                out.append("- Runs: `\(short(command.joined(separator: " ")))`")
            }
            var settings = (try? JSONValue(encoding: t))?.objectValue ?? [:]
            settings["id"] = nil
            out += ["", "<details><summary>Settings</summary>", "", "````json", short(JSONValue.object(settings).prettyText()), "````", "", "</details>"]
            let log = entry.log.suffix(logLines)
            out += ["", "<details><summary>Log (last \(log.count) lines)</summary>", "", "````"]
            out += log.isEmpty ? ["(empty)"] : log.map(short)
            out += ["````", "", "</details>"]
        }
        if tunnels.isEmpty { out += ["", "No tunnels."] }
        out += ["", "<!-- Check hostnames and account ids before posting. -->", ""]
        return out.joined(separator: "\n")
    }
}
