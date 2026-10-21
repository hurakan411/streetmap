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
    private var currentMotionEvidence: MotionEvidence?
    private var processingTask: Task<Void, Never>?
    private var generation = UUID()
    private var lastAcceptedCallbackDate = Date.distantPast
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
        guard CLLocationCoordinate2DIsValid(location.coordinate),
              location.horizontalAccuracy >= 0,
              abs(location.timestamp.timeIntervalSinceNow) < 90 else { return }
        onLocationChanged?(location)
        guard recordingMode != .off else { return }
        if let last = currentPoints.last {
            let gap = location.timestamp.timeIntervalSince(last.timestamp)
            guard gap > 0 else { return }
            if gap > 180 { finishTrackIfNeeded() }
        }
        // Do not discard the beginning of a bus/train journey while its mode
        // is pending. Accuracy and mode decisions are attached as metadata.
        var point = GeoPoint(location: location)
        point.motionEvidence = currentMotionEvidence
        currentPoints.append(point)
        scheduleProcessing()
    }

    private func scheduleProcessing() {
        guard processingTask == nil, !currentPoints.isEmpty else { return }
        let snapshot = currentPoints
        let mode = movementCaptureMode
        let token = generation
        processingTask = Task { @MainActor [weak self] in
            let processed = await Task.detached(priority: .userInitiated) {
                RecordingProcessor.process(snapshot, captureMode: mode)
            }.value
            guard let self, !Task.isCancelled, self.generation == token else { return }
            self.onLivePointsChanged?(processed)
            if let latest = processed.last(where: { $0.isUsableObservation }),
               latest.timestamp > self.lastAcceptedCallbackDate {
                self.lastAcceptedCallbackDate = latest.timestamp
                self.onPointAccepted?(latest)
            }
            self.processingTask = nil
            if self.currentPoints.count > snapshot.count { self.scheduleProcessing() }
        }
    }

    private func motionEvidence(_ activity: CMMotionActivity, receivedAt: Date) -> MotionEvidence {
        MotionEvidence(startDate: activity.startDate, receivedAt: receivedAt,
                       confidence: Int(activity.confidence.rawValue), walking: activity.walking,
                       running: activity.running, cycling: activity.cycling,
                       automotive: activity.automotive, stationary: activity.stationary)
    }

    private func startMotionUpdatesIfAvailable() {
        guard !isMonitoringMotion, CMMotionActivityManager.isActivityAvailable() else { return }
        isMonitoringMotion = true
        motionManager.startActivityUpdates(to: .main) { [weak self] activity in
            guard let self, let activity else { return }
            self.currentMotionEvidence = self.motionEvidence(activity, receivedAt: Date())
        }
    }

    private func queryRecentMotionHistoryIfAvailable() {
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        let now = Date()
        guard now.timeIntervalSince(lastMotionHistoryQueryDate) >= 30 else { return }
        lastMotionHistoryQueryDate = now
        motionManager.queryActivityStarting(from: now.addingTimeInterval(-3 * 60), to: now, to: .main) {
            [weak self] activities, _ in
            guard let self, let latest = activities?.last,
                  latest.startDate > (self.currentMotionEvidence?.startDate ?? .distantPast) else { return }
            // A historical event retains its original age. A query must not
            // make stale automotive evidence look newly observed.
            self.currentMotionEvidence = self.motionEvidence(latest, receivedAt: latest.startDate)
        }
    }

    private func stopMotionUpdates() {
        if isMonitoringMotion { motionManager.stopActivityUpdates() }
        isMonitoringMotion = false
        currentMotionEvidence = nil
    }

    private func finishTrackIfNeeded() {
        processingTask?.cancel()
        processingTask = nil
        generation = UUID()
        let snapshot = currentPoints
        currentPoints = []
        if snapshot.count >= 2 {
            let processed = RecordingProcessor.process(snapshot, captureMode: movementCaptureMode)
            // Preserve pending and rejected raw observations too. They are
            // excluded from visible geometry, not erased from the sensor archive.
            onTrackFinished?(processed)
        }
        onLivePointsChanged?([])
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
