import Darwin
import Foundation
import Testing
@testable import TunnelKit

private func sh(_ script: String) -> Invocation {
    Invocation(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script])
}

@Test func runnerCapturesBothStreams() async throws {
    let log = LogBuffer()
    let process = try SystemRunner(path: "/usr/bin:/bin").launch(sh("echo out; echo err 1>&2; exit 3"), log: log)
    #expect(await process.waitForExit() == 3)
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.lines.contains("out"))
    #expect(log.lines.contains("err"))
}

@Test func runnerPassesPath() async throws {
    let log = LogBuffer()
    let process = try SystemRunner(path: "/custom/bin:/usr/bin:/bin").launch(sh(#"printf '%s\n' "$PATH""#), log: log)
    _ = await process.waitForExit()
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.lines == ["/custom/bin:/usr/bin:/bin"])
}

@Test func invalidUTF8IsReplacedNotDropped() async throws {
    let log = LogBuffer()
    let process = try SystemRunner(path: "/usr/bin:/bin").launch(sh(#"printf 'a\377b\n'"#), log: log)
    _ = await process.waitForExit()
    try await Task.sleep(for: .milliseconds(100))
    #expect(log.lines == ["a\u{FFFD}b"])
}

@Test func terminateKillsStubbornChildAndItsChildren() async throws {
    let log = LogBuffer()
    let process = try SystemRunner(path: "/usr/bin:/bin").launch(sh(#"trap "" TERM; sleep 30 & wait"#), log: log)
    let started = ContinuousClock.now
    await process.terminate()
    #expect(ContinuousClock.now - started < .seconds(4))
    #expect(kill(process.pid, 0) != 0)
    #expect(kill(-process.pid, 0) != 0, "the process group, including sleep, is gone")
}

@Test func childGetsTermEvenIfSpawnerBlocksIt() async throws {
    var blocked = sigset_t(), old = sigset_t()
    sigemptyset(&blocked)
    sigaddset(&blocked, SIGTERM)
    pthread_sigmask(SIG_BLOCK, &blocked, &old)
    let process = try SystemRunner(path: "/usr/bin:/bin").launch(
        Invocation(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"]), log: LogBuffer())
    pthread_sigmask(SIG_SETMASK, &old, nil)

    try await Task.sleep(for: .milliseconds(100))
    kill(process.pid, SIGTERM)
    #expect(await process.waitForExit() == 128 + SIGTERM)
}

@Test func logBufferKeeps500() {
    let log = LogBuffer()
    for i in 1...600 { log.append("line \(i)") }
    #expect(log.lines.count == 500)
    #expect(log.lines.first == "line 101")
    #expect(log.tail(50).first == "line 551")
}

@Test func logBufferJoinsPartialChunks() {
    let log = LogBuffer()
    log.append(chunk: Data("hel".utf8))
    log.append(chunk: Data("lo\nwor".utf8))
    log.append(chunk: Data("ld\n".utf8))
    #expect(log.lines == ["hello", "world"])
}
