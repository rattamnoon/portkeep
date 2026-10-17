import SwiftUI
import TunnelKit

/// Settings › General › Import from SSH Config…: LocalForward and DynamicForward lines from
/// ~/.ssh/config as a checklist of SSH tunnels to add.
struct SSHImportView: View {
    let forwards: [SSHConfigForward]
    @Environment(TunnelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<String> = []
    @State private var group = "Other"

    private func added(_ forward: SSHConfigForward) -> Bool { store.tunnels.contains(where: forward.matches) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Import from SSH Config").font(.headline).padding([.horizontal, .top], 16)
            Text("Forwards found in ~/.ssh/config and the files it includes.")
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 2)
            if forwards.isEmpty {
                ContentUnavailableView("No Forwards Found", systemImage: "terminal",
                                       description: Text("No LocalForward or DynamicForward lines under a named Host."))
            } else {
                Form {
                    Section {
                        ForEach(forwards) { row($0) }
                    } footer: {
                        if forwards.contains(where: { $0.forwardsOnHost > 1 }) {
                            Text("ssh opens every forward of a host at once, so tunnels from a host with several run one at a time. To run them side by side, remove those LocalForward lines from ~/.ssh/config after adding.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Section {
                        ComboField("Group", text: $group, choices: store.groups, prompt: example("Production"))
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add \(chosen.count) Tunnels") {
                    let group = group.trimmingCharacters(in: .whitespaces)
                    store.add(forwards.filter { chosen.contains($0.id) }.map { $0.tunnel(group: group.isEmpty ? "Other" : group) })
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(12)
        }
        .frame(width: 540, height: 460)
        .onAppear { chosen = Set(forwards.filter { !added($0) }.map(\.id)) }
    }

    private func row(_ forward: SSHConfigForward) -> some View {
        let done = added(forward)
        return Toggle(isOn: Binding(
            get: { chosen.contains(forward.id) },
            set: { if $0 { chosen.insert(forward.id) } else { chosen.remove(forward.id) } })) {
            VStack(alignment: .leading, spacing: 1) {
                Text(forward.name)
                Group {
                    if done {
                        Text("Already added")
                    } else if let destination = forward.destination {
                        Text(verbatim: "127.0.0.1:\(forward.localPort) → \(destination.host):\(destination.port)")
                    } else {
                        Text("SOCKS proxy on 127.0.0.1:\(String(forward.localPort))")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .disabled(done)
    }
}
