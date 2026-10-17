import Darwin
import Foundation

/// Remembers which children are running so a crashed or force-quit app can clean them up
/// on its next launch (spec §8, `running.json`).
public final class OrphanReaper: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()

    public init(file: URL) {
        self.file = file
    }

    /// pid → executable path.
    public var recorded: [Int32: String] { lock.withLock { read() } }

    public func record(pid: Int32, executable: String) {
        lock.withLock {
            var all = read()
            all[pid] = executable
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

    /// Kills recorded pids that are still alive and still running the recorded executable,
    /// so a pid reused by an unrelated process is never touched. Clears the record.
    public func reap(
        isAlive: (Int32) -> Bool = { Darwin.kill($0, 0) == 0 },
        executableOf: (Int32) -> String? = OrphanReaper.executablePath,
        kill: (Int32) -> Void = { _ = Darwin.kill(-$0, SIGKILL); _ = Darwin.kill($0, SIGKILL) }
    ) {
        lock.withLock {
            for (pid, executable) in read().sorted(by: { $0.key < $1.key })
            where isAlive(pid) && executableOf(pid) == executable {
                kill(pid)
            }
            write([:])
        }
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
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
