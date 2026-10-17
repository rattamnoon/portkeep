import Darwin
import Foundation

/// `control.sock` in Portkeep's data folder: a Unix domain socket the running app listens on,
/// speaking newline-delimited JSON-RPC 2.0. Only the user who owns the app can connect (mode
/// 0600, and each peer's uid is checked).
public enum ControlSocket {
    public static let fileName = "control.sock"

    public static func path(in directory: URL) -> String {
        directory.appendingPathComponent(fileName).path
    }

    /// Portkeep's data folder: `PORTKEEP_DATA_DIR`, or ~/Library/Application Support/Portkeep.
    public static func dataDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = environment["PORTKEEP_DATA_DIR"], !dir.isEmpty { return URL(fileURLWithPath: dir) }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Portkeep")
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    static func address(_ path: String) throws(Failure) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else {
            throw Failure(description: "The socket path is too long (\(bytes.count) bytes, at most \(capacity - 1)): \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// A connected socket to `path`, or nil when nothing is listening there.
    static func connect(_ path: String) throws(Failure) -> Int32? {
        var address = try address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}

/// Reads newline-terminated lines from a file descriptor.
final class LineReader {
    private let fd: Int32
    private var buffer = Data()
    /// A longer line closes the connection: nothing legitimate is that big.
    static let maxLine = 4 << 20

    init(fd: Int32) { self.fd = fd }

    /// The next line without its newline; nil at end of file or on error.
    func next() -> Data? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard buffer.count < Self.maxLine else { return nil }
            var chunk = [UInt8](repeating: 0, count: 16384)
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EINTR { continue }
            if n <= 0 {
                // A last line without a newline still counts.
                if buffer.isEmpty { return nil }
                defer { buffer = Data() }
                return buffer
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

/// The app's side: accepts connections and answers each line with `handler`, in order per connection.
public final class ControlSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (Data) async -> Data?

    public let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private var stopped = false

    public init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    /// Binds the socket, replacing one left by an earlier run. Throws when another Portkeep is
    /// already listening there.
    public func start() throws(ControlSocket.Failure) {
        if let fd = try ControlSocket.connect(path) {
            close(fd)
            throw ControlSocket.Failure(description: "Another Portkeep is already listening on \(path).")
        }
        var info = stat()
        if lstat(path, &info) == 0 {
            // Only ever remove a stale socket, never a file someone put there.
            guard (info.st_mode & S_IFMT) == S_IFSOCK else {
                throw ControlSocket.Failure(description: "\(path) exists and isn't a socket.")
            }
            unlink(path)
        }
        var address = try ControlSocket.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlSocket.Failure(description: "socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 16) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            unlink(path)
            throw ControlSocket.Failure(description: "Couldn’t listen on \(path): \(message)")
        }
        lock.withLock {
            listener = fd
            stopped = false
        }
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "Portkeep control socket"
        thread.start()
    }

    /// Stops accepting and removes the socket file. The accept loop notices within a fraction of
    /// a second and closes the listening socket itself: closing it here could free its descriptor
    /// number for another socket while the loop is about to call accept on it again.
    public func stop() {
        let fd = lock.withLock { () -> Int32 in
            defer {
                listener = -1
                stopped = true
            }
            return listener
        }
        guard fd >= 0 else { return }
        unlink(path)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop(_ fd: Int32) {
        defer { close(fd) }
        while true {
            // accept() isn't woken by closing the socket on macOS, so wait in short polls and
            // check for stop() between them.
            var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let polled = poll(&ready, 1, 200)
            if isStopped { return }
            if polled < 0, errno != EINTR { return }
            if polled <= 0 { continue }
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == ECONNABORTED || errno == EWOULDBLOCK { continue }
                return
            }
            if isStopped {
                close(client)
                return
            }
            // Belt and braces with the 0600 mode: only this user.
            var uid = uid_t(), gid = gid_t()
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
                close(client)
                continue
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let thread = Thread { [self] in serve(client) }
            thread.name = "Portkeep control connection"
            thread.start()
        }
    }

    private final class Box: @unchecked Sendable {
        var value: Data?
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        let handler = self.handler
        while let line = reader.next() {
            if line.allSatisfy({ $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\r") || $0 == UInt8(ascii: "\t") }) { continue }
            // This is a thread of its own, so waiting here holds up only this connection.
            let box = Box()
            let done = DispatchSemaphore(value: 0)
            Task {
                box.value = await handler(line)
                done.signal()
            }
            done.wait()
            if let response = box.value, !ControlSocket.writeAll(fd, response + Data("\n".utf8)) { return }
        }
    }
}

/// The command line tool's side: one request at a time over one connection.
public final class ControlClient {
    public let path: String
    private var fd: Int32 = -1
    private var reader: LineReader?
    private var nextID = 1

    public init(path: String) {
        self.path = path
    }

    deinit { if fd >= 0 { close(fd) } }

    /// Connects if not already connected. False when nothing is listening.
    public func connect() throws(ControlSocket.Failure) -> Bool {
        if fd >= 0 { return true }
        guard let socket = try ControlSocket.connect(path) else { return false }
        fd = socket
        reader = LineReader(fd: socket)
        return true
    }

    public func disconnect() {
        if fd >= 0 { close(fd) }
        fd = -1
        reader = nil
    }

    /// Sends a request and waits for its response. Throws `RPCError` for an error response, and
    /// `RPCError.unavailable` when the connection is lost.
    public func call(_ method: String, _ params: JSONValue = .object([:])) throws(RPCError) -> JSONValue {
        let connected: Bool
        do { connected = try connect() } catch { throw RPCError(RPCError.unavailable, error.description) }
        guard connected else { throw RPCError(RPCError.unavailable, "Portkeep isn’t running.") }
        let id = nextID
        nextID += 1
        let request = RPCRequest(id: .int(id), method: method, params: params)
        let line = JSONValue.lineEncoder.encodeOrEmpty(request) + Data("\n".utf8)
        guard ControlSocket.writeAll(fd, line), let reply = reader?.next() else {
            disconnect()
            throw RPCError(RPCError.unavailable, "Lost the connection to Portkeep.")
        }
        guard let response = try? JSONDecoder().decode(RPCResponse.self, from: reply) else {
            throw RPCError(RPCError.internalError, "Portkeep sent something that isn’t JSON-RPC.")
        }
        if let error = response.error { throw error }
        return response.result ?? .null
    }
}
