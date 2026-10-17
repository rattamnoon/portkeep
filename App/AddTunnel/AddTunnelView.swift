import SwiftUI
import TunnelKit

/// Method list on the left, its fields on the right (design canvas: "Add tunnel · connection methods").
struct AddTunnelView: View {
    @Environment(TunnelStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var draft = TunnelDraft()
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(selection: $draft.kind) {
                    Section("Connect with") {
                        ForEach(MethodKind.allCases) { kind in
                            VStack(alignment: .leading, spacing: 1) {
                                Label(kind.title, systemImage: kind.symbol)
                                Text(kind.subtitle).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                            }
                            .padding(.vertical, 2)
                            .tag(kind)
                        }
                    }
                }
                .listStyle(.sidebar)
                .frame(width: 220)

                TunnelEditor(draft: $draft)
            }

            Divider()
            HStack {
                Button("Test Connection") { Task { await runTest() } }
                    .disabled(draft.tunnel == nil || testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(testResult).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add Tunnel") {
                    guard let tunnel = draft.tunnel else { return }
                    Task {
                        await store.save(tunnel)
                        dismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.tunnel == nil)
                .accessibilityIdentifier("add.confirm")
            }
            .padding(12)
        }
        .frame(width: 780, height: 600)
    }

    private func runTest() async {
        guard let tunnel = draft.tunnel else { return }
        testing = true
        testResult = nil
        let (state, _) = await store.test(tunnel)
        testing = false
        switch state {
        case .connected: testResult = String(localized: "Connected. Port \(String(tunnel.localPort)) is open.")
        default: testResult = statusLine(state, tunnel: tunnel, now: .now)
        }
    }
}
