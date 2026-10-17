import SwiftUI
import TunnelKit

struct TunnelRow: View {
    let tunnel: Tunnel
    @Environment(TunnelStore.self) private var store
    @Environment(Navigation.self) private var navigation
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @State private var hovering = false

    private var state: TunnelState { store.state(of: tunnel.id) }

    private var active: Bool {
        switch state {
        case .connected, .starting, .checking, .retrying: true
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
            Button { Task { await store.toggle(tunnel.id) } } label: {
                HStack(spacing: 9) {
                    ZStack {
                        Circle().fill(active ? Color.accentColor : Color.primary.opacity(0.09))
                        Image(systemName: tunnel.method.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(active ? Color.white : Color.primary)
                    }
                    .frame(width: 26, height: 26)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(tunnel.name).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(store.statusText(tunnel.id, now: context.date))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(state.needsAttention ? 2 : 1)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 4)
                    if showsWarning {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 12))
                            .accessibilityHidden(true)
                    }
                    Text(":\(String(tunnel.localPort))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tunnel.name), \(store.statusText(tunnel.id))")
            .accessibilityHint(state.isOn ? "Turns the tunnel off" : "Turns the tunnel on")

            actionsMenu
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(hovering ? Color.primary.opacity(0.07) : .clear))
        .onHover { hovering = $0 }
    }

    private var actionsMenu: some View {
        Menu {
            fixAction
            Button("Copy Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("127.0.0.1:\(tunnel.localPort)", forType: .string)
            }
            Button("Edit Tunnel…") {
                navigation.selection = .tunnel(tunnel.id)
                navigation.showingAdd = false
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }
            Button("Show Log") {
                NSApp.activate(ignoringOtherApps: true)
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

    @ViewBuilder private var fixAction: some View {
        switch state {
        case .blocked(let owner) where owner != nil:
            let alternate = PortProbe.alternate(for: tunnel.localPort) { store.ports.isFree($0) }
            Button("Use Port \(String(alternate))") { Task { await store.useAlternatePort(tunnel.id) } }
            Divider()
        case .failed(.ssoExpired):
            Button("Sign In to AWS…") { Task { await store.signIn(tunnel.id) } }
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
