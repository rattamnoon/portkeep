import SwiftUI
import TunnelKit

/// System Settings–style window: tunnels by group in the sidebar, the selected one on the right.
struct SettingsView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""
    @State private var confirmingDelete = false

    private func openAddWindow() {
        AppActivation.bringForward()
        openWindow(id: "add")
    }

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $navigation.selection) {
                ForEach(store.groups, id: \.self) { group in
                    let tunnels = filtered.filter { $0.group == group }
                    if !tunnels.isEmpty {
                        Section {
                            ForEach(tunnels) { tunnel in
                                Text(tunnel.name).lineLimit(1)
                                .tag(SettingsSelection.tunnel(tunnel.id))
                                .contextMenu {
                                    Button("Duplicate") { duplicate(tunnel.id) }
                                }
                            }
                        } header: {
                            GroupHeader(name: group, hex: store.file.groupColors[group])
                                .contextMenu {
                                    Button("Start All") { Task { await store.startGroup(group) } }
                                    Button("Stop All") { Task { await store.stopGroup(group) } }
                                }
                        }
                    }
                }
                Section {
                    Label("Groups & Tags", systemImage: "tag").tag(SettingsSelection.labels)
                    Label("Tools", systemImage: "wrench.and.screwdriver").tag(SettingsSelection.tools)
                    Label("General", systemImage: "gearshape").tag(SettingsSelection.general)
                }
            }
            .searchable(text: $search, placement: .sidebar)
            .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 340)
            // Like System Settings: the sidebar always shows, and its toggle crowded the window buttons.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 2) {
                    Button { openAddWindow() } label: {
                        Image(systemName: "plus").frame(width: 24, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Add Tunnel").accessibilityIdentifier("sidebar.add")
                    Button { confirmingDelete = true } label: {
                        Image(systemName: "minus").frame(width: 24, height: 22).contentShape(Rectangle())
                    }
                    .accessibilityLabel("Remove Tunnel").accessibilityIdentifier("sidebar.remove")
                    .disabled(selectedID == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
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
            case .labels:
                LabelsView()
            case nil:
                placeholder
            }
        }
        .frame(minWidth: 760, minHeight: 540)
        // On macOS a confirmation dialog is a sheet; keep it at the top so no child presentation hides it.
        .confirmationDialog(
            "Remove \(selectedID.flatMap { store.tunnel($0)?.name } ?? "")?",
            isPresented: $confirmingDelete
        ) {
            Button("Remove", role: .destructive) {
                guard let id = selectedID else { return }
                navigation.selection = nil
                Task { await store.delete(id) }
            }
            .accessibilityIdentifier("sidebar.confirmRemove")
        } message: {
            Text("The tunnel stops if it's running.")
        }
    }

    /// Opens the editor on the copy.
    private func duplicate(_ id: UUID) {
        if let copy = store.duplicate(id) { navigation.selection = .tunnel(copy) }
    }

    private var selectedID: UUID? {
        if case .tunnel(let id) = navigation.selection { return id }
        return nil
    }

    private var filtered: [Tunnel] {
        guard !search.isEmpty else { return store.tunnels }
        return store.tunnels.filter {
            $0.name.localizedCaseInsensitiveContains(search) || String($0.localPort).contains(search)
                || $0.group.localizedCaseInsensitiveContains(search)
                || $0.tags.contains { $0.localizedCaseInsensitiveContains(search) }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView {
            Label("No Tunnel Selected", systemImage: "point.3.connected.trianglepath.dotted")
        } actions: {
            Button("Add Tunnel…") { openAddWindow() }
        }
        // Otherwise the window keeps the title of the tunnel that was just removed.
        .navigationTitle("Settings")
    }
}

struct TunnelDetailView: View {
    let tunnel: Tunnel
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
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
                Button("Duplicate") {
                    if let copy = store.duplicate(tunnel.id) { navigation.selection = .tunnel(copy) }
                }
                .accessibilityIdentifier("detail.duplicate")
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
            Button("Show Log") { AppActivation.bringForward(); openWindow(id: "log", value: tunnel.id) }
            // A button, not a switch: a Toggle bound to async state never called its setter here.
            Button(state.isOn ? "Stop" : "Start") { Task { await store.toggle(tunnel.id) } }
                .keyboardShortcut(.return, modifiers: .command)
                .accessibilityIdentifier("detail.toggle")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background))
        // Border only: an overlay shape takes every click inside it, which made the card's buttons dead.
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator).allowsHitTesting(false))
    }
}

/// Resolved path of each CLI, with an override field (spec §5.6).
struct ToolsView: View {
    @Environment(TunnelStore.self) private var store
    private let tools = ["ssh", "aws", "session-manager-plugin", "kubectl", "gcloud", "cloudflared"]

    var body: some View {
        Form {
            Section {
                ForEach(tools, id: \.self) { ToolRow(tool: $0) }
            } footer: {
                Text("Portkeep finds each tool on your login shell's PATH. Type or choose a path to use a different one; Reset goes back to the one found.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Tools")
    }
}

private struct ToolRow: View {
    let tool: String
    @Environment(TunnelStore.self) private var store
    @State private var text = ""

    private var override: String? { store.file.toolPaths[tool] }
    /// What PATH alone would give, ignoring the override.
    private var found: String? { ToolPaths(searchPath: store.tools.searchPath, overrides: [:]).url(for: tool)?.path }
    private var effective: String? { override ?? found }
    private var usable: Bool { effective.map { FileManager.default.isExecutableFile(atPath: $0) } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: usable ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(usable ? .green : .orange)
                    .accessibilityLabel(usable ? Text("Found") : Text("Not found"))
                Text(verbatim: tool).fontWeight(.medium)
                Spacer()
                if override != nil {
                    Text("Custom").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 6) {
                TextField(tool, text: $text, prompt: Text(found ?? String(localized: "Not found")))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { store.setToolOverride(tool, path: text.trimmingCharacters(in: .whitespaces)) }
                Button("Choose…", action: choose)
                Button("Reset") {
                    text = ""
                    store.setToolOverride(tool, path: "")
                }
                .disabled(override == nil)
            }
            if let override, !FileManager.default.isExecutableFile(atPath: override) {
                Text("\(override) isn't an executable file.").font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
        .onAppear { text = override ?? "" }
        .onChange(of: override) { _, new in text = new ?? "" }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.directoryURL = URL(fileURLWithPath: (effective as NSString?)?.deletingLastPathComponent ?? "/opt/homebrew/bin")
        panel.message = String(localized: "Choose the \(tool) executable")
        if panel.runModal() == .OK, let url = panel.url {
            text = url.path
            store.setToolOverride(tool, path: url.path)
        }
    }
}
