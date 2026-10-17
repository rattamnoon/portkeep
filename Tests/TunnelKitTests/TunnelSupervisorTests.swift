import Foundation
import Testing
@testable import TunnelKit

private let base = Date(timeIntervalSince1970: 1_800_000_000)

/// Drives a supervisor without guessing at timing. The supervisor's loop runs in its own task, so
/// after each command the harness waits, on events rather than on time, until the loop has parked
/// on the clock or stopped and the state stream has caught up. Only then does it move the clock or
/// let the test look at the state.
private struct Harness {
    let ports = FakePorts()
    let runner = FakeRunner()
    let pulse = Pulse()
    let clock: ManualClock
    let reaper = OrphanReaper(file: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json"))
    let states = Recorder<TunnelState>()
    let supervisor: TunnelSupervisor<ManualClock>

    init(method: TunnelMethod = .ssh(SSHConfig(mode: .local, host: "jump", destination: Endpoint(host: "db", port: 5432)))) {
        clock = ManualClock(pulse: pulse)
        supervisor = TunnelSupervisor(
            tunnel: Tunnel(name: "db", group: "UAT", localPort: 5432, method: method),
            tools: ToolPaths(searchPath: "/opt/homebrew/bin", overrides: [:], isExecutable: { _ in true }),
            ports: ports, runner: runner, reaper: reaper, clock: clock, now: { base })
        let states = states, pulse = pulse, stream = supervisor.states
        Task {
            for await s in stream {
                states.append(s)
                pulse.ping()
            }
        }
    }

    var state: TunnelState { get async { await supervisor.state } }

    /// Waits until the supervisor has nothing left to do at the current time: its loop is asleep on
    /// the clock, or it has stopped (off, blocked, failed), and `states` has seen the latest state.
    /// While the state is still `leaving`, it isn't done yet (the loop was started but hasn't run).
    func quiesce(leaving: TunnelState? = nil) async {
        while true {
            let seen = pulse.generation
            let state = await supervisor.state
            let caughtUp = states.all.last == state || (states.all.isEmpty && state == .off)
            let parked = clock.hasSleepers || state.isStopped
            if caughtUp, parked, state != leaving { return }
            await pulse.wait(after: seen)
        }
    }

    func turnOn() async {
        await supervisor.turnOn()
        await quiesce(leaving: .off)
    }

    /// Moves the clock forward by `duration`, waking each sleep that falls due in order and letting
    /// the supervisor reach its next one before going on.
    func advance(_ duration: Duration) async {
        await quiesce()
        let target = clock.now.advanced(by: duration)
        while clock.fireNext(upTo: target) { await quiesce() }
        clock.set(now: target)
    }

    /// Gets to Connected: launch, port accepts on the first poll.
    func connect() async {
        await turnOn()
    }

    /// Make the current process die with `status` and let the supervisor notice on its next
    /// once-a-second check.
    func crash(_ status: Int32 = 1) async {
        runner.last?.exit(status)
        await advance(.seconds(1))
    }
}

private extension TunnelState {
    /// No loop is running, so nothing will change until the test does something.
    var isStopped: Bool {
        switch self {
        case .off, .blocked, .failed, .standingBy: true
        case .checking, .starting, .connected, .retrying: false
        }
    }
}

@Test func happyPath() async {
    let h = Harness()
    h.ports.acceptsQueue = [false, false]
    await h.turnOn()
    await h.advance(.milliseconds(500))
    #expect(h.states.all == [.checking, .starting, .connected(since: base)])
}

@Test func blockedWhenPortTaken() async {
    let h = Harness()
    h.ports.free = false
    h.ports.owner = PortOwner(pid: 4411, command: "clickhouse-server")
    await h.turnOn()
    #expect(h.states.all == [.checking, .blocked(PortOwner(pid: 4411, command: "clickhouse-server"))])
    #expect(h.runner.launches.isEmpty)
}

@Test func toolMissingFails() async {
    let h = Harness(method: .ssm(SSMConfig(profile: "p", region: "r", target: "i", forwardTo: .instance(port: 22))))
    await h.supervisor.setTools(ToolPaths(searchPath: "/x", overrides: [:], isExecutable: { $0.hasSuffix("/aws") }))
    await h.turnOn()
    #expect(await h.state == .failed(.toolMissing(ToolMissing(tool: "session-manager-plugin", installHint: "brew install --cask session-manager-plugin"))))
}

@Test func readinessTimeoutRetries() async {
    let h = Harness()
    h.ports.acceptsDefault = false
    await h.turnOn()
    await h.advance(.seconds(20))
    #expect(await h.state == .retrying(.readinessTimeout, attempt: 1, until: base.addingTimeInterval(1)))
    #expect(h.runner.launches[0].terminated)
}

@Test func backoffSequence() async {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.turnOn()
    var waits: [TimeInterval] = []
    for _ in 0..<7 {
        guard case .retrying(_, _, let until) = await h.state else {
            Issue.record("expected retrying, got \(await h.state)"); return
        }
        let wait = until.timeIntervalSince(base)
        waits.append(wait)
        await h.advance(.seconds(wait))
    }
    #expect(waits == [1, 2, 4, 8, 16, 30, 60])
}

@Test func nonRetryableFails() async {
    let h = Harness()
    h.runner.onLaunch = { p, log in
        log.append("user@jump: Permission denied (publickey).")
        p.exit(255)
    }
    await h.turnOn()
    #expect(await h.state == .failed(.authFailed))
    await h.advance(.seconds(120))
    #expect(h.runner.launches.count == 1)
}

@Test func healthTwoMisses() async {
    let h = Harness()
    await h.connect()
    h.ports.acceptsDefault = false
    await h.advance(.seconds(10))
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(10))
    #expect(await h.state == .retrying(.stoppedResponding, attempt: 1, until: base.addingTimeInterval(1)))
}

@Test func backoffResetsAfter60sConnected() async {
    let h = Harness()
    await h.connect()
    await h.crash()
    #expect(await h.state == .retrying(.unknown(status: 1), attempt: 1, until: base.addingTimeInterval(1)))
    await h.advance(.seconds(1))
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(61))
    await h.crash()
    guard case .retrying(_, let attempt, let until) = await h.state else {
        Issue.record("expected retrying, got \(await h.state)"); return
    }
    #expect(attempt == 1)
    #expect(until == base.addingTimeInterval(1))
}

@Test func kickSkipsBackoff() async {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.turnOn()
    guard case .retrying = await h.state else { Issue.record("expected retrying"); return }
    #expect(h.runner.launches.count == 1)
    await h.supervisor.kick()
    await h.quiesce()
    #expect(h.runner.launches.count == 2, "relaunched without advancing the clock")
}

@Test func offlineDoesNotCountAttempts() async {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.turnOn()
    await h.supervisor.setNetworkAvailable(false)
    await h.advance(.seconds(300))
    #expect(await h.state == .retrying(.unknown(status: 1), attempt: 1, until: base.addingTimeInterval(1)))
    #expect(h.runner.launches.count == 1)

    h.runner.onLaunch = { _, _ in }
    await h.supervisor.setNetworkAvailable(true)
    await h.quiesce()
    #expect(h.runner.launches.count == 2)
}

@Test func wakeDuringStartingNeverDoublesProcesses() async {
    let h = Harness()
    h.ports.acceptsDefault = false
    await h.turnOn()
    #expect(await h.state == .starting)
    await h.supervisor.kick()
    await h.quiesce()
    #expect(h.runner.launches.count == 2)
    #expect(h.runner.launches[0].terminated)
    #expect(h.runner.maxLive == 1)
}

@Test func turnOffStops() async {
    let h = Harness()
    await h.connect()
    await h.supervisor.turnOff()
    await h.quiesce()
    #expect(await h.state == .off)
    #expect(h.runner.launches[0].terminated)
    #expect(h.reaper.recorded.isEmpty)
}

@Test func recordsPidForReaper() async {
    let h = Harness()
    await h.connect()
    #expect(h.reaper.recorded.keys.sorted() == [1000])
}

@Test func remoteForwardUsesLiveness() async {
    let h = Harness(method: .ssh(SSHConfig(mode: .remote, host: "jump", destination: Endpoint(host: "localhost", port: 3000))))
    h.ports.free = false  // a remote forward never checks or probes the local port
    h.ports.acceptsDefault = false
    await h.turnOn()
    #expect(await h.state == .starting)
    await h.advance(.seconds(3))
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(30))
    #expect(await h.state == .connected(since: base))
}
