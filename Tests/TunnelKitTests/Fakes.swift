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

/// Wakes whoever waits on it each time something they watch changes. A waiter passes the
/// `generation` it read before checking, so a change between the check and the wait isn't lost.
final class Pulse: @unchecked Sendable {
    private let lock = NSLock()
    private var _generation = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var generation: Int { lock.withLock { _generation } }

    func ping() {
        let woken = lock.withLock {
            _generation += 1
            defer { waiters = [] }
            return waiters
        }
        woken.forEach { $0.resume() }
    }

    /// Returns once the generation has moved past `seen`.
    func wait(after seen: Int) async {
        await withCheckedContinuation { c in
            let moved: Bool = lock.withLock {
                if _generation != seen { return true }
                waiters.append(c)
                return false
            }
            if moved { c.resume() }
        }
    }
}

/// A clock that moves only when the test fires its sleepers, and pings `pulse` whenever something
/// starts sleeping on it. `TestClock` gives no such signal, so a test could only guess, with yields
/// or real sleeps, whether the code under test had reached its next sleep yet.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration = .zero
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    let pulse: Pulse
    private let lock = NSLock()
    private var _now = Instant()
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelled: Set<UUID> = []

    init(pulse: Pulse) { self.pulse = pulse }

    var now: Instant { lock.withLock { _now } }
    var minimumResolution: Duration { .zero }
    var hasSleepers: Bool { lock.withLock { !sleepers.isEmpty } }

    func sleep(until deadline: Instant, tolerance: Duration? = nil) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let early: (any Error)?? = lock.withLock {
                    if cancelled.remove(id) != nil { return .some(CancellationError()) }
                    if deadline <= _now { return .some(nil) }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    return .none
                }
                switch early {
                case .some(let error?): c.resume(throwing: error)
                case .some(nil): c.resume()
                case .none: pulse.ping()
                }
            }
        } onCancel: {
            let c = lock.withLock {
                guard let sleeper = sleepers.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return nil as CheckedContinuation<Void, any Error>?
                }
                return sleeper.continuation
            }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Wakes the earliest sleeper due by `limit`, moving the time to its deadline. False when none is.
    func fireNext(upTo limit: Instant) -> Bool {
        let due: Sleeper? = lock.withLock {
            guard let (id, sleeper) = sleepers.filter({ $0.value.deadline <= limit }).min(by: { $0.value.deadline < $1.value.deadline })
            else { return nil }
            sleepers[id] = nil
            _now = max(_now, sleeper.deadline)
            return sleeper
        }
        due?.continuation.resume()
        return due != nil
    }

    func set(now: Instant) {
        lock.withLock { _now = max(_now, now) }
    }
}
