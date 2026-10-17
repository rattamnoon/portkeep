import SwiftUI
import TunnelKit

struct MenuView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let banner = store.banner {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 0) {
                if store.tunnels.isEmpty {
                    emptyState
                } else {
                    ForEach(store.groups, id: \.self) { group in
                        let tunnels = store.tunnels.filter { $0.group == group }
                        if !tunnels.isEmpty {
                            HStack(spacing: 5) {
                                if let hex = store.file.groupColors[group] {
                                    Circle().fill(Color(hex: hex)).frame(width: 7, height: 7).accessibilityHidden(true)
                                }
                                Text(group.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .tracking(0.4)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                groupSwitch(group, tunnels: tunnels)
                            }
                            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 2)
                            ForEach(tunnels) { TunnelRow(tunnel: $0) }
                        }
                    }
                }
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))

            Button { open(.none, add: true) } label: {
                Label("Add Tunnel…", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)

            HStack(spacing: 8) {
                Button { open(store.tunnels.first.map { .tunnel($0.id) }, add: false) } label: {
                    Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity)
                }
                Button { NSApplication.shared.terminate(nil) } label: {
                    Label("Quit", systemImage: "power").frame(maxWidth: .infinity)
                }
            }
            .controlSize(.large)
        }
        .padding(12)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // From the bundle, not NSApp.applicationIconImage: that one comes from the system's
            // icon cache and can still show an old icon after an update.
            Image(nsImage: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")
                .flatMap(NSImage.init(contentsOf:)) ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 34, height: 34)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Portkeep").font(.system(size: 14, weight: .bold))
                Text("\(store.connectedCount) of \(store.tunnels.count) connected")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("All tunnels", isOn: Binding(
                get: { store.tunnels.contains { store.state(of: $0.id).isOn } },
                set: { on in Task { on ? await store.startAll() : await store.stopAll() } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(store.tunnels.isEmpty)
                .help("Start or stop every tunnel")
        }
        .padding(.horizontal, 4)
    }

    /// Like the switch at the top, for one group: on while any of its tunnels is on.
    private func groupSwitch(_ group: String, tunnels: [Tunnel]) -> some View {
        Toggle("Tunnels in \(group)", isOn: Binding(
            get: { tunnels.contains { store.state(of: $0.id).isOn } },
            set: { on in Task { on ? await store.startGroup(group) : await store.stopGroup(group) } }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help("Start or stop every tunnel in \(group)")
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No tunnels yet").font(.system(size: 13, weight: .medium))
            Text("Add one, or pick a host from ~/.ssh/config.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func open(_ selection: SettingsSelection?, add: Bool) {
        AppActivation.bringForward()
        if add {
            openWindow(id: "add")
        } else {
            navigation.selection = selection
            navigation.showSettings()
        }
    }
}
