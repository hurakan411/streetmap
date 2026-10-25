import Foundation

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    assertions += 1
    if !condition() { print("FAIL: \(message)"); exit(1) }
}

func scenario(_ test: (UserDefaults) -> Void) {
    let name = "StreetPrint.ReviewTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    test(defaults)
}

scenario { defaults in
    let first = ReviewRequestEligibility(defaults: defaults)
    for days in [0, 1, 3, 5, 100] {
        check(first.nextEligibleTrigger(activeDays: days) == nil, "first launch must never request")
    }
    let next = ReviewRequestEligibility(defaults: defaults)
    check(next.nextEligibleTrigger(activeDays: 0) == nil, "no record")
    check(next.nextEligibleTrigger(activeDays: 1) == .activeDay1, "day 1")
    check(next.nextEligibleTrigger(activeDays: 2) == .activeDay1, "missed day 1")
    next.markRequested(.activeDay1)
    check(next.nextEligibleTrigger(activeDays: 3) == nil, "at most one per launch")
    let third = ReviewRequestEligibility(defaults: defaults)
    check(third.nextEligibleTrigger(activeDays: 1) == nil, "day 1 not repeated")
    check(third.nextEligibleTrigger(activeDays: 2) == nil, "no day 2 milestone")
    check(third.nextEligibleTrigger(activeDays: 3) == .activeDay3, "day 3")
    third.markRequested(.activeDay3)
    let fourth = ReviewRequestEligibility(defaults: defaults)
    check(fourth.nextEligibleTrigger(activeDays: 4) == nil, "no day 4 milestone")
    check(fourth.nextEligibleTrigger(activeDays: 5) == .activeDay5, "day 5")
    fourth.markRequested(.activeDay5)
    let later = ReviewRequestEligibility(defaults: defaults)
    for days in [0, 1, 2, 3, 4, 5, 10] {
        check(later.nextEligibleTrigger(activeDays: days) == nil, "consumed milestones never replay")
    }
}

scenario { defaults in
    _ = ReviewRequestEligibility(defaults: defaults)
    let next = ReviewRequestEligibility(defaults: defaults)
    next.blockForOnboarding()
    check(next.nextEligibleTrigger(activeDays: 5) == nil, "onboarding replay blocks this launch")
    let later = ReviewRequestEligibility(defaults: defaults)
    check(later.nextEligibleTrigger(activeDays: 5) == .activeDay5, "next launch latest milestone")
    later.markRequested(.activeDay5)
    check(defaults.bool(forKey: "review.activeDay1.requested"), "suppress lower day 1")
    check(defaults.bool(forKey: "review.activeDay3.requested"), "suppress lower day 3")
}

scenario { defaults in
    defaults.set(true, forKey: "review.onboarding.pending")
    _ = ReviewRequestEligibility(defaults: defaults)
    check(defaults.object(forKey: "review.onboarding.pending") == nil, "legacy onboarding pending removed")
    let next = ReviewRequestEligibility(defaults: defaults)
    check(next.nextEligibleTrigger(activeDays: 0) == nil, "legacy onboarding cannot request without history")
    check(next.nextEligibleTrigger(activeDays: 3) == .activeDay3, "latest only, not retroactive day 1")
}

scenario { defaults in
    defaults.set(true, forKey: "review.activeDay2.requested")
    _ = ReviewRequestEligibility(defaults: defaults)
    let next = ReviewRequestEligibility(defaults: defaults)
    check(next.nextEligibleTrigger(activeDays: 1) == nil, "old day 2 consumes new day 1")
    check(next.nextEligibleTrigger(activeDays: 3) == .activeDay3, "old day 2 does not consume day 3")
}

scenario { defaults in
    defaults.set(true, forKey: "review.activeDay5.requested")
    _ = ReviewRequestEligibility(defaults: defaults)
    let next = ReviewRequestEligibility(defaults: defaults)
    for days in [1, 3, 5, 50] {
        check(next.nextEligibleTrigger(activeDays: days) == nil, "old day 5 suppresses all backfill")
    }
}

print("PASS: \(assertions) review-policy assertions (1/3/5 days, launch/onboarding gates, legacy migration, no backfill)")
