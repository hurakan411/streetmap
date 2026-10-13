import Foundation

final class LocalHistoryStore {
    private struct Archive: Codable {
        var tracks: [WalkTrack]
    }

    private let fileURL: URL
    private let draftURL: URL
    private let recoveryAnchorURL: URL

    init(fileManager: FileManager = .default) {
        let root = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fileManager.temporaryDirectory
        let directory = root.appendingPathComponent("Michi", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent("walk-history.json")
        draftURL = directory.appendingPathComponent("active-route.json")
        recoveryAnchorURL = directory.appendingPathComponent("recovery-anchor.json")
    }

    func load() -> [WalkTrack] {
        guard let data = try? Data(contentsOf: fileURL),
              let archive = try? JSONDecoder.michi.decode(Archive.self, from: data) else {
            return []
        }
        return archive.tracks
    }

    func save(_ tracks: [WalkTrack]) {
        guard let data = try? JSONEncoder.michi.encode(Archive(tracks: tracks)) else { return }
        // バックグラウンド測位中（端末ロック中）も保存できるよう、
        // ファイルを「開いている間だけ」保護する指定は使わない。
        try? data.write(to: fileURL, options: [.atomic])
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: draftURL)
        try? FileManager.default.removeItem(at: recoveryAnchorURL)
    }

    func loadDraft() -> [GeoPoint] {
        guard let data = try? Data(contentsOf: draftURL),
              let points = try? JSONDecoder.michi.decode([GeoPoint].self, from: data) else {
            return []
        }
        return points
    }

    func saveDraft(_ points: [GeoPoint]) {
        guard let data = try? JSONEncoder.michi.encode(points) else { return }
        try? data.write(to: draftURL, options: [.atomic])
    }

    func clearDraft() {
        try? FileManager.default.removeItem(at: draftURL)
    }

    func loadRecoveryAnchor() -> GeoPoint? {
        guard let data = try? Data(contentsOf: recoveryAnchorURL) else { return nil }
        return try? JSONDecoder.michi.decode(GeoPoint.self, from: data)
    }

    func saveRecoveryAnchor(_ point: GeoPoint) {
        guard let data = try? JSONEncoder.michi.encode(point) else { return }
        try? data.write(to: recoveryAnchorURL, options: [.atomic])
    }

    func clearRecoveryAnchor() {
        try? FileManager.default.removeItem(at: recoveryAnchorURL)
    }
}

private extension JSONEncoder {
    static var michi: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var michi: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
