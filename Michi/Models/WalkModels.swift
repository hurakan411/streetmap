import CoreLocation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case japanese
    case english

    var id: String { rawValue }

    static var deviceDefault: AppLanguage {
        let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
        return preferred.hasPrefix("ja") ? .japanese : .english
    }

    var localeIdentifier: String {
        switch self {
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? ""
            return preferred.hasPrefix("ja") ? "ja" : "en"
        case .japanese: return "ja"
        case .english: return "en"
        }
    }
}

struct GeoPoint: Codable, Hashable, Identifiable {
    var latitude: Double
    var longitude: Double
    var timestamp: Date
    var horizontalAccuracy: Double
    var speed: Double
    // nilは旧バージョンで保存された実測点との後方互換用。
    var isEstimated: Bool?
    // nilは移動手段の保存前に作られた履歴との後方互換用。
    var transportMode: TransportMode?

    var id: String { "\(timestamp.timeIntervalSince1970)-\(latitude)-\(longitude)" }
    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    var location: CLLocation {
        CLLocation(
            coordinate: coordinate,
            altitude: 0,
            horizontalAccuracy: horizontalAccuracy,
            verticalAccuracy: -1,
            course: -1,
            speed: speed,
            timestamp: timestamp
        )
    }

    init(location: CLLocation, transportMode: TransportMode? = nil) {
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        timestamp = location.timestamp
        horizontalAccuracy = location.horizontalAccuracy
        speed = max(0, location.speed)
        isEstimated = false
        self.transportMode = transportMode
    }

    init(
        latitude: Double,
        longitude: Double,
        timestamp: Date,
        horizontalAccuracy: Double = 8,
        speed: Double = 1.2,
        isEstimated: Bool = false,
        transportMode: TransportMode? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.timestamp = timestamp
        self.horizontalAccuracy = horizontalAccuracy
        self.speed = speed
        self.isEstimated = isEstimated
        self.transportMode = transportMode
    }

    var estimated: Bool { isEstimated == true }
    var resolvedTransportMode: TransportMode {
        let speedBasedMode = TransportMode.infer(speedMetersPerSecond: speed)
        guard let transportMode else { return speedBasedMode }
        // 旧判定で徒歩／自転車として保存された明らかな高速区間は、履歴ファイルを
        // 破壊的に書き換えず表示時に補正する。渋滞中の車判定はそのまま維持する。
        if speedBasedMode == .automotive, transportMode != .automotive {
            return .automotive
        }
        if transportMode == .walking, speedBasedMode == .cycling {
            return .cycling
        }
        return transportMode
    }
}

struct WalkTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var rawPoints: [GeoPoint]
    var matchedPoints: [GeoPoint]
    var createdAt: Date
    var isRoadMatched: Bool
    // 推定復元された区間かどうか。Optionalにして既存の履歴JSONをそのまま読めるようにする。
    var isEstimated: Bool?

    init(
        id: UUID = UUID(),
        rawPoints: [GeoPoint],
        matchedPoints: [GeoPoint] = [],
        createdAt: Date? = nil,
        isRoadMatched: Bool = false,
        isEstimated: Bool = false
    ) {
        self.id = id
        self.rawPoints = rawPoints
        self.matchedPoints = matchedPoints
        self.createdAt = createdAt ?? rawPoints.first?.timestamp ?? Date()
        self.isRoadMatched = isRoadMatched
        self.isEstimated = isEstimated
    }

    var displayPoints: [GeoPoint] { matchedPoints.count > 1 ? matchedPoints : rawPoints }
    var startDate: Date { rawPoints.first?.timestamp ?? createdAt }
    var endDate: Date { rawPoints.last?.timestamp ?? createdAt }
    var containsEstimatedData: Bool {
        isEstimated == true || displayPoints.contains(where: \.estimated)
    }

    var distance: CLLocationDistance {
        RecordedDistanceCalculator.legs(from: rawPoints, isEstimatedTrack: isEstimated == true)
            .reduce(0) { $0 + $1.distance }
    }
}

enum PeriodPreset: String, CaseIterable, Identifiable {
    case today = "今日"
    case month = "今月"
    case year = "今年"
    case all = "全て"
    var id: String { rawValue }
}

enum MapDisplayMode: String, CaseIterable {
    case map
    case excavation
    case routesOnly
}

enum TransportMode: String, Codable, CaseIterable, Identifiable, Hashable {
    case walking
    case cycling
    case automotive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .walking: "徒歩"
        case .cycling: "自転車"
        case .automotive: "車"
        }
    }

    var symbol: String {
        switch self {
        case .walking: "figure.walk"
        case .cycling: "bicycle"
        case .automotive: "car.side.fill"
        }
    }

    static func infer(speedMetersPerSecond speed: Double) -> TransportMode {
        let kilometersPerHour = max(0, speed) * 3.6
        if kilometersPerHour <= 8 { return .walking }
        if kilometersPerHour <= 24 { return .cycling }
        return .automotive
    }
}

enum RecordingMode: String, Codable, CaseIterable, Identifiable {
    case persistent
    case background
    case off

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

enum MovementCaptureMode: String, Codable, CaseIterable, Identifiable {
    case walking
    case bicycle
    case all

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

enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case editorialGlass
    case midnightPulse
    case paperAtlas

    var id: String { rawValue }
    var name: String {
        switch self {
        case .editorialGlass: "Editorial Glass"
        case .midnightPulse: "Midnight Pulse"
        case .paperAtlas: "Modern Paper Atlas"
        }
    }
    var subtitle: String {
        switch self {
        case .editorialGlass: "ミルキーガラス + コバルト"
        case .midnightPulse: "濃紺 + エレクトリックシアン"
        case .paperAtlas: "生成り紙 + 藍色インク"
        }
    }
    var routeColor: Color {
        switch self {
        case .editorialGlass: Color(red: 0.09, green: 0.42, blue: 1.0)
        case .midnightPulse: Color(red: 0.21, green: 0.84, blue: 1.0)
        case .paperAtlas: Color(red: 0.12, green: 0.31, blue: 0.47)
        }
    }
    var interactionColor: Color { routeColor }
    var uiRouteColor: UIColor { UIColor(routeColor) }
    var uiInteractionColor: UIColor { UIColor(interactionColor) }
    var backgroundColor: Color {
        switch self {
        case .editorialGlass: Color(red: 0.98, green: 0.98, blue: 0.97)
        case .midnightPulse: Color(red: 0.027, green: 0.067, blue: 0.12)
        case .paperAtlas: Color(red: 0.96, green: 0.93, blue: 0.85)
        }
    }
    var foregroundColor: Color {
        switch self {
        case .midnightPulse: Color(red: 0.91, green: 0.96, blue: 1)
        default: Color(red: 0.09, green: 0.10, blue: 0.11)
        }
    }
    var controlBackground: Color {
        switch self {
        case .editorialGlass: .white.opacity(0.88)
        case .midnightPulse: Color(red: 0.025, green: 0.09, blue: 0.15).opacity(0.94)
        case .paperAtlas: Color(red: 0.98, green: 0.95, blue: 0.87).opacity(0.96)
        }
    }
    var controlBorder: Color {
        switch self {
        case .editorialGlass: .white.opacity(0.76)
        case .midnightPulse: routeColor.opacity(0.24)
        case .paperAtlas: Color(red: 0.35, green: 0.26, blue: 0.16).opacity(0.22)
        }
    }
    var selectedControlBackground: Color {
        switch self {
        case .editorialGlass: .white
        case .midnightPulse: routeColor.opacity(0.18)
        case .paperAtlas: routeColor
        }
    }
    var selectedControlForeground: Color {
        switch self {
        case .editorialGlass: foregroundColor
        case .midnightPulse: routeColor
        case .paperAtlas: .white
        }
    }
    var shadowColor: Color {
        switch self {
        case .midnightPulse: routeColor.opacity(0.12)
        default: .black.opacity(0.11)
        }
    }
    var prefersDarkMap: Bool { self == .midnightPulse }
    var lineScale: CGFloat {
        switch self {
        case .editorialGlass: 1.05
        case .midnightPulse: 1.2
        case .paperAtlas: 1.1
        }
    }
}

struct WalkStats: Equatable {
    var newRoads: Int
    var distance: CLLocationDistance
    var activeDays: Int

    static let zero = WalkStats(newRoads: 0, distance: 0, activeDays: 0)
}

struct WeightedSegment: Identifiable {
    let id: String
    let start: CLLocationCoordinate2D
    let end: CLLocationCoordinate2D
    let frequency: Int
    let isEstimated: Bool
    let firstVisitedAt: Date
    let transportMode: TransportMode
}

enum SegmentKey {
    static func make(_ first: GeoPoint, _ second: GeoPoint) -> String {
        let midLat = (first.latitude + second.latitude) / 2
        let midLon = (first.longitude + second.longitude) / 2
        let latBucket = Int((midLat * 4_000).rounded())
        let lonBucket = Int((midLon * 4_000).rounded())
        var angle = atan2(second.latitude - first.latitude, second.longitude - first.longitude)
        if angle < 0 { angle += .pi }
        if angle >= .pi { angle -= .pi }
        let angleBucket = Int((angle / (.pi / 8)).rounded()) % 8
        return "\(latBucket):\(lonBucket):\(angleBucket)"
    }
}
