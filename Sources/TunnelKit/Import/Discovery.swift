import Foundation

/// What the user already has configured: the lists behind the editor's pickers, and which tools
/// are installed. `discover` on the control socket returns it so an agent fills in real names.
public struct Discovery: Codable, Equatable, Sendable {
    /// `Host` aliases from ~/.ssh/config.
    public var sshHosts: [String]
    /// Profiles from ~/.aws/config with their regions.
    public var awsProfiles: [AWSProfile]
    /// `kubectl config get-contexts -o name`; empty without kubectl.
    public var kubeContexts: [String]
    /// Tool name → path, for the tools Portkeep found.
    public var tools: [String: String]
    /// Tool name → how to install it, for the ones it didn't.
    public var missingTools: [String: String]

    public init(sshHosts: [String] = [], awsProfiles: [AWSProfile] = [], kubeContexts: [String] = [],
                tools: [String: String] = [:], missingTools: [String: String] = [:]) {
        self.sshHosts = sshHosts
        self.awsProfiles = awsProfiles
        self.kubeContexts = kubeContexts
        self.tools = tools
        self.missingTools = missingTools
    }

    public static let toolNames = ["ssh", "aws", "session-manager-plugin", "kubectl", "gcloud", "cloudflared"]

    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser, tools: ToolPaths,
                            run: ToolLocator.Run = ToolLocator.captureOutput) async -> Discovery {
        var found = Discovery()
        if let text = try? String(contentsOf: home.appendingPathComponent(".ssh/config"), encoding: .utf8) {
            found.sshHosts = SSHConfigParser.hosts(in: text)
        }
        if let text = try? String(contentsOf: home.appendingPathComponent(".aws/config"), encoding: .utf8) {
            found.awsProfiles = AWSConfigParser.profiles(in: text)
        }
        for tool in toolNames {
            if let url = tools.url(for: tool) {
                found.tools[tool] = url.path
            } else {
                found.missingTools[tool] = CommandBuilder.installHints[tool] ?? ""
            }
        }
        if let kubectl = tools.url(for: "kubectl"),
           let output = try? await run(kubectl, ["config", "get-contexts", "-o", "name"]) {
            found.kubeContexts = KubeContexts.parse(output)
        }
        return found
    }
}
