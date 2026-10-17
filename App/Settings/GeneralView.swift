import SwiftUI
import TunnelKit
import UserNotifications

/// App language. macOS reads `AppleLanguages` at launch, so a change applies after relaunching.
struct GeneralView: View {
    @Environment(TunnelStore.self) private var store
    static let languages: [(code: String, name: String)] = [
        ("en", "English"), ("th", "ไทย"), ("zh-Hans", "简体中文"), ("ja", "日本語"),
    ]

    @State private var selection = GeneralView.current
    @AppStorage("restoreTunnelsOnLaunch") private var restoreTunnels = true
    @AppStorage("notifyOnDrop") private var notifyOnDrop = true
    @State private var notificationsDenied = false
    @State private var sshForwards: [SSHConfigForward]?
    @State private var launched = GeneralView.current
    @State private var copied: String?

    var body: some View {
        Form {
            Section {
                Toggle("Reopen tunnels that were on when Portkeep quit", isOn: $restoreTunnels)
            } footer: {
                Text("Tunnels set to Connect at login always start.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Notify when a tunnel drops", isOn: $notifyOnDrop)
                    .onChange(of: notifyOnDrop) { _, on in
                        guard on else { return }
                        Task {
                            await DropNotifications.authorize()
                            notificationsDenied = await DropNotifications.isDenied
                        }
                    }
                if notifyOnDrop, notificationsDenied {
                    HStack {
                        Text("Notifications for Portkeep are off in System Settings.")
                            .font(.caption).foregroundStyle(.orange)
                        Spacer()
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                        }
                    }
                }
            } footer: {
                Text("When a tunnel has been down for 30 seconds or needs you, such as an expired sign-in, and again when it’s back.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Tunnels") {
                LabeledContent("Back up or move to another Mac") {
                    HStack {
                        Button("Export Tunnels…", action: exportTunnels)
                            .disabled(store.tunnels.isEmpty)
                        Button("Import Tunnels…", action: importTunnels)
                            .disabled(store.readOnly)
                    }
                }
                LabeledContent("Forwards in ~/.ssh/config") {
                    Button("Import from SSH Config…") { sshForwards = SSHConfigParser.forwards() }
                        .disabled(store.readOnly)
                }
            }
            Section {
                LabeledContent("Command line tool") {
                    Button("Install Command Line Tool…") { CommandLineTool.install(searchPath: store.tools.searchPath) }
                }
            } footer: {
                Text("Adds portkeep to your PATH: portkeep list, portkeep start <name>, portkeep stop-group <group>…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("MCP server") {
                    Button(copied == "mcp" ? "Copied" : "Copy MCP Config") { copy(CommandLineTool.mcpConfig, as: "mcp") }
                        .disabled(CommandLineTool.mcpConfig == nil)
                        .accessibilityIdentifier("general.copyMCPConfig")
                }
                if let command = CommandLineTool.claudeCommand {
                    LabeledContent {
                        Button(copied == "claude" ? "Copied" : "Copy Command") { copy(command, as: "claude") }
                    } label: {
                        Text("Claude Code")
                        Text(verbatim: command)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            } header: {
                Text("AI assistants")
            } footer: {
                Text("Lets Claude, Cursor and other assistants that support MCP list, add, test and start your tunnels. Paste the config into the assistant’s MCP settings, or run the command for Claude Code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Language", selection: $selection) {
                    Text("Same as macOS").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.code) { Text(verbatim: $0.name).tag($0.code) }
                }
                .onChange(of: selection) { _, code in
                    if code.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "AppleLanguages")
                    } else {
                        UserDefaults.standard.set([code], forKey: "AppleLanguages")
                    }
                }
                if selection != launched {
                    HStack {
                        Text("Portkeep needs to relaunch to switch language.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Relaunch Now", action: Self.relaunch)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
        .task { notificationsDenied = await DropNotifications.isDenied }
        .sheet(isPresented: Binding(get: { sshForwards != nil }, set: { if !$0 { sshForwards = nil } })) {
            SSHImportView(forwards: sshForwards ?? []).environment(store)
        }
    }

    private func copy(_ text: String?, as which: String) {
        guard let text else { return }
        CommandLineTool.copy(text)
        copied = which
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == which { copied = nil }
        }
    }

    private func exportTunnels() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = String(localized: "Portkeep Tunnels.json")
        panel.allowedContentTypes = [.json]
        panel.message = String(localized: "Tunnels, groups, tags and colours. Tool paths aren’t included.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportData().write(to: url, options: .atomic)
        } catch {
            showAlert(String(localized: "Couldn’t export tunnels"), error.localizedDescription)
        }
    }

    private func importTunnels() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "Choose a file from Export Tunnels…, or a tunnels.json.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url),
              let export = try? JSONDecoder().decode(TunnelExport.self, from: data) else {
            showAlert(String(localized: "Couldn’t import \(url.lastPathComponent)"),
                      String(localized: "It isn’t a Portkeep export or tunnels.json."))
            return
        }
        let summary = store.importTunnels(export)
        showAlert(String(localized: "Imported \(String(summary.imported)), skipped \(String(summary.skipped))"),
                  summary.skipped > 0 ? String(localized: "Skipped tunnels are already here with the same settings.") : "")
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private static var current: String {
        guard let set = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String],
              let first = set.first else { return "" }
        return languages.first { first.hasPrefix($0.code) }?.code ?? ""
    }

    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }
}
