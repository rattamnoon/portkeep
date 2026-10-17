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
