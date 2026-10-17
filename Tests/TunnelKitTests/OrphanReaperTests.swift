import Darwin
import Foundation
import Testing
@testable import TunnelKit

private func tempFile() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)/running.json")
}

@Test func reapKillsOnlyPidsStartedAtTheRecordedTime() {
    let file = tempFile()
    let reaper = OrphanReaper(file: file)
    reaper.record(pid: 100, startTime: "1.1")   // still ours
    reaper.record(pid: 200, startTime: "1.1")   // pid reused by another process
    reaper.record(pid: 300, startTime: "1.1")   // gone
    reaper.record(pid: 400, startTime: nil)     // start time unknown: never killed

    var killed: [Int32] = []
    OrphanReaper(file: file).reap(
        startTimeOf: { [100: "1.1", 200: "9.9", 400: "1.1"][$0] },
        kill: { killed.append($0) })

    #expect(killed == [100])
    #expect(OrphanReaper(file: file).recorded.isEmpty)
}

@Test func forgetRemovesPid() {
    let file = tempFile()
    let reaper = OrphanReaper(file: file)
    reaper.record(pid: 100, startTime: "1.1")
    reaper.forget(pid: 100)
    #expect(OrphanReaper(file: file).recorded.isEmpty)
}

@Test func stopAllStopsRunningChildrenSynchronously() async throws {
    let runner = SystemRunner(path: "/usr/bin:/bin")
    let polite = try runner.launch(Invocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]), log: LogBuffer())
    let stubborn = try runner.launch(
        Invocation(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", #"trap "" TERM; while :; do sleep 1; done"#]),
        log: LogBuffer())
    try await Task.sleep(for: .milliseconds(200))
    let reaper = OrphanReaper(file: tempFile())
    for p in [polite, stubborn] { reaper.record(pid: p.pid, startTime: OrphanReaper.startTime(of: p.pid)) }

    let started = Date()
    reaper.stopAll(grace: 1)
    #expect(Date().timeIntervalSince(started) < 2)
    #expect(await polite.waitForExit() == 128 + SIGTERM)
    #expect(await stubborn.waitForExit() == 128 + SIGKILL)
    #expect(reaper.recorded.isEmpty)
}

@Test func reapsARealExecdChild() async throws {
    // Review Focus 2: a custom command that execs into another program is still found and killed.
    let log = LogBuffer()
    let process = try SystemRunner(path: "/usr/bin:/bin").launch(
        Invocation(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exec sleep 30"]), log: log)
    try await Task.sleep(for: .milliseconds(200))
    let file = tempFile()
    OrphanReaper(file: file).record(pid: process.pid, startTime: OrphanReaper.startTime(of: process.pid))

    OrphanReaper(file: file).reap()
    #expect(await process.waitForExit() == 128 + SIGKILL)
}
