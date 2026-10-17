import Foundation
import Testing
@testable import TunnelKit

private struct Boom: Error {}

@Test func fallsBackOnFailure() async {
    let path = await ToolLocator.loginShellPath(shell: "/bin/zsh") { _, _ in throw Boom() }
    #expect(path == ToolLocator.fallbackPath)
}

@Test func fallsBackOnEmptyOutput() async {
    let path = await ToolLocator.loginShellPath(shell: "/bin/zsh") { _, _ in "" }
    #expect(path == ToolLocator.fallbackPath)
}

@Test func usesShellOutput() async {
    let path = await ToolLocator.loginShellPath(shell: "/opt/homebrew/bin/fish") { exe, args in
        #expect(exe.path == "/opt/homebrew/bin/fish")
        #expect(args == ["-l", "-c", #"printf %s "$PATH""#])
        return "/opt/homebrew/bin:/usr/bin"
    }
    #expect(path == "/opt/homebrew/bin:/usr/bin")
}

@Test func fallsBackOnTimeout() async {
    let path = await ToolLocator.loginShellPath(shell: "/bin/zsh", timeout: .milliseconds(50)) { _, _ in
        try await Task.sleep(for: .seconds(5))
        return "/never"
    }
    #expect(path == ToolLocator.fallbackPath)
}

@Test func resolvesFromSearchPathInOrder() {
    let tools = ToolPaths(searchPath: "/a:/opt/homebrew/bin:/usr/bin", overrides: [:], isExecutable: {
        $0 == "/opt/homebrew/bin/aws" || $0 == "/usr/bin/aws"
    })
    #expect(tools.url(for: "aws")?.path == "/opt/homebrew/bin/aws")
    #expect(tools.url(for: "kubectl") == nil)
}

@Test func overrideWins() {
    let tools = ToolPaths(searchPath: "/opt/homebrew/bin", overrides: ["aws": "/custom/aws"], isExecutable: { _ in true })
    #expect(tools.url(for: "aws")?.path == "/custom/aws")
}

@Test func realLoginShellFindsSh() async {
    // Review Focus 1: whatever the user's shell, the resolved PATH must find basic tools.
    let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    let path = await ToolLocator.loginShellPath(shell: shell)
    #expect(ToolPaths(searchPath: path, overrides: [:]).url(for: "sh") != nil)
}
