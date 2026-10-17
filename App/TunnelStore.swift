import AppKit
import Foundation
import Observation
import ServiceManagement
import TunnelKit

/// The app's single source of truth: tunnel definitions, their live states, and the commands the UI sends.
@MainActor @Observable
final class TunnelStore {
    typealias Supervisor = TunnelSupervisor<ContinuousClock>

    private(set) var file = TunnelFile()
    private(set) var states: [UUID: TunnelState] = [:]
    var banner: String?
    private(set) var tools = ToolPaths(searchPath: ToolLocator.fallbackPath, overrides: [:])
    private(set) var readOnly = false

    @ObservationIgnored private var supervisors: [UUID: Supervisor] = [:]
    @ObservationIgnored private var claims = PortClaims()
    @ObservationIgnored private var runner: any ProcessRunning = SystemRunner(path: ToolLocator.fallbackPath)
    @ObservationIgnored let ports: any PortChecking = SystemPorts()
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let reaper: OrphanReaper
    @ObservationIgnored private let notifications = DropNotifications()

    var tunnels: [Tunnel] { file.tunnels }
    var groups: [String] {
        var seen = file.groups
        for t in file.tunnels where !seen.contains(t.group) { seen.append(t.group) }
        return seen
    }

    /// With PORTKEEP_DEBUG=1, commands and state changes are appended to debug.log beside tunnels.json (UI tests).
    @ObservationIgnored private let debugLog: URL?

    /// Tunnels the user has switched on (kept even while they retry or fail), saved to session.json
    /// so the next launch can turn the same ones back on.
    @ObservationIgnored private var wantedOn: Set<UUID> = []
    @ObservationIgnored private let sessionURL: URL

    /// Settings › General: turn back on what was on when Portkeep quit. On unless switched off.
    static var restoresOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "restoreTunnelsOnLaunch") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "restoreTunnelsOnLaunch") }
    }

    init(directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Portkeep")) {
        fileURL = directory.appendingPathComponent("tunnels.json")
        sessionURL = directory.appendingPathComponent("session.json")
        reaper = OrphanReaper(file: directory.appendingPathComponent("running.json"))
        debugLog = ProcessInfo.processInfo.environment["PORTKEEP_DEBUG"] == "1"
            ? directory.appendingPathComponent("debug.log") : nil
        notifications.lookup = { [weak self] id in
            guard let self, let tunnel = self.tunnel(id) else { return nil }
            return (tunnel.name, tunnel.localPort, self.statusText(id))
        }
    }

    private func debug(_ message: @autoclosure () -> String) {
        guard let debugLog else { return }
        let line = Data("\(Date.now.formatted(.iso8601)) \(message())\n".utf8)
        if let handle = try? FileHandle(forWritingTo: debugLog) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: debugLog)
        }
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
            banner = String(localized: "tunnels.json was written by a newer Portkeep. Changes won’t be saved.")
        case .broken(let backup):
            file = TunnelFile()
            banner = String(localized: "tunnels.json couldn’t be read, so it was moved to \(backup.lastPathComponent).")
        }

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let path = await ToolLocator.loginShellPath(shell: shell)
        debug("start: PATH=\(path)")
        runner = SystemRunner(path: path)
        tools = ToolPaths(searchPath: path, overrides: file.toolPaths)

        for tunnel in file.tunnels { makeSupervisor(for: tunnel) }
        let restore = Self.restoresOnLaunch ? loadSession() : []
        debug("start: restoring \(restore.count) tunnel(s)")
        // Two of them on one port: the first in the list starts, the other stays off.
        await switchOn(file.tunnels.filter { $0.connectAtLogin || restore.contains($0.id) }.map(\.id))
    }

    /// Sample tunnels with fixed states and no processes, for screenshots (PORTKEEP_DEMO=1). Nothing is saved.
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
        let demoTags: [[String]] = [["postgres"], ["redis"], ["mysql"], ["clickhouse"], ["metrics"], []]
        var tunnels = demo.map(\.0)
        for index in tunnels.indices { tunnels[index].tags = demoTags[index] }
        file = TunnelFile(groups: ["Staging", "Production", "Other"], tunnels: tunnels,
                          groupColors: ["Staging": "#34C759", "Production": "#FF3B30"])
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
        debug("supervisor created for \(tunnel.name)")
        Task { [weak self] in
            for await state in stream {
                self?.debug("\(tunnel.name): \(state)")
                self?.states[tunnel.id] = state
                self?.notifications.stateChanged(tunnel.id, to: state)
            }
        }
    }

    // MARK: Commands

    func state(of id: UUID) -> TunnelState { states[id] ?? .off }

    // MARK: Session (what was on)

    private func remember(_ id: UUID, on: Bool) {
        let changed = on ? wantedOn.insert(id).inserted : wantedOn.remove(id) != nil
        guard changed, !readOnly else { return }
        // Written straight away rather than at quit, so a crash or forced restart keeps it too.
        let ids = wantedOn.map(\.uuidString).sorted()
        try? JSONEncoder().encode(["on": ids]).write(to: sessionURL, options: .atomic)
    }

    private func loadSession() -> Set<UUID> {
        guard let data = try? Data(contentsOf: sessionURL),
              let saved = try? JSONDecoder().decode([String: [String]].self, from: data)
        else { return [] }
        let known = Set(file.tunnels.map(\.id))
        return Set((saved["on"] ?? []).compactMap(UUID.init(uuidString:))).intersection(known)
    }

    func toggle(_ id: UUID) async {
        debug("toggle \(id) from \(state(of: id))")
        if state(of: id).isOn { await turnOff(id) } else { await turnOn(id) }
    }

    /// Switching on a tunnel whose port another tunnel holds switches that one off first, so
    /// tunnels sharing a port act as one switch between environments.
    func turnOn(_ id: UUID) async {
        await switchOn([id])
    }

    /// Switches on `ids` together, one tunnel per local port (the first in list order wins).
    func switchOn(_ ids: [UUID]) async {
        let wanted = Set(ids)
        let plan = claims.planSwitchOn(file.tunnels.filter { wanted.contains($0.id) })
        for holder in plan.stop {
            debug("switchOn: stopping \(tunnel(holder)?.name ?? "?") to free its port")
            await turnOff(holder)
        }
        for id in plan.start {
            guard let tunnel = tunnel(id), let supervisor = supervisors[id] else {
                debug("turnOn \(id): no tunnel or supervisor")
                continue
            }
            remember(id, on: true)
            _ = claims.claim(tunnel.localPort, by: id)
            await supervisor.turnOn()
        }
    }

    func turnOff(_ id: UUID) async {
        guard let tunnel = tunnel(id) else { return }
        remember(id, on: false)
        await supervisors[id]?.turnOff()
        claims.release(tunnel.localPort, by: id)
    }

    func isOn(_ id: UUID) -> Bool { wantedOn.contains(id) || state(of: id).isOn }

    func startAll() async {
        await switchOn(file.tunnels.map(\.id))
    }

    func stopAll() async {
        for tunnel in file.tunnels where isOn(tunnel.id) { await turnOff(tunnel.id) }
    }

    func startGroup(_ group: String) async {
        await switchOn(file.tunnels.filter { $0.group == group }.map(\.id))
    }

    func stopGroup(_ group: String) async {
        for tunnel in file.tunnels where tunnel.group == group && isOn(tunnel.id) { await turnOff(tunnel.id) }
    }

    func kickAll() async {
        for supervisor in supervisors.values { await supervisor.kick() }
    }

    func setNetworkAvailable(_ available: Bool) async {
        for supervisor in supervisors.values { await supervisor.setNetworkAvailable(available) }
    }

    func retry(_ id: UUID) async { await supervisors[id]?.kick() }

    func save(_ tunnel: Tunnel) async {
        if !file.groups.contains(tunnel.group) { file.groups.append(tunnel.group) }
        if let index = file.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
            let old = file.tunnels[index]
            file.tunnels[index] = tunnel
            persist()
            if old.localPort != tunnel.localPort, state(of: tunnel.id).isOn {
                claims.release(old.localPort, by: tunnel.id)
                // Moving onto a port another running tunnel holds switches that one off, as turning on does.
                if let holder = claims.holder(of: tunnel.localPort) { await turnOff(holder) }
                _ = claims.claim(tunnel.localPort, by: tunnel.id)
            }
            // Only a change to how it connects restarts it; renaming or retagging doesn't.
            if old.localPort != tunnel.localPort || old.method != tunnel.method
                || old.startsOnConnect != tunnel.startsOnConnect || old.idleMinutes != tunnel.idleMinutes {
                await supervisors[tunnel.id]?.update(tunnel)
            }
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
        notifications.forget(id)
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

    // MARK: Groups, tags, colours
    // Labels don't change how a tunnel runs, so these edit the file without restarting anything.

    func setGroupColor(_ group: String, hex: String) {
        file.groupColors[group] = hex
        persist()
    }

    func setTagColor(_ tag: String, hex: String) {
        file.tagColors[tag] = hex
        persist()
    }

    func addGroup(_ name: String, hex: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !groups.contains(name) else { return }
        file.groups.append(name)
        file.groupColors[name] = hex
        persist()
    }

    /// Removes a group no tunnel is in.
    func deleteGroup(_ name: String) {
        guard !file.tunnels.contains(where: { $0.group == name }) else { return }
        file.groups.removeAll { $0 == name }
        file.groupColors[name] = nil
        persist()
    }

    func addTag(_ name: String, hex: String) {
        guard let name = Tunnel.parseTags(name).first,
              !file.allTags.contains(where: { $0.lowercased() == name.lowercased() }) else { return }
        file.tags.append(name)
        file.tagColors[name] = hex
        persist()
    }

    /// Removes a tag from the list and from every tunnel that has it.
    func deleteTag(_ name: String) {
        file.tags.removeAll { $0 == name }
        for index in file.tunnels.indices { file.tunnels[index].tags.removeAll { $0 == name } }
        file.tagColors[name] = nil
        persist()
    }

    func tunnelCount(inGroup group: String) -> Int { file.tunnels.filter { $0.group == group }.count }
    func tunnelCount(withTag tag: String) -> Int { file.tunnels.filter { $0.tags.contains(tag) }.count }

    func renameGroup(_ old: String, to new: String) {
        guard old != new else { return }
        for index in file.tunnels.indices where file.tunnels[index].group == old { file.tunnels[index].group = new }
        if let i = file.groups.firstIndex(of: old) {
            if file.groups.contains(new) { file.groups.remove(at: i) } else { file.groups[i] = new }
        }
        if let color = file.groupColors.removeValue(forKey: old), file.groupColors[new] == nil { file.groupColors[new] = color }
        persist()
    }

    func renameTag(_ old: String, to new: String) {
        guard old != new else { return }
        for index in file.tunnels.indices {
            file.tunnels[index].tags = Tunnel.parseTags(
                file.tunnels[index].tags.map { $0 == old ? new : $0 }.joined(separator: ","))
        }
        if let i = file.tags.firstIndex(of: old) {
            if file.tags.contains(new) { file.tags.remove(at: i) } else { file.tags[i] = new }
        }
        if let color = file.tagColors.removeValue(forKey: old), file.tagColors[new] == nil { file.tagColors[new] = color }
        persist()
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
        // Connect now, even for a tunnel that would wait for an app.
        probe.startsOnConnect = false
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
        return statusLine(state(of: id), tunnel: tunnel, now: now)
    }

    var connectedCount: Int { states.values.filter { if case .connected = $0 { true } else { false } }.count }
    var needsAttention: Bool { states.values.contains(where: \.needsAttention) }

    private func persist() {
        guard !readOnly else { return }
        do {
            try file.save(to: fileURL)
        } catch {
            banner = String(localized: "Couldn’t save tunnels.json: \(error.localizedDescription)")
        }
        updateLoginItem()
    }

    /// Portkeep opens at login only while some tunnel asks to connect at login (spec §5.5).
    private func updateLoginItem() {
        let wanted = file.tunnels.contains(where: \.connectAtLogin)
        let service = SMAppService.mainApp
        do {
            switch (wanted, service.status) {
            case (true, .notRegistered), (true, .notFound): try service.register()
            case (false, .enabled), (false, .requiresApproval): try service.unregister()
            default: break
            }
        } catch {
            banner = String(localized: "Couldn’t update the login item: \(error.localizedDescription)")
        }
    }
}
