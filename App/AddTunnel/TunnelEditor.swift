import SwiftUI
import TunnelKit

/// The fields for one tunnel, shared by the Add sheet and the Settings detail pane.
struct TunnelEditor: View {
    @Binding var draft: TunnelDraft
    var showsMethodPicker = false
    @Environment(TunnelStore.self) private var store
    @State private var sources = ConfigSources()
    @State private var advanced = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name, prompt: Text("e.g. Dashboard MySQL")).accessibilityIdentifier("editor.name")
                Picker("Group", selection: $draft.group) {
                    ForEach(groupChoices, id: \.self) { Text($0).tag($0) }
                }
                if showsMethodPicker {
                    Picker("Connect with", selection: $draft.kind) {
                        ForEach(MethodKind.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                    }
                }
            }

            Section(header: Text(draft.kind.title)) {
                methodFields
                LabeledContent("Local port") {
                    HStack {
                        Text(portStatus.text).font(.caption).foregroundStyle(portStatus.color)
                        TextField("Local port", text: $draft.localPort, prompt: Text("e.g. 3306")).accessibilityIdentifier("editor.localPort")
                            .labelsHidden()
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Toggle("Connect at login", isOn: $draft.connectAtLogin)
            }

            if hasAdvanced {
                Section {
                    DisclosureGroup("Advanced Options", isExpanded: $advanced) { advancedFields }
                }
            }

            Section {
                Text(commandPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } header: {
                Text("Runs")
            } footer: {
                Text(draft.kind.needs).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await sources.load(tools: store.tools) }
    }

    private var groupChoices: [String] {
        var groups = store.groups
        if !groups.contains(draft.group) { groups.append(draft.group) }
        return groups
    }

    // MARK: Method fields

    @ViewBuilder private var methodFields: some View {
        switch draft.kind {
        case .ssh:
            Picker("Forwarding", selection: $draft.sshMode) {
                Text("Local").tag(SSHMode.local)
                Text("Remote").tag(SSHMode.remote)
                Text("SOCKS").tag(SSHMode.dynamic)
            }
            .pickerStyle(.segmented)
            ComboField("Host", text: $draft.sshHost, choices: sources.sshHosts, prompt: "e.g. jump")
            ComboField("Jump through", text: $draft.sshJump, choices: sources.sshHosts, prompt: "None")
            if draft.sshMode != .dynamic {
                hostPort("Destination", host: $draft.destHost, port: $draft.destPort,
                         hostPrompt: "e.g. mysql.internal", portPrompt: "3306")
            }
        case .ssm:
            ComboField("Profile", text: $draft.profile, choices: sources.awsProfiles.map(\.name), prompt: "e.g. default")
                .onChange(of: draft.profile) { _, name in
                    if draft.region.isEmpty, let region = sources.awsProfiles.first(where: { $0.name == name })?.region {
                        draft.region = region
                    }
                }
            TextField("Region", text: $draft.region, prompt: Text("e.g. ap-southeast-1"))
            TextField("Instance ID", text: $draft.target, prompt: Text("e.g. i-0123456789abcdef0"))
            Picker("Forward to", selection: $draft.ssmToRemoteHost) {
                Text("Remote host").tag(true)
                Text("The instance").tag(false)
            }
            .pickerStyle(.segmented)
            if draft.ssmToRemoteHost {
                TextField("Remote host", text: $draft.remoteHost, prompt: Text("e.g. mysql.prod.internal"))
            }
            TextField("Remote port", text: $draft.remotePort, prompt: Text("e.g. 3306"))
        case .kubernetes:
            ComboField("Context", text: $draft.context, choices: sources.kubeContexts, prompt: "e.g. my-cluster")
            TextField("Namespace", text: $draft.namespace, prompt: Text("e.g. default"))
            TextField("Resource", text: $draft.resource, prompt: Text("e.g. svc/grafana"))
            TextField("Remote port", text: $draft.remotePort, prompt: Text("e.g. 3000"))
        case .iap:
            TextField("Project", text: $draft.project, prompt: Text("e.g. my-project"))
            TextField("Zone", text: $draft.zone, prompt: Text("e.g. asia-southeast1-a"))
            TextField("Instance", text: $draft.instance, prompt: Text("e.g. db-1"))
            TextField("Remote port", text: $draft.remotePort, prompt: Text("e.g. 5432"))
        case .cloudflare:
            TextField("Hostname", text: $draft.hostname, prompt: Text("e.g. db.example.com"))
        case .custom:
            TextField("Command", text: $draft.command, prompt: Text("e.g. tsh proxy db --port {port} mydb"), axis: .vertical).accessibilityIdentifier("editor.command")
                .font(.system(size: 12, design: .monospaced))
            Text("Use {port} where the local port goes.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hasAdvanced: Bool { draft.kind == .ssh || draft.kind == .ssm }

    @ViewBuilder private var advancedFields: some View {
        switch draft.kind {
        case .ssh:
            TextField("Identity file", text: $draft.identityFile, prompt: Text("Use ssh-agent"))
            TextField("Keep-alive (seconds)", text: $draft.keepAlive)
            Toggle("Fail if the port can't be forwarded", isOn: $draft.exitOnForwardFailure)
            Toggle("Compression", isOn: $draft.compression)
            TextField("Extra arguments", text: $draft.extraArgs, prompt: Text("-o LogLevel=ERROR"))
        case .ssm:
            Toggle("Offer AWS sign-in when the session expires", isOn: $draft.ssoAutoLogin)
        default:
            EmptyView()
        }
    }

    private func hostPort(_ label: LocalizedStringKey, host: Binding<String>, port: Binding<String>,
                          hostPrompt: String, portPrompt: String) -> some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: host, prompt: Text(hostPrompt)).labelsHidden()
                Text(":").foregroundStyle(.secondary)
                TextField("Port", text: port, prompt: Text(portPrompt)).labelsHidden().frame(width: 64)
            }
        }
    }

    // MARK: Derived

    private var portStatus: (text: LocalizedStringKey, color: Color) {
        guard let port = Int(draft.localPort), (1...65535).contains(port) else { return ("", .secondary) }
        if let other = store.tunnels.first(where: { $0.localPort == port && $0.id != draft.id }) {
            return ("Also used by \(other.name)", .orange)
        }
        if store.tunnel(draft.id)?.localPort == port, store.state(of: draft.id).isOn { return ("", .secondary) }
        return store.ports.isFree(port) ? ("Available", .secondary) : ("In use", .orange)
    }

    private var commandPreview: String {
        guard let tunnel = draft.tunnel else {
            return String(localized: "Fill in the fields above to see the command.")
        }
        do {
            let inv = try CommandBuilder.invocation(for: tunnel, tools: store.tools)
            return ([inv.executable.lastPathComponent] + inv.arguments.map(Self.quoted)).joined(separator: " ")
        } catch {
            return String(localized: "\(error.tool) not found. Install it with \(error.installHint).")
        }
    }

    private static func quoted(_ arg: String) -> String {
        arg.contains(where: { $0 == " " || $0 == "\"" }) ? "'\(arg)'" : arg
    }
}

/// A text field with a menu of known values (hosts from ~/.ssh/config, AWS profiles, kube contexts).
struct ComboField: View {
    let label: LocalizedStringKey
    @Binding var text: String
    let choices: [String]
    let prompt: String

    init(_ label: LocalizedStringKey, text: Binding<String>, choices: [String], prompt: String) {
        self.label = label
        _text = text
        self.choices = choices
        self.prompt = prompt
    }

    var body: some View {
        LabeledContent(label) {
            HStack(spacing: 4) {
                TextField(label, text: $text, prompt: Text(prompt)).labelsHidden()
                if !choices.isEmpty {
                    Menu {
                        ForEach(choices, id: \.self) { choice in Button(choice) { text = choice } }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(Text("Choose \(Text(label))"))
                }
            }
        }
    }
}

/// Hosts, profiles and contexts the user already has configured.
@MainActor @Observable
final class ConfigSources {
    var sshHosts: [String] = []
    var awsProfiles: [AWSProfile] = []
    var kubeContexts: [String] = []

    func load(tools: ToolPaths) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if let text = try? String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8) {
            sshHosts = SSHConfigParser.hosts(in: text)
        }
        if let text = try? String(contentsOf: home.appendingPathComponent(".aws/config"), encoding: .utf8) {
            awsProfiles = AWSConfigParser.profiles(in: text)
        }
        if let kubectl = tools.url(for: "kubectl"),
           let output = try? await ToolLocator.captureOutput(kubectl, ["config", "get-contexts", "-o", "name"]) {
            kubeContexts = KubeContexts.parse(output)
        }
    }
}
