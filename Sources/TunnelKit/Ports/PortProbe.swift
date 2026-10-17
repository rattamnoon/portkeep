import Darwin
import Foundation

public struct PortOwner: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }
}

public protocol PortChecking: Sendable {
    /// True when nothing is listening on 127.0.0.1:port.
    func isFree(_ port: Int) -> Bool
    /// True when a TCP connect to 127.0.0.1:port succeeds (ADR-0004).
    func accepts(_ port: Int) async -> Bool
    func owner(of port: Int) async -> PortOwner?
}

public struct SystemPorts: PortChecking {
    public init() {}

    public func isFree(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = Self.loopback(port)
        let error = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 ? 0 : errno
            }
        }
        if error == 0 { return true }
        // A tunnel stopped while a client was connected leaves its connections in TIME_WAIT for
        // about 30 s, which fails a plain bind. Nothing listens there, though: the next tunnel can have it.
        return error == EADDRINUSE && !Self.connects(port, timeoutMilliseconds: 250)
    }

    public func accepts(_ port: Int) async -> Bool {
        Self.connects(port, timeoutMilliseconds: 1000)
    }

    private static func connects(_ port: Int, timeoutMilliseconds: Int32) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = Self.loopback(port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMilliseconds) == 1 else { return false }
        var error: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &len)
        return error == 0
    }

    public func owner(of port: Int) async -> PortOwner? {
        let output = try? await ToolLocator.captureOutput(
            URL(fileURLWithPath: "/usr/sbin/lsof"), ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpcn"])
        return output.flatMap(PortProbe.parseLsof)
    }

    private static func loopback(_ port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = UInt16(port).bigEndian
        return addr
    }
}

public enum PortProbe {
    /// First process in `lsof -F pcn` output.
    public static func parseLsof(_ output: String) -> PortOwner? {
        var pid: Int32?
        for line in output.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int32(value)
            case "c": if let pid { return PortOwner(pid: pid, command: value) }
            default: break
            }
        }
        return nil
    }

    /// A port on 127.0.0.1 nothing listens on, picked by the system: where an on-demand tunnel's
    /// process listens while Portkeep holds the tunnel's own port.
    public static func ephemeralPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return 0 }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        return ok ? Int(UInt16(bigEndian: addr.sin_port)) : 0
    }

    /// The port to offer instead of a taken one (spec §5.4).
    public static func alternate(for port: Int, isFree: (Int) -> Bool) -> Int {
        if port + 10000 <= 65535, let free = (port + 10000...65535).first(where: isFree) {
            return free
        }
        return (20000...65535).first(where: isFree) ?? port
    }
}
