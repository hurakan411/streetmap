# Review request eligibility

Milestones are 1, 3 and 5 recorded active days (existing all-history active-day calculation, independent of visible map filters). They are opportunities to call StoreKit, not guarantees of a visible prompt or an actual review.

- Never request in the first process launch using the new policy, or in any launch where onboarding finishes, including the debug replay.
- On a later launch, allow viewing the recorded map for 10 foreground seconds first. Do not request over Settings, sharing, date selection, POI cards, course planning or an undetermined location-permission state. Cancel the pending task on inactivity or leaving the map.
- At most one attempt per process launch. Persist attempts for each milestone; if multiple milestones were missed, request only the latest reached and consume lower milestones too.
- Delete the old pending onboarding flag. An old day-2 attempt consumes the new day-1 milestone. Existing day-5 attempts also suppress lower milestones. No recorded routes or recording settings are changed.
- Apple does not specify that a particular day count guarantees sufficient engagement or approval. Day-1 requests can still be too early for a particular user; App Review acceptance is not guaranteed.

```sh
xcrun swiftc Michi/Services/ReviewRequestPolicy.swift prototypes/ReviewRequests/main.swift -o /private/tmp/streetprint_review_policy_tests
/private/tmp/streetprint_review_policy_tests
```

The tests use isolated, disposable UserDefaults suites, never the app's real defaults. UI checks should additionally verify initial onboarding and cancellation while a modal is open; StoreKit may suppress the actual system sheet.
