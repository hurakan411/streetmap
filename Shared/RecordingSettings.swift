import Foundation

// Raw values are the existing on-device preference values. Keep them stable.
enum RecordingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case persistent, background, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .persistent: "常時記録"
        case .background: "バックグラウンドまで"
        case .off: "計測オフ"
        }
    }
    var detail: String {
        switch self {
        case .persistent: "終了後も大きな移動で再開を試みます"
        case .background: "起動中・ホーム画面・画面ロック中だけ記録"
        case .off: "移動経路の計測と保存を停止します"
        }
    }
    var symbol: String {
        switch self {
        case .persistent: "location.fill.viewfinder"
        case .background: "rectangle.stack.badge.play.fill"
        case .off: "pause.circle.fill"
        }
    }
}

enum MovementCaptureMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case walking, bicycle, all
    var id: String { rawValue }
    var title: String {
        switch self {
        case .walking: "徒歩のみ"
        case .bicycle: "自転車まで"
        case .all: "すべての移動"
        }
    }
    var detail: String {
        switch self {
        case .walking: "時速10km以下を記録"
        case .bicycle: "時速40km以下を記録"
        case .all: "自動車・電車を含めて速度制限なし"
        }
    }
    var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .bicycle: "bicycle"
        case .all: "car.side.fill"
        }
    }
    var maximumSpeedKilometersPerHour: Double? {
        switch self {
        case .walking: 10
        case .bicycle: 40
        case .all: nil
        }
    }
}

struct RecordingWidgetState: Codable, Equatable {
    var recordingMode: RecordingMode = .off
    var movementMode: MovementCaptureMode = .all
    var authorization: Int = 0
    var isCollecting = false
    var isConfigured = false
    var language = "system"
    var theme = "editorialGlass"

    var isJapanese: Bool {
        language == "japanese" || (language == "system" && Locale.preferredLanguages.first?.hasPrefix("ja") == true)
    }

    // CLAuthorizationStatus raw values: always = 3, when-in-use = 4.
    // Never claim an unauthorized selection is actively recording.
    var needsPermission: Bool {
        switch recordingMode {
        case .persistent: authorization != 3
        case .background: authorization != 3 && authorization != 4
        case .off: false
        }
    }

    func requiresApp(for mode: RecordingMode) -> Bool {
        guard isConfigured else { return true }
        switch mode {
        case .off: return false
        case .persistent: return authorization != 3
        case .background:
            return authorization != 3 && (authorization != 4 || !isCollecting)
        }
    }

    func text(_ japanese: String, _ english: String) -> String { isJapanese ? japanese : english }
}

enum RecordingWidgetStore {
    static let groupID = "group.jp.michi.walkmap"
    static let kind = "StreetPrintRecordingWidget"
    static let homeURL = URL(string: "streetprint://map")!
    static let settingsURL = URL(string: "streetprint://recording-settings")!
    private static let key = "recordingWidgetState.v1"

    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: groupID)) -> RecordingWidgetState {
        guard let data = defaults?.data(forKey: key),
              let state = try? JSONDecoder().decode(RecordingWidgetState.self, from: data) else {
            return RecordingWidgetState()
        }
        return state
    }

    // Only the main app writes this display snapshot. Widget intents execute
    // in that app and apply changes to the real recorder before publishing.
    // No location, movement history or recovery anchor is shared.
    @discardableResult
    static func save(_ state: RecordingWidgetState, to defaults: UserDefaults? = UserDefaults(suiteName: groupID)) -> Bool {
        guard let defaults, let data = try? JSONEncoder().encode(state) else { return false }
        if let oldData = defaults.data(forKey: key),
           let previous = try? JSONDecoder().decode(RecordingWidgetState.self, from: oldData),
           previous == state { return false }
        defaults.set(data, forKey: key)
        return true
    }
}
