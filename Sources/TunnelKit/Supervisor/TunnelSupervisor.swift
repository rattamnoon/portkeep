import Foundation

/// Runs one tunnel through the states of spec §5.1: checks the port, launches the CLI, waits for
/// the local port to accept connections, health-checks it, and retries with backoff.
public actor TunnelSupervisor<C: Clock> where C.Duration == Duration {
    public private(set) var tunnel: Tunnel
    public private(set) var state: TunnelState = .off {
        didSet { if state != oldValue { continuation.yield(state) } }
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

    private var loop: Task<Void, Never>?
    private var current: (any RunningProcess)?
    private var wantsOn = false
    private var networkAvailable = true
    private var backoff = Backoff()
    private var attempt = 0

    static var readinessPoll: Duration { .milliseconds(250) }
    static var readinessPolls: Int { 80 }  // 20 s
    static var healthEvery: Int { 10 }     // seconds between probes
    static var resetAfter: Duration { .seconds(60) }

    public init(
        tunnel: Tunnel, tools: ToolPaths, ports: any PortChecking, runner: any ProcessRunning,
        reaper: OrphanReaper, clock: C, now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.tunnel = tunnel
        self.id = tunnel.id
        self.tools = tools
        self.ports = ports
        self.runner = runner
        self.reaper = reaper
        self.clock = clock
        self.now = now
        (states, continuation) = AsyncStream.makeStream(of: TunnelState.self)
    }

    // MARK: Commands

    public func turnOn() {
        guard !wantsOn else { return }
        wantsOn = true
        resetRetries()
        startLoop()
    }

    public func turnOff() async {
        wantsOn = false
        await stopLoop()
        state = .off
    }

    /// Skip any remaining wait and check again now (wake, network back, user retry).
    public func kick() async {
        guard wantsOn else { return }
        await stopLoop()
        resetRetries()
        startLoop()
    }

    public func setNetworkAvailable(_ available: Bool) async {
        networkAvailable = available
        if available, wantsOn, case .retrying = state { await kick() }
    }

    public func update(_ tunnel: Tunnel) async {
        self.tunnel = tunnel
        if wantsOn { await kick() }
    }

    public func setTools(_ tools: ToolPaths) {
        self.tools = tools
    }

    /// Marks the tunnel blocked because another tunnel holds its port; it stays on and
    /// starts when kicked after the other one lets go.
    public func blockByOtherTunnel() async {
        wantsOn = true
        await stopLoop()
        state = .blocked(nil)
    }

    // MARK: Loop

    private func resetRetries() {
        attempt = 0
        backoff.reset()
    }

    private func startLoop() {
        loop = Task { await self.run() }
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

    private func run() async {
        while !Task.isCancelled {
            state = .checking
            let port = tunnel.localPort

            if hasLocalPort, !ports.isFree(port) {
                let owner = await ports.owner(of: port)
                if !Task.isCancelled { state = .blocked(owner) }
                return
            }

            let invocation: Invocation
            do {
                invocation = try CommandBuilder.invocation(for: tunnel, tools: tools)
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
}
