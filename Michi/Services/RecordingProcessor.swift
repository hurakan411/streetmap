import CoreLocation
import Foundation
import MapKit

struct MotionEvidence: Codable, Hashable {
    var startDate: Date
    var receivedAt: Date
    var confidence: Int
    var walking: Bool
    var running: Bool
    var cycling: Bool
    var automotive: Bool
    var stationary: Bool

    func isFresh(at date: Date) -> Bool {
        confidence >= 1 && startDate <= date && date.timeIntervalSince(receivedAt) <= 90
            && date.timeIntervalSince(receivedAt) >= -5
    }
    var exclusiveMode: TransportMode? {
        let foot = walking || running
        guard [foot, cycling, automotive].filter({ $0 }).count == 1 else { return nil }
        return foot ? .walking : cycling ? .cycling : .automotive
    }
}

struct RecordingEvidence: Codable, Hashable {
    var version = RecordingProcessor.version
    var coordinateStatus: String
    var coordinateReason: String
    var classificationReason: String
    var classificationPending: Bool
    var representativeSpeedKmh: Double?
    var captureExcluded = false
}

/// Pure, deterministic processing of immutable sensor fields. Running this on
/// an active buffer allows a later reliable fix to resolve pending observations
/// and backdate a confirmed transport transition without losing its beginning.
enum RecordingProcessor {
    static let version = 3

    static func process(_ input: [GeoPoint], captureMode: MovementCaptureMode = .all) -> [GeoPoint] {
        guard !input.isEmpty else { return [] }
        var result = input
        let coordinates = input.map { MKMapPoint($0.coordinate) }
        let referenceLatitude = input.first(where: { CLLocationCoordinate2DIsValid($0.coordinate) })?.latitude ?? 0
        let metersPerPoint = MKMetersPerMapPointAtLatitude(referenceLatitude)
        func distance(_ a: Int, _ b: Int) -> Double {
            hypot(coordinates[a].x - coordinates[b].x, coordinates[a].y - coordinates[b].y) * metersPerPoint
        }
        func interval(_ a: Int, _ b: Int) -> Double { input[b].timestamp.timeIntervalSince(input[a].timestamp) }
        var reasons = Array(repeating: "observed", count: input.count)
        var accepted = input.map {
            CLLocationCoordinate2DIsValid($0.coordinate) && $0.horizontalAccuracy.isFinite
                && $0.horizontalAccuracy >= 0 && $0.horizontalAccuracy <= 100
                && $0.timestamp.timeIntervalSince1970.isFinite && !$0.estimated
        }
        for i in input.indices {
            if input[i].horizontalAccuracy > 65 {
                let motion = input[i].motionEvidence
                let vehicleEvidence = motion.map {
                    $0.isFresh(at: input[i].timestamp) && ($0.exclusiveMode == .automotive || $0.exclusiveMode == .cycling)
                } ?? false
                if !vehicleEvidence { accepted[i] = false }
            }
            if !accepted[i] { reasons[i] = "invalid_or_inaccurate_fix" }
        }

        // Reject an isolated excursion that rapidly returns to the original
        // corridor, not a real sustained bus/train departure. Core Motion's
        // genuine motorized evidence is kept separate from inferred labels.
        if input.count >= 3 {
            for i in 1..<(input.count - 1) where accepted[i] && accepted[i - 1] {
                let dt = interval(i - 1, i)
                guard dt > 0, dt <= 30 else { continue }
                let motion = input[i].motionEvidence
                let genuineVehicle = motion.map { $0.isFresh(at: input[i].timestamp) && $0.exclusiveMode == .automotive } ?? false
                guard !genuineVehicle else { continue }
                let outward = distance(i - 1, i)
                let uncertainty = max(25, min(70, input[i - 1].horizontalAccuracy + input[i].horizontalAccuracy))
                guard outward > 6 * dt + uncertainty else { continue }
                var j = i + 1
                while j < input.count && interval(i - 1, j) <= 45 {
                    if accepted[j] {
                        let direct = distance(i - 1, j)
                        let returning = distance(i, j)
                        if direct < max(25, 2 * interval(i - 1, j)),
                           outward + returning > max(80, direct * 3 + uncertainty) {
                            for index in i..<j { accepted[index] = false; reasons[index] = "returning_gps_excursion" }
                            break
                        }
                    }
                    j += 1
                }
            }
        }

        var previous: Int?
        var pending = Set<Int>()
        for i in input.indices where accepted[i] {
            if let a = previous {
                let dt = interval(a, i), d = distance(a, i)
                let uncertainty = max(15, min(70, input[a].horizontalAccuracy + input[i].horizontalAccuracy))
                if dt <= 0 || (dt <= 30 && d > 120 * dt + uncertainty) {
                    accepted[i] = false; reasons[i] = "impossible_position_jump"; continue
                }
                let reliable = reliableSpeed(input[i])
                let motionWalking = input[i].motionEvidence.map {
                    $0.isFresh(at: input[i].timestamp) && $0.exclusiveMode == .walking
                } ?? false
                let conflictsWithSpeed = reliable.map { d > max(4, $0 * 2) * dt + uncertainty * 1.5 } ?? false
                if dt > 0 && dt <= 30 && d > 6 * dt + uncertainty && (motionWalking || conflictsWithSpeed) {
                    // Wait for subsequent fixes to corroborate a real departure.
                    let last = min(input.count - 1, i + 30)
                    let corroborated = (i...last).contains { j in
                        let duration = interval(i, j)
                        return accepted[j] && duration >= 12 && duration <= 40
                            && distance(i, j) / duration >= 5
                    }
                    if !corroborated {
                        accepted[i] = false
                        pending.insert(i); reasons[i] = "awaiting_position_confirmation"
                        continue
                    }
                }
            }
            previous = i
        }

        var classifier = TemporalTransportClassifier()
        for i in input.indices {
            var evidence = RecordingEvidence(
                coordinateStatus: accepted[i] ? "accepted" : pending.contains(i) ? "pending" : "rejected",
                coordinateReason: reasons[i], classificationReason: "no_reliable_position",
                classificationPending: true, representativeSpeedKmh: nil
            )
            if accepted[i] {
                let decision = classifier.consume(input[i])
                result[i].transportMode = decision.mode
                evidence.classificationReason = decision.reason
                evidence.classificationPending = decision.pending
                evidence.representativeSpeedKmh = decision.speed
                if let start = decision.confirmedSince {
                    // Re-label only the active, unsaved candidate buffer. Sensor
                    // coordinates, timestamps, speeds and motion evidence stay intact.
                    var j = i - 1
                    while j >= 0 && input[j].timestamp >= start {
                        if accepted[j] {
                            result[j].transportMode = decision.mode
                            result[j].recordingEvidence?.classificationPending = false
                            result[j].recordingEvidence?.classificationReason = "confirmed_transition"
                        }
                        j -= 1
                    }
                }
            } else {
                result[i].transportMode = nil
            }
            result[i].recordingEvidence = evidence
        }
        for i in result.indices {
            guard result[i].transportMode != nil, let evidence = result[i].recordingEvidence else { continue }
            // Never filter a transition while its mode is still unresolved.
            let excluded = !evidence.classificationPending && captureMode.maximumSpeedKilometersPerHour.map {
                (evidence.representativeSpeedKmh ?? 0) > $0
            } == true
            result[i].recordingEvidence?.captureExcluded = excluded
        }
        return result
    }

    static func reliableSpeed(_ point: GeoPoint) -> Double? {
        guard point.reportedSpeedIsValid != false, point.speed.isFinite, point.speed >= 0,
              let accuracy = point.speedAccuracy, accuracy >= 0, accuracy <= 1.5,
              point.horizontalAccuracy <= 40 else { return nil }
        return point.speed
    }
}

private struct TemporalTransportClassifier {
    struct Decision {
        var mode: TransportMode
        var pending: Bool
        var reason: String
        var speed: Double?
        var confirmedSince: Date?
    }
    private var window: [GeoPoint] = []
    private var stable: TransportMode = .walking
    private var candidate: (mode: TransportMode, since: Date, boundary: Date)?
    private var lastEvidenceOfVehicle = Date.distantPast
    private var latestMotionEvent = Date.distantPast

    mutating func consume(_ point: GeoPoint) -> Decision {
        let now = point.timestamp
        if let last = window.last, now.timeIntervalSince(last.timestamp) > 45 {
            window = []; candidate = nil; stable = .walking; lastEvidenceOfVehicle = .distantPast
        }
        window.append(point)
        window.removeAll { now.timeIntervalSince($0.timestamp) > 30 }
        let samples = window.compactMap(RecordingProcessor.reliableSpeed).sorted()
        let reported = samples.isEmpty ? nil : samples[samples.count / 2] * 3.6
        let anchor = window.first!
        let duration = now.timeIntervalSince(anchor.timestamp)
        let displacement = anchor.location.distance(from: point.location)
        let uncertainty = max(8, min(40, (anchor.horizontalAccuracy + point.horizontalAccuracy) * 0.5))
        let positional = duration >= 5 ? max(0, displacement - uncertainty) / duration * 3.6 : 0
        let speed = reported ?? (duration >= 10 ? positional : 0)
        let motion = point.motionEvidence.flatMap { $0.isFresh(at: now) ? $0 : nil }
        let hint = motion?.exclusiveMode
        if reported == nil && duration < 10 && hint == nil {
            return Decision(mode: stable, pending: true, reason: "awaiting_speed_or_motion_evidence", speed: nil)
        }
        if hint == .automotive, let motion, motion.startDate > latestMotionEvent {
            // This timestamp is an actual sensor event, never refreshed by
            // reading a previous classifier result or querying old history.
            latestMotionEvent = motion.startDate
            lastEvidenceOfVehicle = motion.startDate
        }

        let desired: TransportMode
        let confirmation: TimeInterval
        let reason: String
        if speed >= 25 && positional >= 18 {
            desired = .automotive; confirmation = 15; reason = "sustained_speed_and_displacement"
        } else if hint == .walking && speed <= 13 {
            desired = .walking; confirmation = stable == .walking ? 0 : 5; reason = "motion_walking"
        } else if hint == .automotive && speed >= 6 && positional >= 4 {
            desired = .automotive; confirmation = 6; reason = "motion_and_vehicle_movement"
        } else if hint == .cycling && speed >= 3 && speed < 30 {
            desired = .cycling; confirmation = 6; reason = "motion_cycling"
        } else if hint != .walking && speed >= 13 && speed <= 24 && positional >= 10 {
            desired = .cycling; confirmation = 20; reason = "sustained_cycling_speed"
        } else if stable == .automotive && now.timeIntervalSince(lastEvidenceOfVehicle) < 90 && hint != .walking {
            desired = .automotive; confirmation = 0; reason = "recent_independent_vehicle_evidence"
        } else {
            desired = .walking; confirmation = stable == .walking ? 0 : 20; reason = "walking_speed_window"
        }
        if desired == stable {
            candidate = nil
            if desired == .automotive && (positional >= 18 || (hint == .automotive && positional >= 4)) {
                lastEvidenceOfVehicle = now
            }
            return Decision(mode: stable, pending: false, reason: reason, speed: speed)
        }
        if candidate?.mode != desired {
            let threshold = desired == .automotive ? (hint == .automotive ? 6.0 : 25.0) : desired == .cycling ? 13.0 : 8.0
            let measuredBoundary = window.first(where: { sample in
                guard let measured = RecordingProcessor.reliableSpeed(sample) else { return false }
                return desired == .walking ? measured * 3.6 <= threshold : measured * 3.6 >= threshold
            })?.timestamp
            let positionBoundary = zip(window, window.dropFirst()).first(where: { a, b in
                let dt = b.timestamp.timeIntervalSince(a.timestamp)
                guard dt > 0, dt <= 15 else { return false }
                let speed = a.location.distance(from: b.location) / dt * 3.6
                return desired == .walking ? speed <= threshold : speed >= threshold
            })?.1.timestamp
            let speedBoundary = measuredBoundary ?? positionBoundary ?? now
            let boundary = desired == .walking && hint == .walking
                ? max(speedBoundary, motion!.startDate) : speedBoundary
            candidate = (desired, now, boundary)
        }
        if let candidate, now.timeIntervalSince(candidate.since) >= confirmation {
            stable = desired
            if desired == .automotive { lastEvidenceOfVehicle = now }
            self.candidate = nil
            return Decision(mode: stable, pending: false, reason: reason, speed: speed,
                            confirmedSince: candidate.boundary)
        }
        return Decision(mode: stable, pending: true, reason: "awaiting_\(desired.rawValue)_confirmation", speed: speed)
    }
}
