import Darwin
import Foundation
import TunnelKit

// portkeep: Portkeep from the terminal, and an MCP server for AI assistants. Ships inside
// Portkeep.app (Contents/Resources/bin) and is linked onto PATH by Settings › General › Install
// Command Line Tool… or Homebrew.
//
// Everything goes to the running app over control.sock in its data folder (launching it when
// needed), so tunnels.json is only ever written by the app. `list` and `status` without --json
// read status.json instead, as they always have, and never start the app.

let me = "portkeep"

let usage = """
    Usage: \(me) <command> [arguments] [--json]

    Tunnels
      list [--group G] [--tag T]    every tunnel: name, group, port and status
      status [<name>]               one tunnel's status; exits 0 when connected
      get <name>                    one tunnel's settings and state (JSON)
      start|stop|toggle <name>      add --wait [seconds] to wait until it connects or fails
      start-group|stop-group <group>
      start-all|stop-all
      test <name>                   connect once and stop, like Test Connection
      test --config '<tunnel json>' test settings without saving them
      logs <name> [-n 50]           the last lines the tunnel's command printed

    Changes
      add --json '<tunnel json>'    also -f file.json, or the JSON on stdin; add --start to switch it on
      edit <name> --json '<patch>'  only the fields to change, e.g. '{"localPort": 3307}'
      remove <name> [--yes]
      duplicate <name> [--name N]
      add-group <name> [--color #RRGGBB]
      add-tag <name> [--color #RRGGBB]

    Reference
      methods [<method>]            each connection method's fields, defaults and an example
      discover                      SSH hosts, AWS profiles, kube contexts and tools on this Mac
      groups, tags
      open [<name>]                 open Portkeep's Settings
      mcp                           run an MCP server on stdin/stdout for AI assistants
      version

    --json prints JSON on every read command. Names and groups match ignoring case; a tunnel's id
    works too. Commands that change something start Portkeep in the background if it isn't running.
    """

struct UsageError: Error {
    var message: String
}

/// Arguments split into positionals and the options this tool knows.
struct Arguments {
    var command: String
    var positionals: [String] = []
    var json = false
    var input: String?
    var file: String?
    var lines: Int?
    var yes = false
    var wait: Double?
    var color: String?
    var name: String?
    var config: String?
    var group: String?
    var tag: String?
    var start = false

    init(_ raw: [String]) throws(UsageError) {
        command = raw.first ?? "help"
        var rest = raw.dropFirst()
        // add and edit take their input after --json; everywhere else it is a switch.
        let jsonTakesInput = command == "add" || command == "edit"
        func value(_ flag: String) throws(UsageError) -> String {
            guard let next = rest.popFirst() else { throw UsageError(message: "\(flag) needs a value.") }
            return next
        }
        while let arg = rest.popFirst() {
            switch arg {
            case "--json":
                json = true
                if jsonTakesInput, let next = rest.first, !next.hasPrefix("-") || next == "-" {
                    input = rest.popFirst()
                }
            case "-f", "--file": file = try value(arg)
            case "-n", "--lines":
                guard let n = Int(try value(arg)) else { throw UsageError(message: "\(arg) needs a number.") }
                lines = n
            case "-y", "--yes": yes = true
            case "--wait":
                if let next = rest.first, let seconds = Double(next) {
                    rest.removeFirst()
                    wait = seconds
                } else {
                    wait = 15
                }
            case "--color": color = try value(arg)
            case "--name": name = try value(arg)
            case "--config": config = try value(arg)
            case "--group": group = try value(arg)
            case "--tag": tag = try value(arg)
            case "--start": start = true
            case "-h", "--help": command = "help"
            default:
                if arg.hasPrefix("-"), arg.count > 1, Double(arg) == nil {
                    throw UsageError(message: "unknown option \(arg).")
                }
                positionals.append(arg)
            }
        }
    }

    func first(_ what: String) throws(UsageError) -> String {
        guard let value = positionals.first, !value.isEmpty else { throw UsageError(message: "\(command) needs a \(what).") }
        return value
    }
}

// MARK: Output

func printJSON(_ value: JSONValue) {
    print(value.prettyText())
}

func warn(_ text: String) {
    FileHandle.standardError.write(Data("\(me): \(text)\n".utf8))
}

/// Rows as aligned columns under a header, as `list` has always printed them.
func printTable(_ header: [String], _ rows: [[String]], rightAligned: Set<Int> = []) {
    var widths = header.map(\.count)
    for row in rows { for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) } }
    for row in [header] + rows {
        let cells = row.enumerated().map { i, cell in
            let pad = String(repeating: " ", count: max(0, widths[i] - cell.count))
            return i == row.count - 1 ? cell : rightAligned.contains(i) ? pad + cell : cell + pad
        }
        print(cells.joined(separator: "  "))
    }
}

/// The old zsh tool's `list` columns: name, group, port, state, detail.
func printStatusTable(_ entries: [StatusSnapshot.Entry], alive: Bool) {
    let rows = entries.map { t -> [String] in
        var detail = alive ? t.status : "Portkeep isn't running"
        if alive, let since = t.connectedSince {
            detail = "since " + since.formatted(date: .omitted, time: .shortened)
        }
        return [t.name, t.group, String(t.port), alive ? t.state : "off", detail]
    }
    // The zsh tool padded NAME and GROUP to at least 4 and 5, PORT to 5 and STATE to 12.
    var name = 4, group = 5
    for row in rows { name = max(name, row[0].count); group = max(group, row[1].count) }
    func line(_ f: [String]) -> String {
        f[0].padding(toLength: name, withPad: " ", startingAt: 0) + "  "
            + f[1].padding(toLength: group, withPad: " ", startingAt: 0) + "  "
            + String(repeating: " ", count: max(0, 5 - f[2].count)) + f[2] + "  "
            + f[3].padding(toLength: max(12, f[3].count), withPad: " ", startingAt: 0) + "  " + f[4]
    }
    print(line(["NAME", "GROUP", "PORT", "STATE", "DETAIL"]))
    for row in rows { print(line(row)) }
}

func printTunnelStates(_ result: JSONValue) {
    let tunnels = result["tunnels"]?.arrayValue ?? []
    printTable(["NAME", "PORT", "STATE", "STATUS"], tunnels.map { t in
        [t["name"]?.stringValue ?? "", t["localPort"]?.intValue.map(String.init) ?? "",
         t["state"]?.stringValue ?? "", t["status"]?.stringValue ?? ""]
    }, rightAligned: [1])
    for t in tunnels {
        if let hint = t["hint"]?.stringValue { print("\(t["name"]?.stringValue ?? ""): \(hint)") }
    }
}

// MARK: Input

func readInput(_ args: Arguments, what: String) throws(UsageError) -> JSONValue {
    var text: String?
    if let input = args.input, input != "-" {
        text = input
    } else if let file = args.file, file != "-" {
        guard let data = FileManager.default.contents(atPath: (file as NSString).expandingTildeInPath) else {
            throw UsageError(message: "can’t read \(file).")
        }
        text = String(decoding: data, as: UTF8.self)
    } else if args.input == "-" || args.file == "-" || isatty(STDIN_FILENO) == 0 {
        text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }
    guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw UsageError(message: "\(args.command) needs \(what) as JSON: --json '<json>', -f file.json, or on stdin.")
    }
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) else {
        throw UsageError(message: "that isn’t valid JSON.")
    }
    return value
}

func confirm(_ question: String) -> Bool {
    FileHandle.standardError.write(Data("\(question) [y/N] ".utf8))
    guard let answer = readLine() else { return false }
    return ["y", "yes"].contains(answer.trimmingCharacters(in: .whitespaces).lowercased())
}

// MARK: Commands

/// The exit status: 0 done, 1 failed or not connected, 2 some of several connected, 64 bad usage.
func run(_ args: Arguments) throws -> Int32 {
    let app = Connection()
    let c = args.command

    switch c {
    case "help":
        print(usage)
        return 0

    case "version", "--version", "-v":
        print("\(me) \(Connection.version)")
        return 0

    case "list", "ls":
        if args.json || args.group != nil || args.tag != nil {
            var params: [String: JSONValue] = [:]
            if let group = args.group { params["group"] = .string(group) }
            if let tag = args.tag { params["tag"] = .string(tag) }
            let result = try app.call("tunnels.list", .object(params))
            if args.json { printJSON(result) } else { printTunnelStates(result) }
            return 0
        }
        guard let snapshot = StatusFile.read(in: app.dataDirectory) else {
            warn("no status yet; open Portkeep first.")
            return 1
        }
        if snapshot.tunnels.isEmpty { print("No tunnels yet."); return 0 }
        printStatusTable(snapshot.tunnels, alive: snapshot.running && StatusFile.isAlive(snapshot.pid))
        return 0

    case "status":
        if args.json {
            if let name = args.positionals.first {
                let tunnel = try app.call("tunnels.get", .object(["tunnel": .string(name)]))
                printJSON(tunnel)
                return tunnel["state"] == .string("connected") ? 0 : 1
            }
            printJSON(try app.call("status"))
            return 0
        }
        guard let name = args.positionals.first else { return try run(Arguments(["list"])) }
        guard let snapshot = StatusFile.read(in: app.dataDirectory) else {
            warn("no status yet; open Portkeep first.")
            return 1
        }
        let alive = snapshot.running && StatusFile.isAlive(snapshot.pid)
        let matches = snapshot.tunnels.filter {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id.uuidString.caseInsensitiveCompare(name) == .orderedSame
        }
        if matches.isEmpty { warn("no tunnel named \"\(name)\"."); return 1 }
        printStatusTable(matches, alive: alive)
        // For scripts: 0 when connected, 1 when not, 2 when only some of several with this name are.
        let connected = matches.filter { alive && $0.state == "connected" }.count
        return connected == 0 ? 1 : connected == matches.count ? 0 : 2

    case "get":
        printJSON(try app.call("tunnels.get", .object(["tunnel": .string(try args.first("tunnel name"))])))
        return 0

    case "start", "stop", "toggle", "start-group", "stop-group", "start-all", "stop-all":
        let action = c.split(separator: "-").first.map(String.init) ?? c
        var params: [String: JSONValue] = ["wait": .number(args.wait ?? 0)]
        if c.hasSuffix("-all") {
            params["all"] = .bool(true)
        } else if c.hasSuffix("-group") {
            params["group"] = .string(try args.first("group name"))
        } else {
            params["tunnel"] = .string(try args.first("tunnel name"))
        }
        let result = try app.call("tunnels.\(action)", .object(params))
        if args.json { printJSON(result) } else if args.wait != nil { printTunnelStates(result) }
        guard args.wait != nil, action != "stop" else { return 0 }
        let states = (result["tunnels"]?.arrayValue ?? []).compactMap { $0["state"]?.stringValue }
        return states.allSatisfy { $0 == "connected" || $0 == "standing-by" || $0 == "off" } ? 0 : 1

    case "add":
        var params: [String: JSONValue] = ["tunnel": try readInput(args, what: "a tunnel")]
        if args.start { params["start"] = .bool(true); params["wait"] = .number(args.wait ?? 15) }
        let result = try app.call("tunnels.add", .object(params))
        for warning in result["warnings"]?.arrayValue ?? [] { warn("warning: \(warning.stringValue ?? "")") }
        printJSON(result)
        return 0

    case "edit":
        let name = try args.first("tunnel name")
        let result = try app.call("tunnels.update", .object(["tunnel": .string(name), "patch": try readInput(args, what: "the fields to change")]))
        for warning in result["warnings"]?.arrayValue ?? [] { warn("warning: \(warning.stringValue ?? "")") }
        printJSON(result)
        return 0

    case "remove", "rm":
        let name = try args.first("tunnel name")
        if !args.yes {
            guard isatty(STDIN_FILENO) != 0 else {
                throw UsageError(message: "remove deletes \"\(name)\" for good; add --yes to confirm.")
            }
            let tunnel = try app.call("tunnels.get", .object(["tunnel": .string(name)]))
            guard confirm("Remove \"\(tunnel["name"]?.stringValue ?? name)\"? It can’t be undone.") else { return 1 }
        }
        let result = try app.call("tunnels.remove", .object(["tunnel": .string(name)]))
        if args.json { printJSON(result) } else { print("Removed \"\(result["removed"]?["name"]?.stringValue ?? name)\".") }
        return 0

    case "duplicate":
        var params: [String: JSONValue] = ["tunnel": .string(try args.first("tunnel name"))]
        if let name = args.name { params["name"] = .string(name) }
        printJSON(try app.call("tunnels.duplicate", .object(params)))
        return 0

    case "test":
        var params: [String: JSONValue] = [:]
        if let config = args.config {
            guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(config.utf8)) else {
                throw UsageError(message: "--config isn’t valid JSON.")
            }
            params["config"] = value
        } else {
            params["tunnel"] = .string(try args.first("tunnel name"))
        }
        let result = try app.call("tunnels.test", .object(params))
        if args.json {
            printJSON(result)
        } else {
            print(result["status"]?.stringValue ?? "")
            if let hint = result["hint"]?.stringValue { print(hint) }
            let log = result["log"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !log.isEmpty, result["ok"] != .bool(true) {
                print("--- log")
                log.suffix(15).forEach { print($0) }
            }
        }
        return result["ok"] == .bool(true) ? 0 : 1

    case "logs", "log":
        let result = try app.call("tunnels.logs", .object([
            "tunnel": .string(try args.first("tunnel name")), "lines": .int(args.lines ?? 50),
        ]))
        if args.json { printJSON(result) } else { result["lines"]?.arrayValue?.forEach { print($0.stringValue ?? "") } }
        return 0

    case "methods":
        var params: [String: JSONValue] = [:]
        if let method = args.positionals.first { params["method"] = .string(method) }
        let result = try app.call("methods.describe", .object(params))
        if args.json { printJSON(result); return 0 }
        func describe(_ field: JSONValue, indent: String) {
            var facts = [field["type"]?.stringValue ?? ""]
            if field["required"] == .bool(true) { facts.append("required") }
            if let d = field["default"] { facts.append("default \(d.lineText())") }
            if let choices = field["enum"]?.arrayValue { facts.append(choices.compactMap(\.stringValue).joined(separator: "|")) }
            print("\(indent)\(field["name"]?.stringValue ?? "") (\(facts.joined(separator: ", "))): \(field["description"]?.stringValue ?? "")")
            for sub in field["fields"]?.arrayValue ?? [] { describe(sub, indent: indent + "  ") }
        }
        if params.isEmpty {
            print("Every tunnel:")
            result["tunnelFields"]?.arrayValue?.forEach { describe($0, indent: "  ") }
        }
        for method in result["methods"]?.arrayValue ?? [] {
            print("\nmethod.\(method["key"]?.stringValue ?? "") — \(method["title"]?.stringValue ?? "")")
            print("  \(method["summary"]?.stringValue ?? "")")
            print("  Runs: \(method["runs"]?.stringValue ?? "")")
            method["fields"]?.arrayValue?.forEach { describe($0, indent: "  ") }
            print("  Example: \(method["example"]?.lineText() ?? "")")
        }
        return 0

    case "discover":
        let result = try app.call("discover")
        if args.json { printJSON(result); return 0 }
        func strings(_ key: String) -> String {
            let items = result[key]?.arrayValue?.compactMap(\.stringValue) ?? []
            return items.isEmpty ? "(none)" : items.joined(separator: ", ")
        }
        print("SSH hosts: \(strings("sshHosts"))")
        let profiles = result["awsProfiles"]?.arrayValue?.map { p in
            (p["name"]?.stringValue ?? "") + (p["region"]?.stringValue.map { " (\($0))" } ?? "")
        } ?? []
        print("AWS profiles: \(profiles.isEmpty ? "(none)" : profiles.joined(separator: ", "))")
        print("Kube contexts: \(strings("kubeContexts"))")
        let tools = result["tools"]?.objectValue?.keys.sorted() ?? []
        print("Tools: \(tools.isEmpty ? "(none)" : tools.joined(separator: ", "))")
        for (tool, hint) in (result["missingTools"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            print("Missing: \(tool) (\(hint.stringValue ?? ""))")
        }
        let ports = result["tunnelPorts"]?.arrayValue?.map { "\($0["port"]?.intValue ?? 0) \($0["name"]?.stringValue ?? "")" } ?? []
        print("Ports in use by tunnels: \(ports.isEmpty ? "(none)" : ports.joined(separator: ", "))")
        return 0

    case "groups", "tags":
        let result = try app.call("\(c).list")
        if args.json { printJSON(result); return 0 }
        printTable(["NAME", "COLOR", "TUNNELS"], (result[c]?.arrayValue ?? []).map { item in
            [item["name"]?.stringValue ?? "", item["color"]?.stringValue ?? "", String(item["tunnels"]?.intValue ?? 0)]
        })
        return 0

    case "add-group", "add-tag":
        var params: [String: JSONValue] = ["name": .string(try args.first("name"))]
        if let color = args.color { params["color"] = .string(color) }
        let result = try app.call(c == "add-group" ? "groups.add" : "tags.add", .object(params))
        if args.json { printJSON(result) } else { print("Added \(c == "add-group" ? "group" : "tag") \(result["name"]?.stringValue ?? "") \(result["color"]?.stringValue ?? "")") }
        return 0

    case "open":
        var url = "portkeep://open"
        if let name = args.positionals.first {
            _ = try app.call("tunnels.get", .object(["tunnel": .string(name)]))
            url += "?name=" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url]
        try open.run()
        open.waitUntilExit()
        return open.terminationStatus

    case "mcp":
        return serveMCP(app)

    default:
        throw UsageError(message: "unknown command \"\(c)\".")
    }
}

/// `portkeep mcp`: one JSON-RPC message per line on stdin, answers on stdout, anything else on stderr.
func serveMCP(_ app: Connection) -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let server = MCPServer(version: Connection.version) { method, params throws(RPCError) in
        try app.call(method, params)
    }
    warn("MCP server ready on stdio (data folder \(app.dataDirectory.path)).")
    while let line = readLine(strippingNewline: true) {
        if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        if let reply = server.handle(line) {
            print(reply)
            fflush(stdout)
        }
    }
    return 0
}

// MARK: Main

signal(SIGPIPE, SIG_IGN)
do {
    let args = try Arguments(Array(CommandLine.arguments.dropFirst()))
    exit(try run(args))
} catch let error as UsageError {
    warn(error.message)
    FileHandle.standardError.write(Data("Run \(me) help for the commands.\n".utf8))
    exit(64)
} catch let error as RPCError {
    warn(error.message)
    exit(1)
} catch {
    warn("\(error)")
    exit(1)
}
