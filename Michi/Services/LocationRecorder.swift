import CoreLocation
import CoreMotion
import Foundation

final class LocationRecorder: NSObject, ObservableObject {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var isActivelyCollecting = false

    var onTrackFinished: (([GeoPoint]) -> Void)?
    var onLivePointsChanged: (([GeoPoint]) -> Void)?
    var onLocationChanged: ((CLLocation) -> Void)?
    var onPointAccepted: ((GeoPoint) -> Void)?
    var onSpeedFiltered: (() -> Void)?

    private let manager = CLLocationManager()
    private let motionManager = CMMotionActivityManager()
    private var backgroundActivitySession: CLBackgroundActivitySession?
    private var currentPoints: [GeoPoint] = []
    private var recordingMode: RecordingMode = .off
    private var movementCaptureMode: MovementCaptureMode = .all
    private var lastObservedLocation: CLLocation?
    private var isExcludingForSpeed = false
    private var currentMotionTransport: TransportMode?
    private var lastMotionEvidenceDate: Date?
    private var recentSpeedSamples: [(date: Date, kilometersPerHour: Double)] = []
    private var motorizedHoldUntil = Date.distantPast
    private var sustainedWalkingSince: Date?
    private var sustainedLowSpeedSince: Date?
    private var lastMotionHistoryQueryDate = Date.distantPast
    private var isMonitoringMotion = false
    private var hasRequestedAlwaysInSession = false

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.activityType = .otherNavigation
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 8
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
    }

    func requestForegroundAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    func requestBackgroundAuthorization() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        } else {
            hasRequestedAlwaysInSession = true
            manager.requestAlwaysAuthorization()
        }
    }

    /// フォアグラウンド復帰時に、連続測位の再開確認と新しい現在地の
    /// 1回取得を同時に行う。記録オフでも地図の現在地だけは更新する。
    func refreshCurrentLocation() {
        guard authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else {
            return
        }
        if recordingMode != .off {
            startServicesIfAuthorized()
        }
        queryRecentMotionHistoryIfAvailable()
        manager.requestLocation()
    }

    func setRecordingMode(_ mode: RecordingMode) {
        recordingMode = mode
        manager.stopMonitoringSignificantLocationChanges()

        if mode != .off {
            startServicesIfAuthorized()
        } else {
            manager.stopUpdatingLocation()
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
            stopMotionUpdates()
            finishTrackIfNeeded()
            isActivelyCollecting = false
        }
    }

    func setMovementCaptureMode(_ mode: MovementCaptureMode) {
        guard movementCaptureMode != mode else { return }
        finishTrackIfNeeded()
        movementCaptureMode = mode
        lastObservedLocation = nil
        isExcludingForSpeed = false
    }

    private func startServicesIfAuthorized() {
        guard recordingMode != .off,
              authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse else { return }
        // UIBackgroundModes(location)と組み合わせ、When In Useでも青いインジケータを
        // 表示しながらホーム画面・画面ロック中の連続更新を維持する。
        manager.allowsBackgroundLocationUpdates = true
        if backgroundActivitySession == nil {
            backgroundActivitySession = CLBackgroundActivitySession()
        }
        manager.startUpdatingLocation()
        startMotionUpdatesIfAvailable()
        queryRecentMotionHistoryIfAvailable()
        if recordingMode == .persistent,
           CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
        }
        isActivelyCollecting = true
    }

    private func consume(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 90 else { return }

        // 地図の現在地表示には、記録基準より粗い初回測位も利用する。
        // 経路として保存する地点だけを下の精度条件で厳しく選別する。
        onLocationChanged?(location)
        guard recordingMode != .off else { return }
        let maximumRecordingAccuracy = movementCaptureMode == .all ? 150.0 : 65.0
        guard location.horizontalAccuracy <= maximumRecordingAccuracy else { return }

        let observedSpeed = speedKilometersPerHour(for: location)
        lastObservedLocation = location
        if let maximumSpeed = movementCaptureMode.maximumSpeedKilometersPerHour,
           observedSpeed > maximumSpeed {
            if !isExcludingForSpeed {
                isExcludingForSpeed = true
                finishTrackIfNeeded()
                onSpeedFiltered?()
            }
            return
        }
        isExcludingForSpeed = false

        if let last = currentPoints.last {
            let gap = location.timestamp.timeIntervalSince(last.timestamp)
            if gap > 180 {
                finishTrackIfNeeded()
            } else if last.location.distance(from: location) < 4 {
                return
            }
        }

        let transportMode = resolvedTransportMode(speedKilometersPerHour: observedSpeed)
        let point = GeoPoint(location: location, transportMode: transportMode)
        onPointAccepted?(point)
        currentPoints.append(point)
        onLivePointsChanged?(currentPoints)
    }

    private func speedKilometersPerHour(for location: CLLocation) -> Double {
        let hasReliableReportedSpeed = location.speed >= 0
            && (location.speedAccuracy < 0 || location.speedAccuracy <= 3.5)
        let reported = hasReliableReportedSpeed ? location.speed * 3.6 : nil

        var calculated: Double?
        if let previous = lastObservedLocation {
            let interval = location.timestamp.timeIntervalSince(previous.timestamp)
            let distance = previous.distance(from: location)
            let minimumReliableDistance = max(
                6,
                min(30, max(previous.horizontalAccuracy, location.horizontalAccuracy) * 0.45)
            )
            if interval >= 1,
               interval <= 30,
               distance >= minimumReliableDistance {
                calculated = distance / interval * 3.6
            }
        }

        // GPSの位置飛びで徒歩が車扱いになるのを避け、端末が返す速度を優先する。
        let instantaneous = max(0, reported ?? calculated ?? 0)
        recentSpeedSamples.append((location.timestamp, instantaneous))
        let cutoff = location.timestamp.addingTimeInterval(-12)
        recentSpeedSamples.removeAll { $0.date < cutoff }
        if recentSpeedSamples.count > 5 {
            recentSpeedSamples.removeFirst(recentSpeedSamples.count - 5)
        }
        let sorted = recentSpeedSamples.map(\.kilometersPerHour).sorted()
        return sorted[sorted.count / 2]
    }

    private func resolvedTransportMode(speedKilometersPerHour speed: Double) -> TransportMode {
        let now = Date()
        // 電車を含む明らかな高速移動は、直前の徒歩判定が残っていても車カテゴリを優先する。
        if speed > 24 {
            registerMotorizedEvidence(at: now)
            return .automotive
        }
        let hasFreshMotionEvidence = lastMotionEvidenceDate.map {
            now.timeIntervalSince($0) <= 35
        } ?? false
        if hasFreshMotionEvidence, let currentMotionTransport {
            switch currentMotionTransport {
            case .automotive:
                registerMotorizedEvidence(at: now)
                return .automotive
            case .walking where speed <= 13:
                break
            case .cycling where speed <= 24:
                if now >= motorizedHoldUntil {
                    clearMotorizedState()
                    return .cycling
                }
            default:
                break
            }
        }

        // 駅・信号・渋滞で速度が落ちても、車／電車判定をすぐ徒歩へ戻さない。
        if now < motorizedHoldUntil {
            return .automotive
        }
        if motorizedHoldUntil != .distantPast {
            if hasFreshMotionEvidence,
               currentMotionTransport == .walking,
               let sustainedWalkingSince,
               now.timeIntervalSince(sustainedWalkingSince) >= 45 {
                clearMotorizedState()
                return .walking
            }
            if speed <= 8 {
                if sustainedLowSpeedSince == nil { sustainedLowSpeedSince = now }
                if let sustainedLowSpeedSince,
                   now.timeIntervalSince(sustainedLowSpeedSince) < 45 {
                    return .automotive
                }
                clearMotorizedState()
            } else {
                sustainedLowSpeedSince = nil
                return .automotive
            }
        }
        return TransportMode.infer(speedMetersPerSecond: speed / 3.6)
    }

    private func registerMotorizedEvidence(at date: Date) {
        currentMotionTransport = .automotive
        lastMotionEvidenceDate = date
        motorizedHoldUntil = max(motorizedHoldUntil, date.addingTimeInterval(90))
        sustainedWalkingSince = nil
        sustainedLowSpeedSince = nil
    }

    private func clearMotorizedState() {
        motorizedHoldUntil = .distantPast
        sustainedWalkingSince = nil
        sustainedLowSpeedSince = nil
    }

    private func startMotionUpdatesIfAvailable() {
        guard !isMonitoringMotion,
              CMMotionActivityManager.isActivityAvailable() else { return }
        isMonitoringMotion = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            guard activity.confidence != .low else { return }
            if activity.automotive {
                self.registerMotorizedEvidence(at: Date())
            } else if activity.cycling {
                self.currentMotionTransport = .cycling
                self.lastMotionEvidenceDate = Date()
                self.sustainedWalkingSince = nil
            } else if activity.walking || activity.running {
                self.currentMotionTransport = .walking
                self.lastMotionEvidenceDate = Date()
                if self.sustainedWalkingSince == nil {
                    self.sustainedWalkingSince = Date()
                }
            }
        }
    }

    private func queryRecentMotionHistoryIfAvailable() {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMotionHistoryQueryDate) >= 30 else { return }
        lastMotionHistoryQueryDate = now
        motionManager.queryActivityStarting(
            from: now.addingTimeInterval(-15 * 60),
            to: now,
            to: .main
        ) { [weak self] activities, _ in
            guard let self,
                  let activities,
                  let latestReliable = activities.last(where: { $0.confidence != .low }) else { return }

            if latestReliable.automotive {
                self.registerMotorizedEvidence(at: Date())
                return
            }
            // 復帰直前まで車／電車だった場合は、駅や信号でstationaryへ変わっていても保持する。
            if let recentAutomotive = activities.last(where: {
                $0.confidence != .low && $0.automotive
            }), now.timeIntervalSince(recentAutomotive.startDate) <= 3 * 60 {
                self.registerMotorizedEvidence(at: Date())
            }
        }
    }

    private func stopMotionUpdates() {
        guard isMonitoringMotion else { return }
        motionManager.stopActivityUpdates()
        isMonitoringMotion = false
        currentMotionTransport = nil
        lastMotionEvidenceDate = nil
        recentSpeedSamples = []
        clearMotorizedState()
    }

    private func finishTrackIfNeeded() {
        defer {
            currentPoints = []
            onLivePointsChanged?([])
        }
        guard currentPoints.count >= 4 else { return }
        let distance = zip(currentPoints, currentPoints.dropFirst()).reduce(0) {
            $0 + $1.0.location.distance(from: $1.1.location)
        }
        guard distance >= 30 else { return }
        onTrackFinished?(currentPoints)
    }
}

extension LocationRecorder: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            startServicesIfAuthorized()
            if authorizationStatus == .authorizedWhenInUse,
               recordingMode == .persistent,
               !hasRequestedAlwaysInSession {
                hasRequestedAlwaysInSession = true
                manager.requestAlwaysAuthorization()
            }
        } else if authorizationStatus == .denied || authorizationStatus == .restricted {
            backgroundActivitySession?.invalidate()
            backgroundActivitySession = nil
            stopMotionUpdates()
            isActivelyCollecting = false
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        locations.forEach(consume)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard (error as? CLError)?.code != .locationUnknown else { return }
        isActivelyCollecting = false
    }

    func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        finishTrackIfNeeded()
    }

    func locationManagerDidResumeLocationUpdates(_ manager: CLLocationManager) {
        isActivelyCollecting = recordingMode != .off
    }
}
