import Foundation
@testable import TunnelKit

final class FakePorts: PortChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var _free = true
    private var _acceptsQueue: [Bool] = []
    private var _acceptsDefault = true
    private var _owner: PortOwner?

    var free: Bool {
        get { lock.withLock { _free } }
        set { lock.withLock { _free = newValue } }
    }
    var acceptsDefault: Bool {
        get { lock.withLock { _acceptsDefault } }
        set { lock.withLock { _acceptsDefault = newValue } }
    }
    var acceptsQueue: [Bool] {
        get { lock.withLock { _acceptsQueue } }
        set { lock.withLock { _acceptsQueue = newValue } }
    }
    var owner: PortOwner? {
        get { lock.withLock { _owner } }
        set { lock.withLock { _owner = newValue } }
    }

    func isFree(_ port: Int) -> Bool { free }
    func accepts(_ port: Int) async -> Bool {
        lock.withLock { _acceptsQueue.isEmpty ? _acceptsDefault : _acceptsQueue.removeFirst() }
    }
    func owner(of port: Int) async -> PortOwner? { owner }
}

final class FakeProcess: RunningProcess, @unchecked Sendable {
    let pid: Int32
    private let lock = NSLock()
    private var status: Int32?
    private var waiters: [CheckedContinuation<Int32, Never>] = []
    private(set) var terminated = false
    private let onExit: @Sendable () -> Void

    init(pid: Int32, onExit: @escaping @Sendable () -> Void) {
        self.pid = pid
        self.onExit = onExit
    }

    var exitStatus: Int32? { lock.withLock { status } }

    func exit(_ code: Int32) {
        let pending: [CheckedContinuation<Int32, Never>]? = lock.withLock {
            guard status == nil else { return nil }
            status = code
            defer { waiters = [] }
            return waiters
        }
        guard let pending else { return }
        onExit()
        pending.forEach { $0.resume(returning: code) }
    }

    func waitForExit() async -> Int32 {
        await withCheckedContinuation { c in
            let done: Int32? = lock.withLock {
                if let status { return status }
                waiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    func terminate() async {
        lock.withLock { terminated = true }
        exit(143)
    }
}

final class FakeRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _launches: [FakeProcess] = []
    private var _live = 0
    private var _maxLive = 0
    /// Runs right after each launch, e.g. to print to the log and exit.
    var onLaunch: @Sendable (FakeProcess, LogBuffer) -> Void = { _, _ in }

    var launches: [FakeProcess] { lock.withLock { _launches } }
    var last: FakeProcess? { launches.last }
    var maxLive: Int { lock.withLock { _maxLive } }

    func launch(_ invocation: Invocation, log: LogBuffer) throws -> any RunningProcess {
        let process = lock.withLock {
            let p = FakeProcess(pid: Int32(1000 + _launches.count)) { [weak self] in
                self?.lock.withLock { self?._live -= 1 }
            }
            _launches.append(p)
            _live += 1
            _maxLive = max(_maxLive, _live)
            return p
        }
        onLaunch(process, log)
        return process
    }
}

final class Recorder<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [T] = []
    var all: [T] { lock.withLock { items } }
    func append(_ item: T) { lock.withLock { items.append(item) } }
}

/// Lets queued actor and task work run without advancing any clock.
func settle() async {
    for _ in 0..<200 { await Task.yield() }
}
