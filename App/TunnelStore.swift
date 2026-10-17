import AppKit
import Foundation
import Observation
import TunnelKit

/// The app's single source of truth: tunnel definitions, their live states, and the commands the UI sends.
@MainActor @Observable
final class TunnelStore {
    typealias Supervisor = TunnelSupervisor<ContinuousClock>

    private(set) var file = TunnelFile()
    private(set) var states: [UUID: TunnelState] = [:]
    /// Tunnels waiting because another tunnel holds their port: waiting id → holder id.
    private(set) var blockedBy: [UUID: UUID] = [:]
    var banner: String?
    private(set) var tools = ToolPaths(searchPath: ToolLocator.fallbackPath, overrides: [:])
    private(set) var readOnly = false

    @ObservationIgnored private var supervisors: [UUID: Supervisor] = [:]
    @ObservationIgnored private var claims = PortClaims()
    @ObservationIgnored private var runner: any ProcessRunning = SystemRunner(path: ToolLocator.fallbackPath)
    @ObservationIgnored let ports: any PortChecking = SystemPorts()
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let reaper: OrphanReaper

    var tunnels: [Tunnel] { file.tunnels }
    var groups: [String] {
        var seen = file.groups
        for t in file.tunnels where !seen.contains(t.group) { seen.append(t.group) }
        return seen
    }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Burrow")) {
        fileURL = directory.appendingPathComponent("tunnels.json")
        reaper = OrphanReaper(file: directory.appendingPathComponent("running.json"))
    }

    // MARK: Lifecycle

    func start() async {
        reaper.reap()
        switch TunnelFile.load(from: fileURL, now: .now) {
        case .loaded(let loaded): file = loaded
        case .missing: file = TunnelFile()
        case .newerSchema(let loaded):
            file = loaded
            readOnly = true
            banner = "tunnels.json was written by a newer Burrow. Changes won't be saved."
        case .broken(let backup):
            file = TunnelFile()
            banner = "tunnels.json couldn't be read, so it was moved to \(backup.lastPathComponent)."
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let path = await ToolLocator.loginShellPath(shell: shell)
        runner = SystemRunner(path: path)
        tools = ToolPaths(searchPath: path, overrides: file.toolPaths)

        for tunnel in file.tunnels { makeSupervisor(for: tunnel) }
        for (id, start) in claims.planLogin(file.tunnels) {
            switch start {
            case .start: await supervisors[id]?.turnOn()
            case .blocked(let holder):
                blockedBy[id] = holder
                await supervisors[id]?.blockByOtherTunnel()
            }
        }
    }

    /// Sample tunnels with fixed states and no processes, for screenshots (BURROW_DEMO=1). Nothing is saved.
    func loadDemo() {
        readOnly = true
        let now = Date.now
        func ssh(_ host: String, _ dest: String, _ port: Int) -> TunnelMethod {
            .ssh(SSHConfig(mode: .local, host: host, destination: Endpoint(host: dest, port: port)))
        }
        let demo: [(Tunnel, TunnelState)] = [
            (Tunnel(name: "Postgres", group: "Staging", localPort: 5432, method: ssh("bastion", "db.staging.internal", 5432)),
             .connected(since: now.addingTimeInterval(-8040))),
            (Tunnel(name: "Redis", group: "Staging", localPort: 16379, method: ssh("bastion", "redis.staging.internal", 6379)),
             .connected(since: now.addingTimeInterval(-8040))),
            (Tunnel(name: "Orders MySQL", group: "Production", localPort: 3306, method: .ssm(SSMConfig(
                profile: "prod", region: "ap-southeast-1", target: "i-0a3f5c9e2b7d41f08",
                forwardTo: .remoteHost(Endpoint(host: "orders.cluster-ro.internal", port: 3306))))),
             .retrying(.hostUnreachable, attempt: 3, until: now.addingTimeInterval(8))),
            (Tunnel(name: "ClickHouse", group: "Production", localPort: 8123, method: .kubernetes(KubeConfig(
                context: "prod", namespace: "analytics", resource: "svc/clickhouse", remotePort: 8123))),
             .blocked(PortOwner(pid: 4411, command: "clickhouse-server"))),
            (Tunnel(name: "Grafana", group: "Production", localPort: 3000, method: .kubernetes(KubeConfig(
                context: "prod", namespace: "monitoring", resource: "svc/grafana", remotePort: 3000))),
             .connected(since: now.addingTimeInterval(-420))),
            (Tunnel(name: "SOCKS Proxy", group: "Other", localPort: 1080, method: .ssh(SSHConfig(mode: .dynamic, host: "jump"))),
             .off),
        ]
        file = TunnelFile(groups: ["Staging", "Production", "Other"], tunnels: demo.map(\.0))
        states = Dictionary(uniqueKeysWithValues: demo.map { ($0.0.id, $0.1) })
    }

    /// Called at quit: stops every child process before the app exits.
    func stopAllNow() {
        reaper.stopAll()
    }

    private func makeSupervisor(for tunnel: Tunnel) {
        let supervisor = Supervisor(tunnel: tunnel, tools: tools, ports: ports, runner: runner,
                                    reaper: reaper, clock: ContinuousClock())
        supervisors[tunnel.id] = supervisor
        states[tunnel.id] = .off
        let stream = supervisor.states
        Task { [weak self] in
            for await state in stream { self?.states[tunnel.id] = state }
        }
    }

    // MARK: Commands

    func state(of id: UUID) -> TunnelState { states[id] ?? .off }

    func toggle(_ id: UUID) async {
        if state(of: id).isOn { await turnOff(id) } else { await turnOn(id) }
    }

    func turnOn(_ id: UUID) async {
        guard let tunnel = tunnel(id), let supervisor = supervisors[id] else { return }
        if let holder = claims.claim(tunnel.localPort, by: id) {
            blockedBy[id] = holder
            await supervisor.blockByOtherTunnel()
        } else {
            blockedBy[id] = nil
            await supervisor.turnOn()
        }
    }

    func turnOff(_ id: UUID) async {
        guard let tunnel = tunnel(id) else { return }
        blockedBy[id] = nil
        await supervisors[id]?.turnOff()
        claims.release(tunnel.localPort, by: id)
        // Hand the port to the next tunnel waiting for it.
        if let waiting = blockedBy.first(where: { $0.value == id })?.key {
            await turnOn(waiting)
        }
    }

    func startAll() async {
        for tunnel in file.tunnels where !state(of: tunnel.id).isOn { await turnOn(tunnel.id) }
    }

    func stopAll() async {
        for tunnel in file.tunnels where state(of: tunnel.id).isOn { await turnOff(tunnel.id) }
    }

    func kickAll() async {
        for supervisor in supervisors.values { await supervisor.kick() }
    }

    func setNetworkAvailable(_ available: Bool) async {
        for supervisor in supervisors.values { await supervisor.setNetworkAvailable(available) }
    }

    func retry(_ id: UUID) async { await supervisors[id]?.kick() }

    func save(_ tunnel: Tunnel) async {
        if let index = file.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            let old = file.tunnels[index]
            file.tunnels[index] = tunnel
            persist()
            if old.localPort != tunnel.localPort, state(of: tunnel.id).isOn {
                claims.release(old.localPort, by: tunnel.id)
                _ = claims.claim(tunnel.localPort, by: tunnel.id)
            }
            await supervisors[tunnel.id]?.update(tunnel)
        } else {
            file.tunnels.append(tunnel)
            persist()
            makeSupervisor(for: tunnel)
        }
    }

    func delete(_ id: UUID) async {
        await turnOff(id)
        supervisors[id] = nil
        states[id] = nil
        file.tunnels.removeAll { $0.id == id }
        persist()
    }

    func useAlternatePort(_ id: UUID) async {
        guard var tunnel = tunnel(id) else { return }
        let ports = self.ports
        tunnel.localPort = PortProbe.alternate(for: tunnel.localPort) { candidate in
            ports.isFree(candidate) && self.claims.holder(of: candidate) == nil
        }
        claims.release(file.tunnels.first { $0.id == id }!.localPort, by: id)
        await save(tunnel)
        await turnOn(id)
    }

    /// `aws sso login` for an expired SSM profile, then retry.
    func signIn(_ id: UUID) async {
        guard let tunnel = tunnel(id), case .ssm(let c) = tunnel.method, let aws = tools.url(for: "aws") else { return }
        _ = try? await ToolLocator.captureOutput(aws, ["sso", "login", "--profile", c.profile])
        await supervisors[id]?.kick()
    }

    func setToolOverride(_ tool: String, path: String) {
        file.toolPaths[tool] = path.isEmpty ? nil : path
        tools = ToolPaths(searchPath: tools.searchPath, overrides: file.toolPaths)
        persist()
        let tools = self.tools
        for supervisor in supervisors.values { Task { await supervisor.setTools(tools) } }
    }

    /// Runs a tunnel once until it connects or fails, then stops it. Used by Test Connection.
    func test(_ tunnel: Tunnel) async -> (state: TunnelState, log: [String]) {
        var probe = tunnel
        probe.id = UUID()
        let supervisor = Supervisor(tunnel: probe, tools: tools, ports: ports, runner: runner,
                                    reaper: reaper, clock: ContinuousClock())
        await supervisor.turnOn()
        for await state in supervisor.states {
            switch state {
            case .connected, .failed, .blocked, .retrying:
                await supervisor.turnOff()
                return (state, supervisor.log.lines)
            default:
                continue
            }
        }
        return (.off, supervisor.log.lines)
    }

    func log(for id: UUID) -> [String] { supervisors[id]?.log.lines ?? [] }

    func tunnel(_ id: UUID) -> Tunnel? { file.tunnels.first { $0.id == id } }

    func statusText(_ id: UUID, now: Date = .now) -> String {
        guard let tunnel = tunnel(id) else { return "" }
        let holderName = blockedBy[id].flatMap { self.tunnel($0)?.name }
        return statusLine(state(of: id), tunnel: tunnel, now: now, blockedBy: holderName)
    }

    var connectedCount: Int { states.values.filter { if case .connected = $0 { true } else { false } }.count }
    var needsAttention: Bool { states.values.contains(where: \.needsAttention) }

    private func persist() {
        guard !readOnly else { return }
        do {
            try file.save(to: fileURL)
        } catch {
            banner = "Couldn't save tunnels.json: \(error.localizedDescription)"
        }
    }
}
