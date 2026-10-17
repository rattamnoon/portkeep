import Clocks
import Darwin
import Foundation
import Testing
@testable import TunnelKit

/// Echoes every byte back on 127.0.0.1:<port> until stopped, standing in for the tunnel's process.
private final class EchoServer: @unchecked Sendable {
    let port: Int
    private let fd: Int32

    init() throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let fd = self.fd
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && Darwin.listen(fd, 8) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        try #require(ok)
        port = Int(UInt16(bigEndian: addr.sin_port))
        Thread.detachNewThread {
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                Thread.detachNewThread {
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while true {
                        let n = read(client, &buffer, buffer.count)
                        if n <= 0 { break }
                        _ = write(client, buffer, n)
                    }
                    close(client)
                }
            }
        }
    }

    func stop() {
        shutdown(fd, SHUT_RDWR)
        close(fd)
    }
}

/// A blocking client socket with a 5 s timeout on reads.
private struct Client {
    let fd: Int32

    init?(port: Int) {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        let fd = self.fd
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        if !ok {
            Darwin.close(fd)
            return nil
        }
    }

    /// Sends `text` and returns what comes back: "" when the other side closed instead.
    /// The blocking read runs on its own thread: on a Swift concurrency thread it would hold one of the
    /// few cooperative threads for up to 5 s, starving the proxy and supervisor it is waiting on.
    func roundTrip(_ text: String) async -> String {
        let fd = self.fd
        return await withCheckedContinuation { continuation in
            Thread.detachNewThread {
                _ = text.withCString { write(fd, $0, strlen($0)) }
                var buffer = [UInt8](repeating: 0, count: 256)
                let n = read(fd, &buffer, buffer.count)
                continuation.resume(returning: n > 0 ? String(decoding: buffer[..<n], as: UTF8.self) : "")
            }
        }
    }

    func close() { Darwin.close(fd) }
}

/// Polls `condition` for up to 5 s of real time.
private func eventually(_ condition: () async -> Bool) async -> Bool {
    for _ in 0..<500 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

@Test func proxyPipesBytesBothWays() async throws {
    let echo = try EchoServer()
    defer { echo.stop() }
    let proxy = TCPProxy(upstream: { echo.port })
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }

    let client = try #require(Client(port: port))
    #expect(await client.roundTrip("hello") == "hello")
    #expect(proxy.activeCount == 1)
    client.close()
    #expect(await eventually { proxy.activeCount == 0 })
}

@Test func proxyClosesClientWithoutUpstream() async throws {
    let proxy = TCPProxy(upstream: { nil })
    let port = try await proxy.start(port: 0)
    defer { proxy.stop() }

    let client = try #require(Client(port: port))
    defer { client.close() }
    #expect(await client.roundTrip("hello") == "")
    #expect(await eventually { proxy.activeCount == 0 })
}

@Test func proxyFailsOnATakenPort() async throws {
    let echo = try EchoServer()
    defer { echo.stop() }
    let proxy = TCPProxy(upstream: { nil })
    await #expect(throws: (any Error).self) { try await proxy.start(port: echo.port) }
}

@Test func proxyStopRefusesNewClients() async throws {
    let proxy = TCPProxy(upstream: { nil })
    let port = try await proxy.start(port: 0)
    proxy.stop()
    #expect(await eventually { Client(port: port).map { $0.close(); return false } ?? true })
}

private final class OnDemandHarness {
    let ports = FakePorts()
    let runner = FakeRunner()
    let clock = TestClock<Duration>()
    let echo: EchoServer
    private(set) var port = PortProbe.ephemeralPort()
    private var tunnel: Tunnel
    let supervisor: TunnelSupervisor<TestClock<Duration>>

    init(idleMinutes: Int = 1) throws {
        let echo = try EchoServer()
        self.echo = echo
        tunnel = Tunnel(
            name: "db", group: "UAT", localPort: port,
            method: .ssh(SSHConfig(mode: .local, host: "jump", destination: Endpoint(host: "db", port: 5432))),
            startsOnConnect: true, idleMinutes: idleMinutes)
        supervisor = TunnelSupervisor(
            tunnel: tunnel,
            tools: ToolPaths(searchPath: "/opt/homebrew/bin", overrides: [:], isExecutable: { _ in true }),
            ports: ports, runner: runner,
            reaper: OrphanReaper(file: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json")),
            clock: clock, pickInternalPort: { echo.port })
    }

    var state: TunnelState { get async { await supervisor.state } }

    /// Switches on and waits for Standing by, moving to another port if a test running in parallel took this one.
    func turnOn() async {
        for _ in 0..<5 {
            await supervisor.turnOn()
            guard case .blocked = await state else { return }
            await supervisor.turnOff()
            port = PortProbe.ephemeralPort()
            tunnel.localPort = port
            await supervisor.update(tunnel)
        }
    }

    func advance(_ duration: Duration, step: Duration = .seconds(1)) async {
        var left = duration
        while left > .zero {
            let next = min(step, left)
            await clock.advance(by: next)
            await settle()
            left -= next
        }
    }
}

@Test func onDemandStandsByUntilAClientConnects() async throws {
    let h = try OnDemandHarness()
    defer { h.echo.stop() }
    await h.turnOn()
    #expect(await h.state == .standingBy)
    #expect(h.runner.launches.isEmpty)

    let client = try #require(Client(port: h.port))
    // The process starts on the internal port, and the client's bytes reach it once it connects.
    #expect(await client.roundTrip("ping") == "ping")
    #expect(h.runner.launches.count == 1)
    if case .connected = await h.state {} else { Issue.record("expected connected, got \(await h.state)") }
    client.close()
    await h.supervisor.turnOff()
}

@Test func onDemandStopsAfterIdleAndStartsAgain() async throws {
    let h = try OnDemandHarness(idleMinutes: 1)
    defer { h.echo.stop() }
    await h.turnOn()

    let first = try #require(Client(port: h.port))
    #expect(await first.roundTrip("one") == "one")
    first.close()
    #expect(await eventually { await h.supervisor.idleTimerRunning })

    await h.advance(.seconds(59))
    #expect(h.runner.last?.terminated == false, "still inside the idle period")
    await h.advance(.seconds(2))
    #expect(await eventually { await h.state == .standingBy })
    #expect(h.runner.last?.terminated == true)

    let second = try #require(Client(port: h.port))
    #expect(await second.roundTrip("two") == "two")
    #expect(h.runner.launches.count == 2)
    second.close()
    await h.supervisor.turnOff()
}

@Test func onDemandWithZeroIdleNeverStops() async throws {
    let h = try OnDemandHarness(idleMinutes: 0)
    defer { h.echo.stop() }
    await h.turnOn()
    let client = try #require(Client(port: h.port))
    #expect(await client.roundTrip("x") == "x")
    client.close()
    try await Task.sleep(for: .milliseconds(200))
    #expect(await h.supervisor.idleTimerRunning == false)
    await h.advance(.seconds(15 * 60), step: .seconds(5))
    #expect(h.runner.last?.terminated == false)
    await h.supervisor.turnOff()
}

@Test func onDemandClientWaitsWhileTheProcessStarts() async throws {
    let h = try OnDemandHarness()
    defer { h.echo.stop() }
    // The port opens on the fifth readiness poll, a second after launch.
    h.ports.acceptsQueue = [false, false, false, false]
    await h.turnOn()

    let client = try #require(Client(port: h.port))
    let reply = Task { await client.roundTrip("wait") }
    #expect(await eventually { h.runner.launches.count == 1 })
    await h.advance(.seconds(2), step: .milliseconds(250))
    #expect(await reply.value == "wait")
    client.close()
    await h.supervisor.turnOff()
}

@Test func onDemandTurnOffClosesTheListener() async throws {
    let h = try OnDemandHarness()
    defer { h.echo.stop() }
    await h.turnOn()
    await h.supervisor.turnOff()
    #expect(await h.state == .off)
    #expect(await eventually { Client(port: h.port).map { $0.close(); return false } ?? true })
}

@Test func onDemandOnlyForLocalListeners() {
    func tunnel(_ method: TunnelMethod) -> Tunnel {
        Tunnel(name: "t", group: "g", localPort: 1, method: method, startsOnConnect: true)
    }
    #expect(tunnel(.ssh(SSHConfig(mode: .local, host: "h"))).runsOnDemand)
    #expect(tunnel(.ssh(SSHConfig(mode: .dynamic, host: "h"))).runsOnDemand)
    #expect(!tunnel(.ssh(SSHConfig(mode: .remote, host: "h"))).runsOnDemand)
    #expect(tunnel(.custom(CustomConfig(command: "serve --port {port}"))).runsOnDemand)
    #expect(!tunnel(.custom(CustomConfig(command: "serve --port 8080"))).runsOnDemand)
}

@Test func onDemandSettingsDecodeAsOffWhenMissing() throws {
    let json = #"{"id":"6F1C2B8E-3D4A-4E5F-8A9B-0C1D2E3F4A5B","name":"n","group":"g","localPort":1,"method":{"cloudflare":{"hostname":"h"}}}"#
    let tunnel = try JSONDecoder().decode(Tunnel.self, from: Data(json.utf8))
    #expect(tunnel.startsOnConnect == false)
    #expect(tunnel.idleMinutes == 10)
    let again = try JSONDecoder().decode(Tunnel.self, from: JSONEncoder().encode(
        Tunnel(name: "n", group: "g", localPort: 1, method: tunnel.method, startsOnConnect: true, idleMinutes: 3)))
    #expect(again.startsOnConnect && again.idleMinutes == 3)
}
