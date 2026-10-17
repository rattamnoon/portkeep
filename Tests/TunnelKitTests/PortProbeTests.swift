import Darwin
import Foundation
import Testing
@testable import TunnelKit

@Test func parsesLsof() {
    #expect(PortProbe.parseLsof("p4411\ncclickhouse-server\nn127.0.0.1:8123\n") == PortOwner(pid: 4411, command: "clickhouse-server"))
    #expect(PortProbe.parseLsof("") == nil)
}

@Test func alternateAddsTenThousand() {
    #expect(PortProbe.alternate(for: 8123) { _ in true } == 18123)
    #expect(PortProbe.alternate(for: 8123) { $0 != 18123 } == 18124)
}

@Test func alternateWrapsHighPorts() {
    #expect(PortProbe.alternate(for: 60000) { _ in true } == 20000)
}

/// Opens a listening socket on an ephemeral port on 127.0.0.1 and returns (fd, port).
private func listen() throws -> (Int32, Int) {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = 0
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let ok = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, len) == 0 && Darwin.listen(fd, 4) == 0 && getsockname(fd, $0, &len) == 0
        }
    }
    try #require(ok)
    return (fd, Int(UInt16(bigEndian: addr.sin_port)))
}

@Test func bindDetectsListener() async throws {
    let ports = SystemPorts()
    let (fd, port) = try listen()
    #expect(ports.isFree(port) == false)
    #expect(await ports.accepts(port) == true)
    let owner = await ports.owner(of: port)
    #expect(owner?.pid == getpid())

    close(fd)
    #expect(ports.isFree(port) == true)
    #expect(await ports.accepts(port) == false)
}

/// Connects to a fresh listener, then closes the server side first, as when a tunnel stops under a
/// connected client. Returns the port, now holding only that connection. The port is below the
/// ephemeral range: there, other tests' port-0 listeners with SO_REUSEADDR can be handed it.
private func leaveTimeWait() throws -> (port: Int, client: Int32) {
    var listener: Int32 = -1
    var port = 0
    for candidate in (0..<20).map({ _ in Int.random(in: 20000..<30000) }) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(candidate).bigEndian
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 && Darwin.listen(fd, 4) == 0
            }
        }
        if ok { listener = fd; port = candidate; break }
        close(fd)
    }
    try #require(listener >= 0)
    let client = socket(AF_INET, SOCK_STREAM, 0)
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = UInt16(port).bigEndian
    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    try #require(connected)
    close(accept(listener, nil, nil))
    close(listener)
    return (port, client)
}

@Test func portWithOnlyTimeWaitConnectionsIsFree() async throws {
    let (port, client) = try leaveTimeWait()
    defer { close(client) }
    // A child spawned by a test running in parallel can hold the listener open for a moment.
    var free = false
    for _ in 0..<20 where !free {
        free = SystemPorts().isFree(port)
        if !free { try await Task.sleep(for: .milliseconds(50)) }
    }
    #expect(free)
}
