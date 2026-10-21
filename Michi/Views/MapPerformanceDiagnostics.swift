import Foundation

// Diagnostic aggregates deliberately contain no coordinates, route IDs or
// location history. Only explicit diagnostic sessions enable collection.
struct MapTimingDistribution: Codable {
    private(set) var count = 0
    private(set) var totalMS = 0.0
    private(set) var maximumMS = 0.0
    private var bins = [Int](repeating: 0, count: 1001)
    mutating func add(_ milliseconds: Double) {
        guard milliseconds.isFinite, milliseconds >= 0 else { return }
        count += 1; totalMS += milliseconds; maximumMS = max(maximumMS, milliseconds)
        bins[min(1000, Int(min(1000, ceil(milliseconds))))] += 1
    }
    var averageMS: Double { count == 0 ? 0 : totalMS / Double(count) }
    var p95MS: Double {
        guard count > 0 else { return 0 }
        let target = Int(ceil(Double(count) * 0.95))
        var sum = 0
        for (i, value) in bins.enumerated() {
            sum += value
            if sum >= target { return i == 1000 ? maximumMS : Double(i) }
        }
        return maximumMS
    }
}

final class MapPerformanceRecorder {
    struct Token { let name: String; let start: TimeInterval; let session: Int }
    struct Result: Codable {
        let stage: String
        let interrupted: Bool
        let durationSeconds: Double
        let metadata: [String: String]
        let interactionFrames: MapTimingDistribution
        let hitchIntervals: Int
        let estimatedMissedCallbacks: Int
        let operations: [String: MapTimingDistribution]
    }
    static let shared = MapPerformanceRecorder()
    private let lock = NSLock()
    private var active = false
    private var generation = 0
    private var startTime = 0.0
    private var stage = ""
    private var metadata: [String: String] = [:]
    private var frames = MapTimingDistribution()
    private var hitches = 0
    private var missed = 0
    private var operations: [String: MapTimingDistribution] = [:]
    private var sampleCounters: [String: Int] = [:]

    func start(stage: String, metadata: [String: String] = [:], at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1; active = true; self.stage = stage; startTime = now
        self.metadata = metadata
        frames = MapTimingDistribution(); hitches = 0; missed = 0; operations = [:]; sampleCounters = [:]
    }
    func begin(_ name: String, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Token? {
        lock.lock(); defer { lock.unlock() }
        return active ? Token(name: name, start: now, session: generation) : nil
    }
    func end(_ token: Token?, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let token else { return }
        lock.lock(); defer { lock.unlock() }
        guard active, token.session == generation else { return }
        operations[token.name, default: MapTimingDistribution()].add((now - token.start) * 1000)
    }
    func beginSampled(_ name: String, every: Int) -> Token? {
        lock.lock()
        guard active else { lock.unlock(); return nil }
        let next = sampleCounters[name, default: 0] + 1
        sampleCounters[name] = next
        let session = generation
        lock.unlock()
        guard next.isMultiple(of: max(1, every)) else { return nil }
        return Token(name: name, start: ProcessInfo.processInfo.systemUptime, session: session)
    }
    func frame(interval: Double, expected: Double) {
        guard interval.isFinite, expected.isFinite, interval > 0, expected > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        frames.add(interval * 1000)
        if interval > expected * 1.5 {
            hitches += 1
            missed += max(1, Int(min(10_000, (interval / expected).rounded())) - 1)
        }
    }
    func stop(interrupted: Bool = false, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Result? {
        lock.lock(); defer { lock.unlock() }
        guard active else { return nil }
        active = false
        return Result(stage: stage, interrupted: interrupted, durationSeconds: max(0, now - startTime),
            metadata: metadata,
            interactionFrames: frames, hitchIntervals: hitches, estimatedMissedCallbacks: missed, operations: operations)
    }
}

enum MapDiagnosticStage: String, CaseIterable, Identifiable {
    case normal, mapOnly, routes, covered
    var id: String { rawValue }
    var title: String {
        switch self {
        case .normal: "通常表示"
        case .mapOnly: "① 地図のみ"
        case .routes: "② 地図＋経路"
        case .covered: "③ 地図＋経路＋紙／タイル"
        }
    }
}

// These hooks compile to no-ops in ordinary Debug and Release builds.
enum MapPerformanceProbe {
    static func beginSampled(_ name: String) -> MapPerformanceRecorder.Token? {
        #if STREETPRINT_DIAGNOSTICS
        MapPerformanceRecorder.shared.beginSampled(name, every: 16)
        #else
        nil
        #endif
    }
    static func begin(_ name: String) -> MapPerformanceRecorder.Token? {
        #if STREETPRINT_DIAGNOSTICS
        MapPerformanceRecorder.shared.begin(name)
        #else
        nil
        #endif
    }
    static func end(_ token: MapPerformanceRecorder.Token?) {
        #if STREETPRINT_DIAGNOSTICS
        MapPerformanceRecorder.shared.end(token)
        #endif
    }
    static func regionWillChange() {
        #if STREETPRINT_DIAGNOSTICS && canImport(UIKit)
        MapPerformanceSession.shared.regionWillChange()
        #endif
    }
    static func regionDidChange() {
        #if STREETPRINT_DIAGNOSTICS && canImport(UIKit)
        MapPerformanceSession.shared.regionDidChange()
        #endif
    }
}

#if STREETPRINT_DIAGNOSTICS && canImport(UIKit)
import SwiftUI
import UIKit
import QuartzCore
import MapKit

final class MapPerformanceSession: NSObject, ObservableObject {
    static let shared = MapPerformanceSession()
    @Published private(set) var status = "未計測"
    @Published private(set) var busy = false
    @Published private(set) var results: [MapPerformanceRecorder.Result] = []
    private var task: Task<Void, Never>?
    private var link: CADisplayLink?
    private var lastTick: CFTimeInterval?
    private var previousBudget = 0.0
    private var changingRegion = false
    private var tailUntil = 0.0
    private let reportQueue = DispatchQueue(label: "StreetPrint.PerformanceReport", qos: .utility)

    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded),
            name: UIApplication.didEnterBackgroundNotification, object: nil)
    }
    func begin(stage: MapDiagnosticStage, seconds: Int, metadata: [String: String]) {
        cancel()
        busy = true; status = "3秒後に計測開始。その後\(seconds)秒間、同じように地図を動かしてください。"
        task = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
            guard let self, UIApplication.shared.applicationState == .active else { self?.cancel(); return }
            self.changingRegion = false; self.lastTick = nil; self.tailUntil = 0
            MapPerformanceRecorder.shared.start(stage: stage.rawValue, metadata: metadata)
            let expectedEnd = ProcessInfo.processInfo.systemUptime + Double(seconds)
            let link = CADisplayLink(target: self, selector: #selector(self.tick(_:)))
            // Do not override the device's preferred frame rate.
            self.link = link; link.add(to: .main, forMode: .common)
            self.status = "計測中：\(stage.title)"
            do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
            catch { return }
            let lag = MapPerformanceRecorder.shared.begin("main.finishDeadlineLag", at: expectedEnd)
            MapPerformanceRecorder.shared.end(lag)
            self.finish(interrupted: false)
        }
    }
    func regionWillChange() {
        guard link != nil else { return }
        if !changingRegion { lastTick = nil }
        changingRegion = true
    }
    func regionDidChange() {
        guard link != nil else { return }
        changingRegion = false; tailUntil = CACurrentMediaTime() + 0.5
    }
    @objc private func tick(_ sender: CADisplayLink) {
        let now = CACurrentMediaTime()
        guard changingRegion || now < tailUntil else { lastTick = nil; return }
        let budget = max(0.001, sender.targetTimestamp - sender.timestamp)
        if let lastTick {
            MapPerformanceRecorder.shared.frame(interval: now - lastTick, expected: max(previousBudget, budget))
        }
        lastTick = now; previousBudget = budget
    }
    @objc private func backgrounded() { cancel() }
    func cancel() {
        task?.cancel(); task = nil
        finish(interrupted: true)
    }
    private func finish(interrupted: Bool) {
        link?.invalidate(); link = nil; lastTick = nil; changingRegion = false
        if let result = MapPerformanceRecorder.shared.stop(interrupted: interrupted) {
            results.append(result)
            if results.count > 12 { results.removeFirst(results.count - 12) }
            status = interrupted ? "計測中断（バックグラウンド移行など）" : "計測完了。設定で結果を比較できます。"
            persistReport()
        } else if busy { status = "計測を中止しました" }
        busy = false
    }
    var reportText: String {
        var lines = ["Street Print map performance diagnostics",
            "iOS \(UIDevice.current.systemVersion) / \(UIDevice.current.model)",
            "Build \(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") ?? "?")",
            "CADisplayLink callback intervals during camera movement + 0.5s tail; NOT GPU presentation FPS.",
            "Operations are elapsed wall time (not CPU utilization), measured over the entire session.",
            "Route draw scopes sample 1 in 16 calls to limit observer overhead. Nested scopes overlap; do not sum as CPU time.",
            "Hitches: callback interval > 1.5 x expected interval. No coordinates or history included."]
        for result in results {
            let frames = result.interactionFrames
            lines.append("\n[\(result.stage)] duration=\(String(format: "%.1f", result.durationSeconds))s interrupted=\(result.interrupted)")
            lines.append(result.metadata.keys.sorted().map { "\($0)=\(result.metadata[$0]!)" }.joined(separator: " "))
            lines.append("Intervals: n=\(frames.count) average=\(String(format: "%.2f", frames.averageMS))ms p95<=\(Int(frames.p95MS))ms max=\(String(format: "%.2f", frames.maximumMS))ms hitches=\(result.hitchIntervals) missedCallbacksEstimate=\(result.estimatedMissedCallbacks)")
            if frames.count == 0 { lines.append("INSUFFICIENT DATA: no camera-movement frame intervals captured.") }
            for key in result.operations.keys.sorted() {
                let timing = result.operations[key]!
                lines.append("\(key): n=\(timing.count) total=\(String(format: "%.2f", timing.totalMS))ms max=\(String(format: "%.2f", timing.maximumMS))ms p95<=\(Int(timing.p95MS))ms")
            }
        }
        return lines.joined(separator: "\n")
    }
    private func persistReport() {
        let text = reportText
        reportQueue.async {
            do {
                let directory = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: true).appendingPathComponent("MapPerformance", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try text.write(to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
            } catch { /* Diagnostics must never interfere with recording. */ }
        }
    }
}

struct MapPerformanceSettingsView: View {
    let closeSettings: () -> Void
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var session = MapPerformanceSession.shared
    @AppStorage("mapDiagnosticStage") private var stageRaw = MapDiagnosticStage.normal.rawValue
    @State private var seconds = 20
    @State private var sharing = false
    private var stage: MapDiagnosticStage { MapDiagnosticStage(rawValue: stageRaw) ?? .normal }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("描画の計測（検証用ビルドのみ）").font(.headline)
            Text("①→②→③の順に、同じ期間・場所で、同じようにスクロール／拡大縮小してください。移動履歴と記録設定は変えません。")
                .font(.caption)
            Picker("表示するもの", selection: $stageRaw) {
                ForEach(MapDiagnosticStage.allCases) { value in Text(value.title).tag(value.rawValue) }
            }.disabled(session.busy)
            Picker("計測時間", selection: $seconds) {
                Text("10秒").tag(10); Text("20秒").tag(20); Text("30秒").tag(30)
            }.disabled(session.busy)
            Button("この条件で計測（地図へ戻る）") {
                let metadata = ["theme": store.theme.rawValue, "periodPreset": store.period.rawValue,
                    "routeRenderer": "persistentScreenPointV1",
                    "segmentCount": String(store.allWeightedSegments.count),
                    "transportFilters": store.visibleTransportModes.map(\.rawValue).sorted().joined(separator: ","),
                    "lowPowerMode": String(ProcessInfo.processInfo.isLowPowerModeEnabled)]
                session.begin(stage: stage, seconds: seconds, metadata: metadata); closeSettings()
            }.disabled(session.busy)
            Text(session.status).font(.caption)
            if session.busy { Button("計測を中止") { session.cancel() } }
            ForEach(Array(session.results.enumerated()), id: \.offset) { _, result in
                let frames = result.interactionFrames
                VStack(alignment: .leading, spacing: 4) {
                    Text(MapDiagnosticStage(rawValue: result.stage)?.title ?? result.stage).font(.subheadline)
                    Text(result.interrupted ? "中断された計測" : frames.count == 0 ? "操作データ不足：地図を動かして再計測" :
                        "操作中の間隔 p95 \(Int(frames.p95MS))ms / 最大 \(Int(frames.maximumMS))ms / 遅延 \(result.hitchIntervals)回")
                        .font(.caption).monospacedDigit()
                }
            }
            if !session.results.isEmpty {
                Button("計測レポートを共有") { sharing = true }
            }
            Button("通常表示へ戻す") { session.cancel(); stageRaw = MapDiagnosticStage.normal.rawValue }
            Text("GPUの描画完了FPSではなく、画面更新コールバックの間隔を測ります。レポートに位置情報は含みません。")
                .font(.caption2)
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .sheet(isPresented: $sharing) { ShareSheet(items: [session.reportText]) }
    }
}

final class MeasuredRoutePolylineRenderer: MKPolylineRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let timing = MapPerformanceProbe.beginSampled("render.routePolyline.sample1of16")
        defer { MapPerformanceProbe.end(timing) }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}

final class MeasuredRouteMultiPolylineRenderer: MKMultiPolylineRenderer {
    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        let timing = MapPerformanceProbe.beginSampled("render.routeMultiPolyline.sample1of16")
        defer { MapPerformanceProbe.end(timing) }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
    }
}
#endif
