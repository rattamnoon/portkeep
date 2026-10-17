/// Wait before each retry: 1, 2, 4, 8, 16, 30, 60 s, then 60 s forever (spec §5.2).
public struct Backoff: Sendable {
    private static let steps: [Duration] = [1, 2, 4, 8, 16, 30, 60].map { .seconds($0) }
    private var index = 0

    public init() {}

    public mutating func next() -> Duration {
        defer { index = min(index + 1, Self.steps.count - 1) }
        return Self.steps[index]
    }

    public mutating func reset() {
        index = 0
    }
}
