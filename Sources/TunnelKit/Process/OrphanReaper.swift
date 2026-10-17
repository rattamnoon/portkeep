import Darwin
import Foundation

/// Remembers which children are running so a crashed or force-quit app can clean them up
/// on its next launch (spec §8, `running.json`).
///
/// A pid is identified by its start time, not its executable: `exec` in a custom command and
/// script-based CLIs (`aws` from Homebrew is Python) change what the process reports as its path.
public final class OrphanReaper: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    /// pid → start time (`OrphanReaper.startTime(of:)`), empty when it couldn't be read.
    public var recorded: [Int32: String] { lock.withLock { read() } }

    public func record(pid: Int32, startTime: String?) {
        lock.withLock {
            var all = read()
            all[pid] = startTime ?? ""
            write(all)
        }
    }

    public func forget(pid: Int32) {
        lock.withLock {
            var all = read()
            all[pid] = nil
            write(all)
        }
    }

    /// Kills each recorded pid whose process is still the one we started (same start time), so a pid
    /// reused by an unrelated process is never touched. Its whole process group goes. Clears the record.
    public func reap(
        startTimeOf: (Int32) -> String? = OrphanReaper.startTime(of:),
        kill: (Int32) -> Void = { _ = Darwin.kill(-$0, SIGKILL); _ = Darwin.kill($0, SIGKILL) }
    ) {
        lock.withLock {
            for (pid, started) in read().sorted(by: { $0.key < $1.key })
            where !started.isEmpty && startTimeOf(pid) == started {
                kill(pid)
            }
            write([:])
        }
    }

    /// Stops every recorded child synchronously: SIGTERM to each process group, SIGKILL to whatever is
    /// left after `grace` seconds. Used at quit, where AppKit is waiting and async work may not run.
    public func stopAll(grace: TimeInterval = 3) {
        lock.withLock {
            let pids = Array(read().keys)
            for pid in pids { _ = Darwin.kill(-pid, SIGTERM); _ = Darwin.kill(pid, SIGTERM) }
            let deadline = Date().addingTimeInterval(grace)
            func running() -> [Int32] { pids.filter { Self.startTime(of: $0) != nil && !Self.isZombie($0) } }
            while !running().isEmpty, Date() < deadline { usleep(50_000) }
            for pid in running() { _ = Darwin.kill(-pid, SIGKILL); _ = Darwin.kill(pid, SIGKILL) }
            write([:])
        }
    }

    private static func isZombie(_ pid: Int32) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return true }
        return info.pbi_status == SZOMB
    }

    /// Process start time as "seconds.microseconds", or nil if the pid doesn't exist.
    public static func startTime(of pid: Int32) -> String? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return "\(info.pbi_start_tvsec).\(info.pbi_start_tvusec)"
    }

    private func read() -> [Int32: String] {
        guard let data = try? Data(contentsOf: file),
              let raw = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int32(k).map { ($0, v) } })
    }

    private func write(_ all: [Int32: String]) {
        let raw = Dictionary(uniqueKeysWithValues: all.map { ("\($0.key)", $0.value) })
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(raw).write(to: file, options: .atomic)
    }
}
