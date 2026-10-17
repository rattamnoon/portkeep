import Foundation
import Testing
@testable import TunnelKit

private let specExample = """
{
  "schemaVersion": 1,
  "groups": ["UAT", "Production", "Other"],
  "tunnels": [
    {
      "id": "6F1C2B8E-3D4A-4E5F-8A9B-0C1D2E3F4A5B",
      "name": "Dashboard MySQL",
      "group": "Production",
      "localPort": 3306,
      "connectAtLogin": true,
      "method": {
        "ssm": {
          "profile": "prod", "region": "ap-southeast-1", "target": "i-0a3f…",
          "forwardTo": { "remoteHost": { "host": "mysql.prod.internal", "port": 3306 } },
          "ssoAutoLogin": true
        }
      }
    }
  ],
  "toolPaths": { "aws": "/opt/homebrew/bin/aws" }
}
"""

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ text: String) throws -> URL {
    let url = try tempDir().appendingPathComponent("tunnels.json")
    try Data(text.utf8).write(to: url)
    return url
}

private func loaded(_ result: LoadResult) throws -> TunnelFile {
    guard case .loaded(let file) = result else {
        Issue.record("expected .loaded, got \(result)")
        throw CancellationError()
    }
    return file
}

@Test func roundTripsSpecExample() throws {
    let url = try write(specExample)
    let file = try loaded(TunnelFile.load(from: url, now: .now))
    #expect(file.tunnels[0].method == .ssm(SSMConfig(
        profile: "prod", region: "ap-southeast-1", target: "i-0a3f…",
        forwardTo: .remoteHost(Endpoint(host: "mysql.prod.internal", port: 3306)),
        ssoAutoLogin: true)))
    #expect(file.toolPaths == ["aws": "/opt/homebrew/bin/aws"])

    try file.save(to: url)
    let again = try loaded(TunnelFile.load(from: url, now: .now))
    #expect(again == file)
}

@Test func roundTripsEveryMethod() throws {
    let methods: [TunnelMethod] = [
        .ssh(SSHConfig(mode: .local, host: "jump", jump: "bastion",
                       destination: Endpoint(host: "db", port: 5432), identityFile: "~/.ssh/id_ed25519")),
        .ssm(SSMConfig(profile: "p", region: "r", target: "i-1", forwardTo: .instance(port: 22))),
        .kubernetes(KubeConfig(context: "c", namespace: "n", resource: "svc/grafana", remotePort: 3000)),
        .iap(IAPConfig(project: "p", zone: "z", instance: "i", remotePort: 5432)),
        .cloudflare(CloudflareConfig(hostname: "db.example.com")),
        .custom(CustomConfig(command: "tsh proxy db --port {port}")),
    ]
    let file = TunnelFile(tunnels: methods.enumerated().map { i, m in
        Tunnel(name: "t\(i)", group: "Other", localPort: 10000 + i, method: m)
    })
    let url = try tempDir().appendingPathComponent("tunnels.json")
    try file.save(to: url)
    #expect(try loaded(TunnelFile.load(from: url, now: .now)) == file)
}

@Test func preservesUnknownTopLevelKeys() throws {
    let text = specExample.replacingOccurrences(
        of: "\"schemaVersion\": 1,", with: "\"schemaVersion\": 1, \"futureThing\": {\"a\": 1},")
    let url = try write(text)
    let file = try loaded(TunnelFile.load(from: url, now: .now))
    try file.save(to: url)
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    let future = json["futureThing"] as! [String: Any]
    #expect(future["a"] as? Int == 1)
}

@Test func brokenFileIsMovedAside() throws {
    let text = "{\"tunnels\": ["
    let url = try write(text)
    var parts = DateComponents()
    parts.year = 2026; parts.month = 10; parts.day = 17; parts.hour = 14; parts.minute = 30; parts.second = 0
    let now = Calendar(identifier: .gregorian).date(from: parts)!

    guard case .broken(let backup) = TunnelFile.load(from: url, now: now) else {
        Issue.record("expected .broken"); return
    }
    #expect(backup.lastPathComponent == "tunnels.json.broken-20261017-143000")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: backup) == Data(text.utf8))
}

@Test func newerSchemaIsReadOnly() throws {
    let url = try write(specExample.replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2"))
    guard case .newerSchema = TunnelFile.load(from: url, now: .now) else {
        Issue.record("expected .newerSchema"); return
    }
}

@Test func missingFile() throws {
    let url = try tempDir().appendingPathComponent("tunnels.json")
    guard case .missing = TunnelFile.load(from: url, now: .now) else {
        Issue.record("expected .missing"); return
    }
}
