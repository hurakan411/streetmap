import AppIntents

extension RecordingMode: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "記録モード"
    static var caseDisplayRepresentations: [RecordingMode: DisplayRepresentation] = [
        .persistent: "常時記録", .background: "バックグラウンドまで", .off: "計測オフ"
    ]
}

extension MovementCaptureMode: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "記録する移動"
    static var caseDisplayRepresentations: [MovementCaptureMode: DisplayRepresentation] = [
        .walking: "徒歩のみ", .bicycle: "自転車まで", .all: "すべての移動"
    ]
}

struct SetRecordingModeIntent: AppIntent {
    static var title: LocalizedStringResource = "記録モードを変更"
    static var isDiscoverable = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.dynamic) }

    @Parameter(title: "記録モード") var mode: RecordingMode
    init() {}
    init(mode: RecordingMode) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if STREETPRINT_WIDGET_EXTENSION
        // The host target's foreground-continuable conformance routes this
        // intent to the app. Never simulate a successful change in a widget.
        try requireRecordingHostApp()
        #else
        let store = AppStore.shared
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2") else {
            try await requestToContinueInForeground()
            return .result()
        }
        if !store.canApplyWidgetRecordingMode(mode) {
            try await requestToContinueInForeground()
            store.widgetRequestedRecordingMode = mode
            store.showsWidgetRecordingSettings = true
        } else {
            if store.widgetRecordingNeedsForeground(mode) {
                try await requestToContinueInForeground()
            }
            store.setRecordingMode(mode)
        }
        store.publishRecordingWidgetState()
        #endif
        return .result()
    }
}

struct SetMovementCaptureModeIntent: AppIntent {
    static var title: LocalizedStringResource = "記録する移動を変更"
    static var isDiscoverable = false
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.dynamic) }

    @Parameter(title: "記録する移動") var mode: MovementCaptureMode
    init() {}
    init(mode: MovementCaptureMode) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if STREETPRINT_WIDGET_EXTENSION
        try requireRecordingHostApp()
        #else
        let store = AppStore.shared
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2") else {
            try await requestToContinueInForeground()
            return .result()
        }
        // Changes the capture policy, not the map's visibility filter.
        // In particular, choosing a transport policy must never resume GPS.
        store.setMovementCaptureMode(mode)
        store.publishRecordingWidgetState()
        #endif
        return .result()
    }
}

// Widgets cannot reliably show a foreground-continuation confirmation. Use
// an explicitly foreground intent for permission/setup and When-In-Use
// session starts, selected from the latest widget snapshot.
struct SetRecordingModeInAppIntent: AppIntent {
    static var title: LocalizedStringResource = "記録モードを変更"
    static var isDiscoverable = false
    static var openAppWhenRun = true
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    @Parameter(title: "記録モード") var mode: RecordingMode
    init() {}
    init(mode: RecordingMode) { self.mode = mode }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if STREETPRINT_WIDGET_EXTENSION
        try requireRecordingHostApp()
        #else
        let store = AppStore.shared
        guard UserDefaults.standard.bool(forKey: "hasCompletedOnboardingV2") else { return .result() }
        if store.canApplyWidgetRecordingMode(mode) {
            store.setRecordingMode(mode)
        } else {
            store.widgetRequestedRecordingMode = mode
            store.showsWidgetRecordingSettings = true
        }
        store.publishRecordingWidgetState()
        #endif
        return .result()
    }
}

#if !STREETPRINT_WIDGET_EXTENSION
// iOS 17–18 compatibility; iOS 26 uses supportedModes above. App-only
// conformance ensures both intents operate the one real LocationRecorder.
extension SetRecordingModeIntent: ForegroundContinuableIntent {}
extension SetMovementCaptureModeIntent: ForegroundContinuableIntent {}
#endif

private enum WidgetRecordingError: Error, CustomLocalizedStringResourceConvertible {
    case openApp
    var localizedStringResource: LocalizedStringResource { "アプリで記録設定を開いてください" }
}

private func requireRecordingHostApp() throws {
    throw WidgetRecordingError.openApp
}
