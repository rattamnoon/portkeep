import Testing
@testable import TunnelKit

private func classify(_ line: String, status: Int32 = 255, profile: String? = nil) -> FailureReason {
    FailureClassifier.classify(stderr: ["some preamble", line], status: status, profile: profile)
}

@Test func hostKeyChanged() {
    #expect(classify("@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @") == .hostKeyChanged)
}

@Test func authFailed() {
    #expect(classify("user@jump: Permission denied (publickey).") == .authFailed)
}

@Test func ssoExpiredCarriesProfile() {
    #expect(classify("Error when retrieving token from sso: Token has expired and refresh failed", profile: "prod") == .ssoExpired(profile: "prod"))
    #expect(classify("The SSO session associated with this profile has expired or is otherwise invalid.") == .ssoExpired(profile: nil))
}

@Test func pluginMissing() {
    #expect(classify("SessionManagerPlugin is not found. Please refer to SessionManager Documentation here") == .pluginMissing)
}

@Test func forwardRefused() {
    #expect(classify("Error: remote port forwarding failed for listen port 8080") == .forwardRefused)
    #expect(classify("channel 2: open failed: administratively prohibited: open failed") == .forwardRefused)
}

@Test func hostUnreachable() {
    for line in [
        "ssh: Could not resolve hostname jump: nodename nor servname provided",
        "ssh: connect to host 10.0.0.1 port 22: Connection timed out",
        "ssh: connect to host 10.0.0.1 port 22: No route to host",
        "connect: Network is unreachable",
        "ssh: connect to host 10.0.0.1 port 22: Connection refused",
    ] {
        #expect(classify(line) == .hostUnreachable, "\(line)")
    }
}

@Test func portInUse() {
    #expect(classify("bind [127.0.0.1]:3306: Address already in use") == .portInUse)
}

@Test func firstMatchWins() {
    let reason = FailureClassifier.classify(
        stderr: ["Connection refused", "user@jump: Permission denied (publickey)."], status: 255, profile: nil)
    #expect(reason == .authFailed)
}

@Test func unknownKeepsStatus() {
    #expect(classify("something new", status: 255) == .unknown(status: 255))
}

@Test func retryability() {
    #expect(FailureReason.hostUnreachable.isRetryable)
    #expect(FailureReason.readinessTimeout.isRetryable)
    #expect(FailureReason.unknown(status: 1).isRetryable)
    #expect(!FailureReason.authFailed.isRetryable)
    #expect(!FailureReason.portInUse.isRetryable)
    #expect(!FailureReason.ssoExpired(profile: "p").isRetryable)
}
