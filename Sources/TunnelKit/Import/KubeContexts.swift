import Foundation

public enum KubeContexts {
    /// Output of `kubectl config get-contexts -o name`.
    public static func parse(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
