import Foundation

struct FailedItem: Codable, Identifiable {
    let id: UUID
    let assetIdentifier: String
    let filename: String
    let reason: String
    let date: Date

    init(assetIdentifier: String, filename: String, reason: String) {
        self.id = UUID()
        self.assetIdentifier = assetIdentifier
        self.filename = filename
        self.reason = reason
        self.date = Date()
    }
}

struct ManifestEntry: Codable {
    let assetIdentifier: String
    let filename: String
    let byteCount: Int64
    let completedAt: Date
}

struct BackupManifest: Codable {
    var entries: [String: ManifestEntry] = [:]
}
