import SwiftUI
import TunnelKit

struct TunnelRow: View {
    let tunnel: Tunnel
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    private var state: TunnelState { store.state(of: tunnel.id) }

    private var active: Bool {
        switch state {
        case .connected, .starting, .checking, .retrying, .standingBy: true
        default: false
        }
    }

    /// Blocked and failed tunnels need the user; retrying ones are handling it themselves.
    private var showsWarning: Bool {
        switch state {
        case .blocked, .failed: true
        default: false
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.09))
                Image(systemName: tunnel.method.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.primary)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(tunnel.name).lineLimit(1)
                    Text(":\(String(tunnel.localPort))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(store.statusText(tunnel.id, now: context.date))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(state.needsAttention ? 2 : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // The text column takes the free width first; a Spacer here split it in half and cut names short.
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .accessibilityElement(children: .combine)
            if showsWarning {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 12))
                    .accessibilityHidden(true)
            }

            actionsMenu

            // One switch per tunnel: on means Portkeep keeps it up.
            Toggle(tunnel.name, isOn: Binding(
                get: { state.isOn },
                set: { _ in Task { await store.toggle(tunnel.id) } }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .accessibilityHint(state.isOn ? Text("Turns the tunnel off") : Text("Turns the tunnel on"))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
    }

    private var actionsMenu: some View {
        Menu {
            fixAction
            Button("Change Local Port…") { changeLocalPort() }
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("127.0.0.1:\(tunnel.localPort)", forType: .string)
            }
            Button("Edit Tunnel…") {
                navigation.selection = .tunnel(tunnel.id)
                AppActivation.bringForward()
                navigation.showSettings()
            }
            Button("Duplicate") {
                guard let copy = store.duplicate(tunnel.id) else { return }
                navigation.selection = .tunnel(copy)
                AppActivation.bringForward()
                navigation.showSettings()
            }
            Button("Show Log") {
                AppActivation.bringForward()
                openWindow(id: "log", value: tunnel.id)
            }
        } label: {
            Image(systemName: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .opacity(hovering || state.needsAttention ? 1 : 0)
        .accessibilityLabel("Actions for \(tunnel.name)")
    }

    /// Asks for a new local port and saves it; a running tunnel restarts on the new port.
    private func changeLocalPort() {
        AppActivation.bringForward()
        let alert = NSAlert()
        alert.messageText = String(localized: "Local port for \(tunnel.name)")
        alert.informativeText = String(localized: "A running tunnel restarts on the new port.")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        field.stringValue = String(tunnel.localPort)
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Change"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let port = Int(text), (1...65535).contains(port) else {
            showProblem(String(localized: "Enter a port from 1 to 65535."))
            return
        }
        guard port != tunnel.localPort else { return }
        var updated = tunnel
        updated.localPort = port
        Task { await store.save(updated) }
    }

    private func showProblem(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.runModal()
    }

    @ViewBuilder private var fixAction: some View {
        switch state {
        case .blocked(let owner):
            if owner != nil {
                let alternate = PortProbe.alternate(for: tunnel.localPort) { store.ports.isFree($0) }
                Button("Use Port \(String(alternate))") { Task { await store.useAlternatePort(tunnel.id) } }
            }
            // For when the other process has gone, or the user stopped it.
            Button("Retry Now") { Task { await store.retry(tunnel.id) } }
            Divider()
        case .failed(.ssoExpired):
            if store.offersSignIn(tunnel.id) {
                Button("Sign In to AWS…") { Task { await store.signIn(tunnel.id) } }
            }
            // For a sign-in done in Terminal.
            Button("Retry Now") { Task { await store.retry(tunnel.id) } }
            Divider()
        case .failed, .retrying:
            Button("Retry Now") { Task { await store.retry(tunnel.id) } }
            Divider()
        default:
            EmptyView()
        }
    }
}

extension TunnelMethod {
    var symbol: String {
        switch self {
        case .ssh: "terminal"
        case .ssm: "cloud"
        case .kubernetes: "shippingbox"
        case .iap: "lock.shield"
        case .cloudflare: "globe"
        case .custom: "chevron.left.forwardslash.chevron.right"
        }
    }
}
