import Clocks
import Foundation
import Testing
@testable import TunnelKit

private let base = Date(timeIntervalSince1970: 1_800_000_000)

private struct Harness {
    let ports = FakePorts()
    let runner = FakeRunner()
    let clock = TestClock<Duration>()
    let reaper = OrphanReaper(file: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json"))
    let states = Recorder<TunnelState>()
    let supervisor: TunnelSupervisor<TestClock<Duration>>

    init(method: TunnelMethod = .ssh(SSHConfig(mode: .local, host: "jump", destination: Endpoint(host: "db", port: 5432)))) {
        supervisor = TunnelSupervisor(
            tunnel: Tunnel(name: "db", group: "UAT", localPort: 5432, method: method),
            tools: ToolPaths(searchPath: "/opt/homebrew/bin", overrides: [:], isExecutable: { _ in true }),
            ports: ports, runner: runner, reaper: reaper, clock: clock, now: { base })
        let states = states, stream = supervisor.states
        Task { for await s in stream { states.append(s) } }
    }

    var state: TunnelState { get async { await supervisor.state } }

    /// Moves the test clock forward in 250 ms steps, letting the supervisor schedule its next wait
    /// after each one. A single big jump only fires the sleeps already registered, which on a busy
    /// CI runner can be none of them.
    func advance(_ duration: Duration) async {
        var left = duration
        while left > .zero {
            let step = min(.milliseconds(250), left)
            await clock.advance(by: step)
            await settle()
            left -= step
        }
    }

    /// Gets to Connected: launch, port accepts on the first poll.
    func connect() async {
        await supervisor.turnOn()
        await settle()
    }

    /// Make the current process die with `status` and let the supervisor react.
    func crash(_ status: Int32 = 1) async throws {
        runner.last?.exit(status)
        await advance(.seconds(1))
        try await Task.sleep(for: .milliseconds(200))
        await settle()
    }
}

@Test func happyPath() async {
    let h = Harness()
    h.ports.acceptsQueue = [false, false]
    await h.supervisor.turnOn()
    await settle()
    await h.advance(.milliseconds(500))
    await settle()
    #expect(h.states.all == [.checking, .starting, .connected(since: base)])
}

@Test func blockedWhenPortTaken() async {
    let h = Harness()
    h.ports.free = false
    h.ports.owner = PortOwner(pid: 4411, command: "clickhouse-server")
    await h.supervisor.turnOn()
    await settle()
    #expect(h.states.all == [.checking, .blocked(PortOwner(pid: 4411, command: "clickhouse-server"))])
    #expect(h.runner.launches.isEmpty)
}

@Test func toolMissingFails() async {
    let h = Harness(method: .ssm(SSMConfig(profile: "p", region: "r", target: "i", forwardTo: .instance(port: 22))))
    await h.supervisor.setTools(ToolPaths(searchPath: "/x", overrides: [:], isExecutable: { $0.hasSuffix("/aws") }))
    await h.supervisor.turnOn()
    await settle()
    #expect(await h.state == .failed(.toolMissing(ToolMissing(tool: "session-manager-plugin", installHint: "brew install --cask session-manager-plugin"))))
}

@Test func readinessTimeoutRetries() async {
    let h = Harness()
    h.ports.acceptsDefault = false
    await h.supervisor.turnOn()
    await settle()
    await h.advance(.seconds(20))
    await settle()
    #expect(await h.state == .retrying(.readinessTimeout, attempt: 1, until: base.addingTimeInterval(1)))
    #expect(h.runner.launches[0].terminated)
}

@Test func backoffSequence() async throws {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.supervisor.turnOn()
    var waits: [TimeInterval] = []
    for _ in 0..<7 {
        try await Task.sleep(for: .milliseconds(200))
        await settle()
        guard case .retrying(_, _, let until) = await h.state else {
            Issue.record("expected retrying, got \(await h.state)"); return
        }
        let wait = until.timeIntervalSince(base)
        waits.append(wait)
        await h.advance(.seconds(wait))
    }
    #expect(waits == [1, 2, 4, 8, 16, 30, 60])
}

@Test func nonRetryableFails() async throws {
    let h = Harness()
    h.runner.onLaunch = { p, log in
        log.append("user@jump: Permission denied (publickey).")
        p.exit(255)
    }
    await h.supervisor.turnOn()
    try await Task.sleep(for: .milliseconds(200))
    await settle()
    #expect(await h.state == .failed(.authFailed))
    await h.advance(.seconds(120))
    await settle()
    #expect(h.runner.launches.count == 1)
}

@Test func healthTwoMisses() async {
    let h = Harness()
    await h.connect()
    h.ports.acceptsDefault = false
    await h.advance(.seconds(10))
    await settle()
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(10))
    await settle()
    #expect(await h.state == .retrying(.stoppedResponding, attempt: 1, until: base.addingTimeInterval(1)))
}

@Test func backoffResetsAfter60sConnected() async throws {
    let h = Harness()
    await h.connect()
    try await h.crash()
    #expect(await h.state == .retrying(.unknown(status: 1), attempt: 1, until: base.addingTimeInterval(1)))
    await h.advance(.seconds(1))
    await settle()
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(61))
    await settle()
    try await h.crash()
    guard case .retrying(_, let attempt, let until) = await h.state else {
        Issue.record("expected retrying, got \(await h.state)"); return
    }
    #expect(attempt == 1)
    #expect(until == base.addingTimeInterval(1))
}

@Test func kickSkipsBackoff() async throws {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.supervisor.turnOn()
    try await Task.sleep(for: .milliseconds(200))
    await settle()
    guard case .retrying = await h.state else { Issue.record("expected retrying"); return }
    #expect(h.runner.launches.count == 1)
    await h.supervisor.kick()
    await settle()
    #expect(h.runner.launches.count == 2, "relaunched without advancing the clock")
}

@Test func offlineDoesNotCountAttempts() async throws {
    let h = Harness()
    h.runner.onLaunch = { p, _ in p.exit(1) }
    await h.supervisor.turnOn()
    try await Task.sleep(for: .milliseconds(200))
    await settle()
    await h.supervisor.setNetworkAvailable(false)
    await h.advance(.seconds(300))
    await settle()
    #expect(await h.state == .retrying(.unknown(status: 1), attempt: 1, until: base.addingTimeInterval(1)))
    #expect(h.runner.launches.count == 1)

    h.runner.onLaunch = { _, _ in }
    await h.supervisor.setNetworkAvailable(true)
    await settle()
    #expect(h.runner.launches.count == 2)
}

@Test func wakeDuringStartingNeverDoublesProcesses() async {
    let h = Harness()
    h.ports.acceptsDefault = false
    await h.supervisor.turnOn()
    await settle()
    #expect(await h.state == .starting)
    await h.supervisor.kick()
    await settle()
    #expect(h.runner.launches.count == 2)
    #expect(h.runner.launches[0].terminated)
    #expect(h.runner.maxLive == 1)
}

@Test func turnOffStops() async {
    let h = Harness()
    await h.connect()
    await h.supervisor.turnOff()
    await settle()
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
    await h.supervisor.turnOn()
    await settle()
    #expect(await h.state == .starting)
    await h.advance(.seconds(3))
    await settle()
    #expect(await h.state == .connected(since: base))
    await h.advance(.seconds(30))
    await settle()
    #expect(await h.state == .connected(since: base))
}
