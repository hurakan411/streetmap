import Foundation

enum ReviewRequestTrigger: String {
    case activeDay1
    case activeDay3
    case activeDay5

    var day: Int {
        switch self {
        case .activeDay1: 1
        case .activeDay3: 3
        case .activeDay5: 5
        }
    }
}

/// A launch-local gate, with persisted milestone attempts (not confirmed ratings).
/// StoreKit can suppress a request; it never tells us whether a rating was given.
final class ReviewRequestEligibility {
    private let defaults: UserDefaults
    private let isFirstLaunch: Bool
    private var onboardingCompletedThisLaunch = false
    private var requestedThisLaunch = false
    private static let milestones: [ReviewRequestTrigger] = [.activeDay1, .activeDay3, .activeDay5]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let launchKey = "review.engagement.hasLaunched"
        isFirstLaunch = !defaults.bool(forKey: launchKey)
        defaults.set(true, forKey: launchKey)

        // Never replay the old onboarding request after an update.
        defaults.removeObject(forKey: "review.onboarding.pending")
        if defaults.bool(forKey: "review.activeDay2.requested") {
            defaults.set(true, forKey: Self.key(.activeDay1))
        }
        if defaults.bool(forKey: Self.key(.activeDay5)) {
            defaults.set(true, forKey: Self.key(.activeDay1))
            defaults.set(true, forKey: Self.key(.activeDay3))
        }
    }

    func blockForOnboarding() { onboardingCompletedThisLaunch = true }

    func nextEligibleTrigger(activeDays: Int) -> ReviewRequestTrigger? {
        guard !isFirstLaunch, !onboardingCompletedThisLaunch, !requestedThisLaunch else { return nil }
        // If a milestone was missed, request only the latest reached one.
        guard let reached = Self.milestones.last(where: { activeDays >= $0.day }),
              !defaults.bool(forKey: Self.key(reached)) else { return nil }
        return reached
    }

    func markRequested(_ trigger: ReviewRequestTrigger) {
        requestedThisLaunch = true
        for milestone in Self.milestones where milestone.day <= trigger.day {
            defaults.set(true, forKey: Self.key(milestone))
        }
    }

    private static func key(_ trigger: ReviewRequestTrigger) -> String {
        "review.\(trigger.rawValue).requested"
    }
}

enum ReviewRequestPolicy {
    private static let launch = ReviewRequestEligibility()
    static func beginLaunch() { _ = launch }
    static func markOnboardingCompleted() { launch.blockForOnboarding() }
    static func nextEligibleTrigger(activeDays: Int) -> ReviewRequestTrigger? {
        launch.nextEligibleTrigger(activeDays: activeDays)
    }
    static func markRequested(_ trigger: ReviewRequestTrigger) { launch.markRequested(trigger) }
}
