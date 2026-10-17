import SwiftUI
import TunnelKit

struct MenuView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    /// The group tab last chosen; "" is All. Kept across popover opens.
    @AppStorage("menuGroupTab") private var groupTab = ""
    @State private var listHeight: CGFloat = 0

    private static let maxListHeight: CGFloat = 480

    private var groupsWithTunnels: [String] {
        store.groups.filter { group in store.tunnels.contains { $0.group == group } }
    }

    /// The chosen group, or nil for All (also when that group has gone).
    private var selectedGroup: String? {
        groupsWithTunnels.contains(groupTab) ? groupTab : nil
    }

    private var shownGroups: [String] {
        selectedGroup.map { [$0] } ?? groupsWithTunnels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if let release = UpdateChecker.shared.available {
                UpdateBanner(release: release).padding(.horizontal, 4)
            }

            if let banner = store.banner {
                Label(banner, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
            }

            if groupsWithTunnels.count > 1 { groupTabs }

            // Scrolls once it is taller than `maxListHeight`, so a long list keeps the popover on screen.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if store.tunnels.isEmpty {
                        emptyState
                    } else {
                        ForEach(shownGroups, id: \.self) { group in
                            let tunnels = store.tunnels.filter { $0.group == group }
                            groupHeader(group, tunnels: tunnels)
                            ForEach(tunnels) { TunnelRow(tunnel: $0) }
                        }
                    }
                }
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ListHeight.self, value: proxy.size.height)
                })
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(listHeight, Self.maxListHeight))
            .onPreferenceChange(ListHeight.self) { listHeight = $0 }
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

    private func groupHeader(_ group: String, tunnels: [Tunnel]) -> some View {
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
    }

    /// "All" plus one tab per group with tunnels, each with its colour and connected count.
    private var groupTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                tab(nil)
                ForEach(groupsWithTunnels, id: \.self) { tab($0) }
            }
            .padding(.horizontal, 2)
        }
    }

    private func tab(_ group: String?) -> some View {
        let selected = selectedGroup == group
        let tunnels = store.tunnels.filter { group == nil || $0.group == group }
        let connected = tunnels.filter { if case .connected = store.state(of: $0.id) { true } else { false } }.count
        return Button { groupTab = group ?? "" } label: {
            HStack(spacing: 4) {
                if let group, let hex = store.file.groupColors[group] {
                    Circle().fill(Color(hex: hex)).frame(width: 6, height: 6)
                }
                if let group { Text(verbatim: group) } else { Text("All") }
                Text(verbatim: "\(connected)/\(tunnels.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(selected ? Color.primary.opacity(0.8) : Color.secondary)
            }
            .font(.system(size: 11, weight: selected ? .semibold : .regular))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.14) : Color.primary.opacity(0.04)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(group.map { Text(verbatim: $0) } ?? Text("All"))
        .accessibilityValue(Text("\(connected) of \(tunnels.count) connected"))
        .accessibilityAddTraits(selected ? .isSelected : [])
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

private struct ListHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
