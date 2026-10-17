import Darwin
import Foundation
import TunnelKit

/// The running app, reached through control.sock in its data folder, launched when it isn't running.
final class Connection {
    let dataDirectory = ControlSocket.dataDirectory()
    private lazy var client = ControlClient(path: ControlSocket.path(in: dataDirectory))
    static let bundleID = "com.rattamnoon.portkeep"
    static let launchTimeout: TimeInterval = 10

    /// Portkeep.app around this executable (Contents/Resources/bin/portkeep), when it is inside one.
    static var appBundle: URL? {
        guard let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() else { return nil }
        let app = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    static var version: String {
        guard let app = appBundle,
              let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let version = info["CFBundleShortVersionString"] as? String else { return "dev" }
        return version
    }

    /// Calls a control method, launching Portkeep first if nothing is listening.
    func call(_ method: String, _ params: JSONValue = .object([:])) throws(RPCError) -> JSONValue {
        do {
            return try client.call(method, params)
        } catch where error.code == RPCError.unavailable {
            client.disconnect()
            try launchAndWait()
            return try client.call(method, params)
        }
    }

    private func launchAndWait() throws(RPCError) {
        launch()
        let deadline = Date.now.addingTimeInterval(Self.launchTimeout)
        while Date.now < deadline {
            if (try? client.connect()) == true { return }
            usleep(200_000)
        }
        throw RPCError(RPCError.unavailable, appIsRunning
            ? "Portkeep is running but isn’t answering on \(ControlSocket.path(in: dataDirectory)). It may be a version before 0.4: quit it and open it again."
            : "Portkeep didn’t start within \(Int(Self.launchTimeout)) seconds. Open it once from Applications, then try again.")
    }

    /// status.json says an app process is alive.
    private var appIsRunning: Bool {
        guard let snapshot = StatusFile.read(in: dataDirectory) else { return false }
        return snapshot.running && StatusFile.isAlive(snapshot.pid)
    }

    /// In the background, without taking focus. A data folder other than the default (development)
    /// starts a separate copy of the app this tool belongs to, so it never wakes the installed one.
    private func launch() {
        var arguments = ["-g"]
        let environment = ProcessInfo.processInfo.environment
        if let dir = environment["PORTKEEP_DATA_DIR"], !dir.isEmpty {
            arguments += ["-n", "--env", "PORTKEEP_DATA_DIR=\(dir)"]
        }
        if let app = Self.appBundle {
            arguments.append(app.path)
        } else {
            arguments += ["-b", Self.bundleID]
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = arguments
        open.standardOutput = FileHandle.nullDevice
        open.standardError = FileHandle.nullDevice
        try? open.run()
        open.waitUntilExit()
    }
}

/// status.json, which the app rewrites on every change: `list` and `status` read it without
/// starting Portkeep, as they always have.
enum StatusFile {
    static func read(in directory: URL) -> StatusSnapshot? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatusSnapshot.self, from: data)
    }

    /// A file left behind by a crash still says running; the pid says otherwise.
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }
}
