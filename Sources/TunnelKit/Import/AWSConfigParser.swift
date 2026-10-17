public struct AWSProfile: Equatable, Hashable, Sendable {
    public var name: String
    public var region: String?

    public init(name: String, region: String?) {
        self.name = name
        self.region = region
    }
}

public enum AWSConfigParser {
    /// `[default]` and `[profile x]` sections of `~/.aws/config`; `[sso-session …]` and others are ignored.
    public static func profiles(in text: String) -> [AWSProfile] {
        var result: [AWSProfile] = []
        var inProfile = false
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                let header = line.dropFirst().dropLast().trimmingCharacters(in: .whitespaces)
                if header == "default" {
                    result.append(AWSProfile(name: "default", region: nil)); inProfile = true
                } else if header.hasPrefix("profile ") {
                    let name = header.dropFirst("profile ".count).trimmingCharacters(in: .whitespaces)
                    result.append(AWSProfile(name: name, region: nil)); inProfile = true
                } else {
                    inProfile = false
                }
            } else if inProfile, let eq = line.firstIndex(of: "=") {
                let key = line[..<eq].trimmingCharacters(in: .whitespaces)
                if key == "region" {
                    result[result.count - 1].region = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return result
    }
}

import Foundation
