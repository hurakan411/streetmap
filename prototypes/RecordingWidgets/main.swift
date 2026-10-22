import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ label: String) {
    precondition(condition(), label)
}

let defaults = UserDefaults(suiteName: "StreetPrint.WidgetTests.\(UUID().uuidString)")!
expect(RecordingWidgetStore.load(from: defaults).recordingMode == .off, "Unconfigured widgets must not imply recording")
expect(!RecordingWidgetStore.load(from: defaults).isConfigured, "Fresh widgets need setup")
var cases = 0
for recording in RecordingMode.allCases {
    for movement in MovementCaptureMode.allCases {
        for authorization in 0...4 {
            let state = RecordingWidgetState(recordingMode: recording, movementMode: movement,
                authorization: authorization, isConfigured: true, language: "japanese")
            expect(RecordingWidgetStore.save(state, to: defaults), "Changed snapshots must be published")
            expect(RecordingWidgetStore.load(from: defaults) == state, "Snapshot must round-trip atomically")
            expect(!RecordingWidgetStore.save(state, to: defaults), "Identical state must not spend widget reload budget")
            let expectedPermission = recording == .persistent ? authorization != 3
                : recording == .background ? (authorization != 3 && authorization != 4) : false
            expect(state.needsPermission == expectedPermission, "Permission matrix")
            let needsApp = recording == .off ? false
                : recording == .persistent ? authorization != 3 : authorization != 3
            expect(state.requiresApp(for: recording) == needsApp, "Background execution / foreground permission routing")
            expect(state.isJapanese, "Japanese language")
            cases += 1
        }
    }
}
let english = RecordingWidgetState(language: "english")
expect(RecordingWidgetStore.homeURL.scheme == "streetprint" && RecordingWidgetStore.homeURL.host == "map", "Widget body opens the map")
expect(RecordingWidgetStore.homeURL != RecordingWidgetStore.settingsURL, "Permission settings are separate from widget body navigation")
let collecting = RecordingWidgetState(recordingMode: .background, authorization: 4, isCollecting: true, isConfigured: true)
expect(!collecting.requiresApp(for: .background), "Existing When-In-Use session need not reopen app")
expect(!english.isJapanese && english.text("日本語", "English") == "English", "Explicit English")
expect(RecordingMode(rawValue: "persistent") == .persistent, "Existing recording preference compatibility")
expect(MovementCaptureMode(rawValue: "bicycle") == .bicycle, "Existing capture preference compatibility")
expect(MovementCaptureMode.bicycle.maximumSpeedKilometersPerHour == 40, "Existing cumulative transport policy")
let encoded = String(data: try! JSONEncoder().encode(RecordingWidgetStore.load(from: defaults)), encoding: .utf8)!
expect(!encoded.contains("latitude") && !encoded.contains("longitude") && !encoded.contains("tracks"), "No route data in widget snapshot")
print("PASS: \(cases) recording × transport × permission cases; atomic snapshot, reload deduplication, language, raw-value compatibility and privacy")
