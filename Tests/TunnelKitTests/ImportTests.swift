import Foundation
import Testing
@testable import TunnelKit

@Test func sshHostsSkipWildcards() {
    let text = "Host jump bastion\n  HostName 1.2.3.4\nHost *\nHost *.internal\nHost !bad\nhost=lower\nHost jump"
    #expect(SSHConfigParser.hosts(in: text) == ["jump", "bastion", "lower"])
}

@Test func awsProfiles() {
    let text = "[default]\nregion = us-east-1\n[profile prod]\nregion = ap-southeast-1\n[sso-session corp]\nregion = eu-west-1\n[profile dev]\n"
    #expect(AWSConfigParser.profiles(in: text) == [
        AWSProfile(name: "default", region: "us-east-1"),
        AWSProfile(name: "prod", region: "ap-southeast-1"),
        AWSProfile(name: "dev", region: nil),
    ])
}

@Test func kubeContexts() {
    #expect(KubeContexts.parse("origin-prod\norigin-uat\n\n") == ["origin-prod", "origin-uat"])
}

@Test func loginStartsOnlyFirstTunnelOnAPort() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump"))
    let a = Tunnel(name: "A", group: "g", localPort: 3306, connectAtLogin: true, method: ssh)
    let b = Tunnel(name: "B", group: "g", localPort: 3306, connectAtLogin: true, method: ssh)
    let c = Tunnel(name: "C", group: "g", localPort: 5432, connectAtLogin: false, method: ssh)
    var claims = PortClaims()
    let plan = claims.planLogin([a, b, c])
    #expect(plan.map(\.id) == [a.id, b.id])
    #expect(plan.map(\.start) == [.start, .blocked(by: a.id)])
}

@Test func launchAlsoRestoresTunnelsThatWereOn() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump"))
    let login = Tunnel(name: "A", group: "g", localPort: 1001, connectAtLogin: true, method: ssh)
    let wasOn = Tunnel(name: "B", group: "g", localPort: 1002, method: ssh)
    let wasOff = Tunnel(name: "C", group: "g", localPort: 1003, method: ssh)
    var claims = PortClaims()
    let plan = claims.planLogin([login, wasOn, wasOff], alsoStart: [wasOn.id])
    #expect(plan.map(\.id) == [login.id, wasOn.id])
    #expect(plan.allSatisfy { $0.start == .start })
}

@Test func secondClaimReturnsHolder() {
    let a = UUID(), b = UUID()
    var claims = PortClaims()
    #expect(claims.claim(3306, by: a) == nil)
    #expect(claims.claim(3306, by: b) == a)
    #expect(claims.claim(3306, by: a) == nil, "re-claiming your own port is fine")
    claims.release(3306, by: b)
    #expect(claims.holder(of: 3306) == a, "only the holder can release")
    claims.release(3306, by: a)
    #expect(claims.claim(3306, by: b) == nil)
}
