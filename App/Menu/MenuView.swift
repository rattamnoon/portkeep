import SwiftUI
import TunnelKit

struct MenuView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 10).padding(.bottom, 4)

            if let banner = store.banner {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }

            if store.tunnels.isEmpty {
                emptyState
            } else {
                ForEach(store.groups, id: \.self) { group in
                    let tunnels = store.tunnels.filter { $0.group == group }
                    if !tunnels.isEmpty {
                        Text(group)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
                        ForEach(tunnels) { TunnelRow(tunnel: $0) }
                    }
                }
            }

            Divider().padding(.horizontal, 10).padding(.vertical, 4)
            MenuItem("Add Tunnel…") { open(.none, add: true) }
            MenuItem("Burrow Settings…") { open(store.tunnels.first.map { .tunnel($0.id) }, add: false) }
            MenuItem("Quit Burrow") { NSApplication.shared.terminate(nil) }
        }
        .padding(5)
        .frame(width: 320)
    }

    private var header: some View {
        HStack {
            Text("Tunnels").font(.system(size: 13, weight: .bold))
            Spacer()
            Toggle("All tunnels", isOn: Binding(
                get: { store.tunnels.contains { store.state(of: $0.id).isOn } },
                set: { on in Task { on ? await store.startAll() : await store.stopAll() } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .disabled(store.tunnels.isEmpty)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
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
            openSettings()
        }
    }
}

/// A plain full-width menu item with the system hover highlight.
struct MenuItem: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? Color.primary.opacity(0.08) : .clear))
        .onHover { hovering = $0 }
    }
}
