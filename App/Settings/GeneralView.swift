import SwiftUI
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
    @State private var launched = GeneralView.current

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
            Section {
                LabeledContent("Command line tool") {
                    Button("Install Command Line Tool…") { CommandLineTool.install(searchPath: store.tools.searchPath) }
                }
            } footer: {
                Text("Adds portkeep to your PATH: portkeep list, portkeep start <name>, portkeep stop-group <group>…")
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
