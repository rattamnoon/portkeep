import Foundation
import Testing
@testable import TunnelKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Test func downOnlyAfterThirtySecondsAndOnce() {
    var notifier = DropNotifier()
    let id = UUID()
    #expect(notifier.update(id, state: .retrying(.hostUnreachable, attempt: 1, until: t0), now: t0) == nil)
    #expect(notifier.check(now: t0.addingTimeInterval(29)).isEmpty)
    #expect(notifier.check(now: t0.addingTimeInterval(30)).map(\.notice) == [.down])
    // Still retrying: no second notice.
    #expect(notifier.update(id, state: .retrying(.hostUnreachable, attempt: 5, until: t0), now: t0.addingTimeInterval(40)) == nil)
    #expect(notifier.check(now: t0.addingTimeInterval(300)).isEmpty)
    #expect(notifier.update(id, state: .connected(since: t0), now: t0.addingTimeInterval(301)) == .recovered)
    #expect(notifier.update(id, state: .connected(since: t0), now: t0.addingTimeInterval(302)) == nil)
}

@Test func quickReconnectSaysNothing() {
    var notifier = DropNotifier()
    let id = UUID()
    _ = notifier.update(id, state: .retrying(.stoppedResponding, attempt: 1, until: t0), now: t0)
    #expect(notifier.update(id, state: .connected(since: t0), now: t0.addingTimeInterval(5)) == nil)
    #expect(notifier.check(now: t0.addingTimeInterval(60)).isEmpty)
}

@Test func needsActionRightAwayThenRecovered() {
    var notifier = DropNotifier()
    let id = UUID()
    let expired = TunnelState.failed(.ssoExpired(profile: "prod"))
    #expect(notifier.update(id, state: expired, now: t0) == .needsAction(expired))
    #expect(notifier.update(id, state: expired, now: t0.addingTimeInterval(1)) == nil)
    #expect(notifier.check(now: t0.addingTimeInterval(60)).isEmpty, "already told them")
    _ = notifier.update(id, state: .starting, now: t0.addingTimeInterval(70))
    #expect(notifier.update(id, state: .connected(since: t0), now: t0.addingTimeInterval(75)) == .recovered)
}

@Test func downThenNeedsActionIsANewChange() {
    var notifier = DropNotifier()
    let id = UUID()
    _ = notifier.update(id, state: .retrying(.hostUnreachable, attempt: 1, until: t0), now: t0)
    #expect(notifier.check(now: t0.addingTimeInterval(31)).map(\.notice) == [.down])
    let hostKey = TunnelState.failed(.hostKeyChanged)
    #expect(notifier.update(id, state: hostKey, now: t0.addingTimeInterval(32)) == .needsAction(hostKey))
}

@Test func switchingOffForgetsTheDrop() {
    var notifier = DropNotifier()
    let id = UUID()
    _ = notifier.update(id, state: .retrying(.hostUnreachable, attempt: 1, until: t0), now: t0)
    #expect(notifier.check(now: t0.addingTimeInterval(31)).count == 1)
    #expect(notifier.update(id, state: .off, now: t0.addingTimeInterval(40)) == nil)
    #expect(notifier.update(id, state: .connected(since: t0), now: t0.addingTimeInterval(50)) == nil, "no recovery notice after switching off")
    _ = notifier.update(id, state: .standingBy, now: t0.addingTimeInterval(60))
    #expect(notifier.check(now: t0.addingTimeInterval(600)).isEmpty, "standing by isn't down")
}
