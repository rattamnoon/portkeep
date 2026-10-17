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

@Test func switchingOnASetStartsOneTunnelPerPort() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump"))
    let a = Tunnel(name: "A", group: "g", localPort: 3306, method: ssh)
    let b = Tunnel(name: "B", group: "g", localPort: 3306, method: ssh)
    let c = Tunnel(name: "C", group: "g", localPort: 5432, method: ssh)
    let plan = PortClaims().planSwitchOn([a, b, c])
    #expect(plan == PortClaims.SwitchOn(start: [a.id, c.id], stop: []))
}

@Test func switchingOnStopsTheOtherTunnelOnItsPort() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump"))
    let prod = Tunnel(name: "Production MySQL", group: "Production", localPort: 3306, method: ssh)
    let dev = Tunnel(name: "Development MySQL", group: "Development", localPort: 3306, method: ssh)
    var claims = PortClaims()
    _ = claims.claim(3306, by: prod.id)
    #expect(claims.planSwitchOn([dev]) == PortClaims.SwitchOn(start: [dev.id], stop: [prod.id]))
}

@Test func switchingOnKeepsATunnelAlreadyOnItsPort() {
    let ssh = TunnelMethod.ssh(SSHConfig(mode: .local, host: "jump"))
    let a = Tunnel(name: "A", group: "g", localPort: 3306, method: ssh)
    let b = Tunnel(name: "B", group: "g", localPort: 3306, method: ssh)
    let c = Tunnel(name: "C", group: "g", localPort: 5432, method: ssh)
    var claims = PortClaims()
    _ = claims.claim(3306, by: b.id)
    // B is already on 3306, so the master switch leaves it rather than flipping to A.
    #expect(claims.planSwitchOn([a, b, c]) == PortClaims.SwitchOn(start: [c.id], stop: []))
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
