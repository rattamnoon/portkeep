import Foundation
import Testing
@testable import TunnelKit

@Test func reapKillsOnlyMatchingAlivePids() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json")
    let reaper = OrphanReaper(file: file)
    reaper.record(pid: 100, executable: "/usr/bin/ssh")
    reaper.record(pid: 200, executable: "/usr/bin/ssh")
    reaper.record(pid: 300, executable: "/usr/bin/ssh")

    var killed: [Int32] = []
    OrphanReaper(file: file).reap(
        isAlive: { $0 != 300 },
        executableOf: { $0 == 100 ? "/usr/bin/ssh" : "/usr/bin/vim" },
        kill: { killed.append($0) })

    #expect(killed == [100])
    #expect(OrphanReaper(file: file).recorded.isEmpty)
}

@Test func forgetRemovesPid() {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json")
    let reaper = OrphanReaper(file: file)
    reaper.record(pid: 100, executable: "/usr/bin/ssh")
    reaper.forget(pid: 100)
    #expect(OrphanReaper(file: file).recorded.isEmpty)
}
