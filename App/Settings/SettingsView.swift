import SwiftUI
import TunnelKit

/// System Settings–style window: tunnels by group in the sidebar, the selected one on the right.
struct SettingsView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @State private var search = ""

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(selection: $navigation.selection) {
                ForEach(store.groups, id: \.self) { group in
                    let tunnels = filtered.filter { $0.group == group }
                    if !tunnels.isEmpty {
                        Section(group) {
                            ForEach(tunnels) { tunnel in
                                HStack {
                                    Text(tunnel.name)
                                    Spacer()
                                    Text(String(tunnel.localPort)).foregroundStyle(.secondary).monospacedDigit()
                                }
                                .tag(SettingsSelection.tunnel(tunnel.id))
                            }
                        }
                    }
                }
                Section {
                    Label("Tools", systemImage: "wrench.and.screwdriver").tag(SettingsSelection.tools)
                    Label("General", systemImage: "gearshape").tag(SettingsSelection.general)
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    Button { navigation.showingAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add Tunnel").accessibilityIdentifier("sidebar.add")
                    Button {
                        if case .tunnel(let id) = navigation.selection {
                            navigation.selection = nil
                            Task { await store.delete(id) }
                        }
                    } label: { Image(systemName: "minus") }
                        .accessibilityLabel("Remove Tunnel").accessibilityIdentifier("sidebar.remove")
                        .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
        } detail: {
            switch navigation.selection {
            case .tunnel(let id):
                if let tunnel = store.tunnel(id) {
                    TunnelDetailView(tunnel: tunnel).id(id)
                } else {
                    placeholder
                }
            case .tools:
                ToolsView()
            case .general:
                GeneralView()
            case nil:
                placeholder
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        .sheet(isPresented: $navigation.showingAdd) { AddTunnelView() }
    }

    private var selectedID: UUID? {
        if case .tunnel(let id) = navigation.selection { return id }
        return nil
    }

    private var filtered: [Tunnel] {
        guard !search.isEmpty else { return store.tunnels }
        return store.tunnels.filter {
            $0.name.localizedCaseInsensitiveContains(search) || String($0.localPort).contains(search)
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No Tunnel Selected", systemImage: "point.3.connected.trianglepath.dotted")
        } actions: {
            Button("Add Tunnel…") { navigation.showingAdd = true }
        }
    }
}

struct TunnelDetailView: View {
    let tunnel: Tunnel
    @Environment(TunnelStore.self) private var store
    @Environment(\.openWindow) private var openWindow
    @State private var draft: TunnelDraft

    init(tunnel: Tunnel) {
        self.tunnel = tunnel
        _draft = State(initialValue: TunnelDraft(tunnel))
    }

    var body: some View {
        VStack(spacing: 0) {
            statusCard.padding([.horizontal, .top], 20)
            TunnelEditor(draft: $draft, showsMethodPicker: true)
            HStack {
                Spacer()
                Button("Revert") { draft = TunnelDraft(tunnel) }
                    .disabled(draft == TunnelDraft(tunnel))
                Button("Save") {
                    guard let updated = draft.tunnel else { return }
                    Task { await store.save(updated) }
                }
                .keyboardShortcut("s")
                .disabled(draft.tunnel == nil || draft == TunnelDraft(tunnel))
                .accessibilityIdentifier("detail.save")
            }
            .padding(12)
        }
        .navigationTitle(tunnel.name)
    }

    private var statusCard: some View {
        let state = store.state(of: tunnel.id)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(state.isOn ? Color.accentColor : Color.primary.opacity(0.1))
                Image(systemName: tunnel.method.symbol).foregroundStyle(state.isOn ? .white : .primary)
            }
            .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(store.statusText(tunnel.id, now: context.date)).fontWeight(.semibold).accessibilityIdentifier("detail.status")
                }
                Text("127.0.0.1:\(String(tunnel.localPort)) · \(tunnel.methodName)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Show Log") { openWindow(id: "log", value: tunnel.id) }
            Toggle("On", isOn: Binding(
                get: { state.isOn },
                set: { _ in Task { await store.toggle(tunnel.id) } }))
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityIdentifier("detail.toggle")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    }
}

/// Resolved path of each CLI, with an override field (spec §5.6).
struct ToolsView: View {
    @Environment(TunnelStore.self) private var store
    private let tools = ["ssh", "aws", "session-manager-plugin", "kubectl", "gcloud", "cloudflared"]

    var body: some View {
        Form {
            Section {
                ForEach(tools, id: \.self) { tool in
                    LabeledContent(tool) {
                        TextField(tool, text: Binding(
                            get: { store.file.toolPaths[tool] ?? "" },
                            set: { store.setToolOverride(tool, path: $0) }),
                            prompt: Text(store.tools.url(for: tool)?.path ?? String(localized: "Not found")))
                            .labelsHidden()
                            .frame(width: 320)
                    }
                }
            } footer: {
                Text("Found on your login shell's PATH. Type a path to override it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tools")
    }
}
