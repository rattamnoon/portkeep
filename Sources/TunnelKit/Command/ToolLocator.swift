import Foundation

/// Where each CLI lives. GUI apps launched from Finder get a minimal PATH, so the
/// search path comes from the user's login shell (spec §5.6).
public struct ToolPaths: Sendable {
    public let searchPath: String
    public let overrides: [String: String]
    private let isExecutable: @Sendable (String) -> Bool

    public init(
        searchPath: String, overrides: [String: String],
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.searchPath = searchPath
        self.overrides = overrides
        self.isExecutable = isExecutable
    }

    public func url(for tool: String) -> URL? {
        if let override = overrides[tool], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        for dir in searchPath.split(separator: ":") where !dir.isEmpty {
            let candidate = "\(dir)/\(tool)"
            if isExecutable(candidate) { return URL(fileURLWithPath: candidate) }
        }
        return nil
    }
}

public enum ToolLocator {
    public static let fallbackPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

    public typealias Run = @Sendable (URL, [String]) async throws -> String

    /// The login shell's `$PATH`, or `fallbackPath` when the shell fails, prints nothing, or takes longer than `timeout`.
    public static func loginShellPath(
        shell: String, timeout: Duration = .seconds(5), run: @escaping Run = captureOutput
    ) async -> String {
        let output = await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await run(URL(fileURLWithPath: shell), ["-l", "-c", #"printf %s "$PATH""#]) }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        let path = (output ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? fallbackPath : path
    }

    /// Runs a command to completion and returns its stdout.
    public static let captureOutput: Run = { executable, arguments in
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}
