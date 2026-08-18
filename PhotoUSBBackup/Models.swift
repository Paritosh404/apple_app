import Foundation

struct FailedItem: Codable, Identifiable {
    let id = UUID()
    let assetIdentifier: String
    let filename: String
    let reason: String
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
