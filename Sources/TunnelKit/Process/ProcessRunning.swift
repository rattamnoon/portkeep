import Darwin
import Foundation

/// The last 500 lines a tunnel's process printed, stdout and stderr together.
public final class LogBuffer: @unchecked Sendable {
    public static let capacity = 500

    private let lock = NSLock()
    private var buffer: [String] = []
    private var partial = Data()

    public init() {}

    public var lines: [String] { lock.withLock { buffer } }

    public func tail(_ count: Int) -> [String] { lock.withLock { Array(buffer.suffix(count)) } }

    public func append(_ line: String) {
        lock.withLock { appendLocked(line) }
    }

    /// Bytes as they arrive from a pipe; lines may be split across chunks.
    public func append(chunk: Data) {
        lock.withLock {
            partial.append(chunk)
            while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
                // Invalid UTF-8 becomes U+FFFD rather than losing the line.
                appendLocked(String(decoding: partial[partial.startIndex..<newline], as: UTF8.self))
                partial.removeSubrange(partial.startIndex...newline)
            }
        }
    }

    private func appendLocked(_ line: String) {
        buffer.append(line)
        if buffer.count > Self.capacity { buffer.removeFirst(buffer.count - Self.capacity) }
    }
}

public protocol RunningProcess: Sendable {
    var pid: Int32 { get }
    /// Exit status if it has exited, without waiting.
    var exitStatus: Int32? { get }
    /// Exit status; 128 + signal number when killed by a signal.
    func waitForExit() async -> Int32
    /// SIGTERM to the whole process group, SIGKILL after 3 s; returns once it has exited.
    func terminate() async
}

public protocol ProcessRunning: Sendable {
    func launch(_ invocation: Invocation, log: LogBuffer) throws -> any RunningProcess
}

public struct LaunchError: Error, Equatable {
    public let errno: Int32
}

/// Spawns each child in its own process group so stopping a tunnel also stops anything it started.
public struct SystemRunner: ProcessRunning {
    /// `PATH` for the child, so tools like `aws` can find `session-manager-plugin`.
    public let path: String

    public init(path: String) {
        self.path = path
    }

    public func launch(_ invocation: Invocation, log: LogBuffer) throws -> any RunningProcess {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw LaunchError(errno: errno) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 1)
        posix_spawn_file_actions_adddup2(&actions, fds[1], 2)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attr, 0)
        var defaults = sigset_t()
        sigfillset(&defaults)
        posix_spawnattr_setsigdefault(&attr, &defaults)

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        let argv = [invocation.executable.path] + invocation.arguments
        let envp = environment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        let rc = withCStrings(argv) { cArgv in
            withCStrings(envp) { cEnvp in
                posix_spawn(&pid, invocation.executable.path, &actions, &attr, cArgv, cEnvp)
            }
        }
        close(fds[1])
        guard rc == 0 else {
            close(fds[0])
            throw LaunchError(errno: rc)
        }

        let reader = FileHandle(fileDescriptor: fds[0], closeOnDealloc: true)
        reader.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { log.append(chunk: data) }
        }
        return SpawnedProcess(pid: pid, reader: reader)
    }
}

private func withCStrings<R>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R) -> R {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
}

private final class SpawnedProcess: RunningProcess, @unchecked Sendable {
    let pid: Int32
    private let reader: FileHandle
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private let source: DispatchSourceProcess

    init(pid: Int32, reader: FileHandle) {
        self.pid = pid
        self.reader = reader
        source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        source.setEventHandler { [weak self] in self?.reap() }
        source.resume()
        // The child may have exited before the source was armed.
        reap()
    }

    private func reap() {
        var raw: Int32 = 0
        guard waitpid(pid, &raw, WNOHANG) == pid else { return }
        let code = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
        source.cancel()
        let pending = lock.withLock {
            status = code
            defer { waiters = [] }
            return waiters
        }
        pending.forEach { $0.resume(returning: code) }
    }

    var exitStatus: Int32? { lock.withLock { status } }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { continuation in
            let done: Int32? = lock.withLock {
                if let status { return status }
                waiters.append(continuation)
                return nil
            }
            if let done { continuation.resume(returning: done) }
        }
    }

    func terminate() async {
        if lock.withLock({ status }) != nil { return }
        kill(-pid, SIGTERM)
        // Poll rather than race waitForExit(): a task group would wait for the uncancellable waiter.
        let deadline = ContinuousClock.now + .seconds(3)
        while lock.withLock({ status }) == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if lock.withLock({ status }) == nil { kill(-pid, SIGKILL) }
        _ = await waitForExit()
        // Anything left in the group (children that ignored TERM) goes too.
        kill(-pid, SIGKILL)
    }
}
