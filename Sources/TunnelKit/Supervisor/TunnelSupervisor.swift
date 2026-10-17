import Foundation

/// Runs one tunnel through the states of spec §5.1: checks the port, launches the CLI, waits for
/// the local port to accept connections, health-checks it, and retries with backoff.
///
/// On demand (`Tunnel.runsOnDemand`), switching on only opens a `TCPProxy` on the local port. The
/// first app to connect starts the process on an internal port, and it stops again after
/// `idleMinutes` with no connections.
public actor TunnelSupervisor<C: Clock> where C.Duration == Duration {
    public private(set) var tunnel: Tunnel
    public private(set) var state: TunnelState = .off {
        didSet {
            guard state != oldValue else { return }
            continuation.yield(state)
            answerWaitingClients()
        }
    }
    /// Every state change, in order.
    public nonisolated let states: AsyncStream<TunnelState>
    public nonisolated let log = LogBuffer()
    public nonisolated let id: UUID

    private let continuation: AsyncStream<TunnelState>.Continuation
    private var tools: ToolPaths
    private let ports: any PortChecking
    private let runner: any ProcessRunning
    private let reaper: OrphanReaper
    private let clock: C
    private let now: @Sendable () -> Date
    private let pickInternalPort: @Sendable () -> Int

    private var loop: Task<Void, Never>?
    private var current: (any RunningProcess)?
    private var wantsOn = false
    private var networkAvailable = true
    private var backoff = Backoff()
    private var attempt = 0

    // On demand
    private var proxy: TCPProxy?
    /// Where the process listens while the proxy holds the tunnel's port.
    private var internalPort: Int?
    private var idleTimer: Task<Void, Never>?
    /// Clients waiting for the process to connect, answered with the internal port or nil.
    private var waitingClients: [UUID: CheckedContinuation<Int?, Never>] = [:]

    static var readinessPoll: Duration { .milliseconds(250) }
    static var readinessPolls: Int { 80 }  // 20 s
    static var healthEvery: Int { 10 }     // seconds between probes
    static var resetAfter: Duration { .seconds(60) }
    static var clientWait: Duration { .seconds(30) }

    public init(
        tunnel: Tunnel, tools: ToolPaths, ports: any PortChecking, runner: any ProcessRunning,
        reaper: OrphanReaper, clock: C, now: @escaping @Sendable () -> Date = Date.init,
        pickInternalPort: @escaping @Sendable () -> Int = PortProbe.ephemeralPort
    ) {
        self.tunnel = tunnel
        self.id = tunnel.id
        self.tools = tools
        self.ports = ports
        self.runner = runner
        self.reaper = reaper
        self.clock = clock
        self.now = now
        self.pickInternalPort = pickInternalPort
        (states, continuation) = AsyncStream.makeStream(of: TunnelState.self)
    }

    // MARK: Commands

    public func turnOn() async {
        guard !wantsOn else { return }
        wantsOn = true
        resetRetries()
        if tunnel.runsOnDemand { await standBy() } else { startLoop() }
    }

    public func turnOff() async {
        wantsOn = false
        await shutDown()
        state = .off
    }

    /// Skip any remaining wait and check again now (wake, network back, user retry).
    public func kick() async {
        guard wantsOn else { return }
        await stopLoop()
        resetRetries()
        guard tunnel.runsOnDemand else { return startLoop() }
        if let proxy {
            // Start again only for clients still connected; otherwise wait for the next one.
            if proxy.activeCount > 0 { startLoop() } else { state = .standingBy }
        } else {
            await standBy()
        }
    }

    public func setNetworkAvailable(_ available: Bool) async {
        networkAvailable = available
        if available, wantsOn, case .retrying = state { await kick() }
    }

    public func update(_ tunnel: Tunnel) async {
        guard wantsOn else {
            self.tunnel = tunnel
            return
        }
        // The port or on-demand setting may have changed, so the listener restarts too.
        await shutDown()
        self.tunnel = tunnel
        wantsOn = false
        await turnOn()
    }

    public func setTools(_ tools: ToolPaths) {
        self.tools = tools
    }

    // MARK: Loop

    private func resetRetries() {
        attempt = 0
        backoff.reset()
    }

    private func startLoop() {
        if tunnel.runsOnDemand, internalPort == nil { internalPort = pickInternalPort() }
        loop = Task { await self.run() }
    }

    /// Stops the process and, on demand, the listener and idle timer.
    private func shutDown() async {
        idleTimer?.cancel()
        idleTimer = nil
        await stopLoop()
        proxy?.stop()
        proxy = nil
        internalPort = nil
    }

    private func stopLoop() async {
        loop?.cancel()
        await loop?.value
        loop = nil
        await stopProcess()
    }

    private func stopProcess() async {
        guard let process = current else { return }
        current = nil
        await process.terminate()
        reaper.forget(pid: process.pid)
    }

    private var hasLocalPort: Bool {
        if case .ssh(let c) = tunnel.method, c.mode == .remote { return false }
        return true
    }

    private enum Outcome {
        case exited(Int32)
        case readinessTimeout
        case stoppedResponding
        case cancelled
    }

    /// The tunnel as its process runs it: on demand, on the internal port.
    private var processTunnel: Tunnel {
        guard tunnel.runsOnDemand, let internalPort else { return tunnel }
        var copy = tunnel
        copy.localPort = internalPort
        return copy
    }

    private func run() async {
        while !Task.isCancelled {
            state = .checking
            let processTunnel = self.processTunnel
            let port = processTunnel.localPort

            if hasLocalPort, !ports.isFree(port) {
                let owner = await ports.owner(of: port)
                if !Task.isCancelled { state = .blocked(owner) }
                return
            }

            let invocation: Invocation
            do {
                invocation = try CommandBuilder.invocation(for: processTunnel, tools: tools)
            } catch {
                state = .failed(.toolMissing(error))
                return
            }

            let process: any RunningProcess
            do {
                process = try runner.launch(invocation, log: log)
            } catch {
                log.append("Could not start \(invocation.executable.path): \(error)")
                state = .failed(.unknown(status: -1))
                return
            }
            current = process
            reaper.record(pid: process.pid, startTime: OrphanReaper.startTime(of: process.pid))
            state = .starting

            let outcome = await connect(process, port: port)
            if case .cancelled = outcome { return }  // stopLoop() stops the process
            if Task.isCancelled { return }
            if case .exited = outcome {
                // Let the pipe drain so the classifier sees the last lines.
                try? await Task.sleep(for: .milliseconds(100))
            }
            await stopProcess()

            let reason = failureReason(for: outcome)
            if reason == .portInUse {
                let owner = await ports.owner(of: port)
                if !Task.isCancelled { state = .blocked(owner) }
                return
            }
            guard reason.isRetryable else {
                state = .failed(reason)
                return
            }

            attempt += 1
            let delay = backoff.next()
            state = .retrying(reason, attempt: attempt, until: now().addingTimeInterval(TimeInterval(delay.components.seconds)))
            do {
                try await clock.sleep(for: delay)
                // Offline: wait without spending attempts; setNetworkAvailable(true) kicks us.
                while !networkAvailable { try await clock.sleep(for: .seconds(1)) }
            } catch {
                return
            }
        }
    }

    private func connect(_ process: any RunningProcess, port: Int) async -> Outcome {
        do {
            if hasLocalPort {
                var ready = false
                for _ in 0..<Self.readinessPolls {
                    if let status = process.exitStatus { return .exited(status) }
                    if await ports.accepts(port) { ready = true; break }
                    try await clock.sleep(for: Self.readinessPoll)
                }
                if !ready { return .readinessTimeout }
            } else {
                try await clock.sleep(for: .seconds(3))
                if let status = process.exitStatus { return .exited(status) }
            }
            if Task.isCancelled { return .cancelled }

            state = .connected(since: now())
            let connectedAt = clock.now
            defer {
                if connectedAt.duration(to: clock.now) >= Self.resetAfter { resetRetries() }
            }

            var misses = 0
            var seconds = 0
            while true {
                try await clock.sleep(for: .seconds(1))
                if let status = process.exitStatus { return .exited(status) }
                seconds += 1
                guard hasLocalPort, seconds % Self.healthEvery == 0 else { continue }
                if await ports.accepts(port) {
                    misses = 0
                } else {
                    misses += 1
                    if misses >= 2 { return .stoppedResponding }
                }
            }
        } catch {
            return .cancelled
        }
    }

    private func failureReason(for outcome: Outcome) -> FailureReason {
        var profile: String?
        if case .ssm(let c) = tunnel.method { profile = c.profile }
        switch outcome {
        case .exited(let status):
            return FailureClassifier.classify(stderr: log.tail(50), status: status, profile: profile)
        case .readinessTimeout:
            let classified = FailureClassifier.classify(stderr: log.tail(50), status: 0, profile: profile)
            if case .unknown = classified { return .readinessTimeout }
            return classified
        case .stoppedResponding, .cancelled:
            return .stoppedResponding
        }
    }

    // MARK: On demand

    /// Listens on the tunnel's port, without starting the process.
    private func standBy() async {
        state = .checking
        let port = tunnel.localPort
        if !ports.isFree(port) {
            let owner = await ports.owner(of: port)
            if wantsOn { state = .blocked(owner) }
            return
        }
        let proxy = TCPProxy(
            upstream: { [weak self] in await self?.upstreamForClient() },
            onActiveChange: { [weak self] in Task { await self?.clientsChanged() } })
        do {
            try await proxy.start(port: port)
        } catch {
            log.append("Could not listen on 127.0.0.1:\(port): \(error)")
            let owner = await ports.owner(of: port)
            if wantsOn { state = .blocked(owner) }
            return
        }
        // Switched off while the listener was starting.
        guard wantsOn, self.proxy == nil else {
            proxy.stop()
            return
        }
        self.proxy = proxy
        log.append("Listening on 127.0.0.1:\(port); starts when an app connects.")
        state = .standingBy
    }

    /// Asked by the proxy for each new client: starts the process if it isn't running and waits up
    /// to `clientWait` for it to connect. Nil closes the client.
    private func upstreamForClient() async -> Int? {
        guard wantsOn else { return nil }
        idleTimer?.cancel()
        idleTimer = nil
        switch state {
        case .connected: return internalPort
        case .off, .blocked, .failed: return nil
        case .standingBy:
            resetRetries()
            startLoop()
        case .checking, .starting, .retrying:
            break
        }
        let id = UUID()
        let timeout = Task { [clock] in
            try? await clock.sleep(for: Self.clientWait)
            self.answer(id, with: nil)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { waitingClients[id] = $0 }
    }

    private func answer(_ id: UUID, with port: Int?) {
        waitingClients.removeValue(forKey: id)?.resume(returning: port)
    }

    private func answerWaitingClients() {
        let port: Int?
        switch state {
        case .connected: port = internalPort
        case .off, .blocked, .failed, .standingBy: port = nil
        case .checking, .starting, .retrying: return
        }
        let waiting = waitingClients.values
        waitingClients = [:]
        waiting.forEach { $0.resume(returning: port) }
    }

    /// Whether the process is running or being started (not idle, failed or off).
    private var processActive: Bool {
        switch state {
        case .checking, .starting, .connected, .retrying: proxy != nil
        case .off, .blocked, .failed, .standingBy: false
        }
    }

    var idleTimerRunning: Bool { idleTimer != nil }

    private func clientsChanged() {
        guard let proxy else { return }
        if proxy.activeCount > 0 {
            idleTimer?.cancel()
            idleTimer = nil
            return
        }
        guard idleTimer == nil, processActive, tunnel.idleMinutes > 0 else { return }
        let wait = Duration.seconds(tunnel.idleMinutes * 60)
        idleTimer = Task { [clock] in
            do { try await clock.sleep(for: wait) } catch { return }
            await self.stopIdleProcess()
        }
    }

    private func stopIdleProcess() async {
        idleTimer = nil
        guard wantsOn, processActive, proxy?.activeCount == 0 else { return }
        log.append("No connections for \(tunnel.idleMinutes) min; stopping until an app connects.")
        await stopLoop()
        state = .standingBy
    }
}
