import AppKit

/// Settings › General › Install Command Line Tool…: links the `portkeep` script inside the app onto PATH.
@MainActor
enum CommandLineTool {
    static var script: URL? {
        Bundle.main.resourceURL?.appendingPathComponent("bin/portkeep")
    }

    /// /usr/local/bin when it's writable (it is on PATH everywhere), otherwise ~/.local/bin.
    static func install(searchPath: String) {
        guard let script, FileManager.default.isExecutableFile(atPath: script.path) else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let system = URL(fileURLWithPath: "/usr/local/bin")
        let user = home.appendingPathComponent(".local/bin")
        let pathDirs = Set(searchPath.split(separator: ":").map { ($0 as NSString).standardizingPath })

        if let link = try? link(script, in: system) {
            report(installedAt: link, onPath: true, script: script)
        } else if let link = try? link(script, in: user, create: true) {
            report(installedAt: link, onPath: pathDirs.contains(user.path), script: script)
        } else {
            report(installedAt: nil, onPath: false, script: script)
        }
    }

    private static func link(_ script: URL, in directory: URL, create: Bool = false) throws -> URL {
        let manager = FileManager.default
        if create { try manager.createDirectory(at: directory, withIntermediateDirectories: true) }
        guard manager.isWritableFile(atPath: directory.path) else { throw CocoaError(.fileWriteNoPermission) }
        let link = directory.appendingPathComponent("portkeep")
        // Replace an older link (another copy of the app); never a file someone else put there.
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if existing == script.path { return link }
            try manager.removeItem(at: link)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: script)
        return link
    }

    private static func report(installedAt link: URL?, onPath: Bool, script: URL) {
        let command = "sudo ln -sf '\(script.path)' /usr/local/bin/portkeep"
        let alert = NSAlert()
        if let link {
            let shown = (link.path as NSString).abbreviatingWithTildeInPath
            alert.messageText = String(localized: "Installed \(shown)")
            alert.informativeText = onPath
                ? String(localized: "Run portkeep list in a new terminal window to try it.")
                : String(localized: "\((link.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath) isn’t on your PATH yet. Add it in your shell profile, or install into /usr/local/bin with:\n\n\(command)")
        } else {
            alert.alertStyle = .warning
            alert.messageText = String(localized: "Couldn’t install the command line tool")
            alert.informativeText = String(localized: "Portkeep can’t write to /usr/local/bin or ~/.local/bin. Run this in Terminal instead:\n\n\(command)")
        }
        alert.addButton(withTitle: String(localized: "OK"))
        if link == nil || !onPath { alert.addButton(withTitle: String(localized: "Copy Command")) }
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }
}
