import Foundation

enum ExportRepresentation: String, Codable {
    case original
    case adjustmentBase
    case renderedFallback
}

struct FailedItem: Codable, Identifiable {
    let id: UUID
    let assetIdentifier: String
    let filename: String
    let resourceType: Int?
    let reason: String
    let date: Date

    init(
        assetIdentifier: String,
        filename: String,
        resourceType: Int? = nil,
        reason: String
    ) {
        self.id = UUID()
        self.assetIdentifier = assetIdentifier
        self.filename = filename
        self.resourceType = resourceType
        self.reason = reason
        self.date = Date()
    }
}

struct AssetLocation: Codable {
    let latitude: Double
    let longitude: Double
    let altitude: Double?
    let horizontalAccuracy: Double?
    let verticalAccuracy: Double?
}

struct ManifestEntry: Codable {
    let assetIdentifier: String
    let filename: String
    let byteCount: Int64
    let completedAt: Date
    let creationDate: Date?
    let modificationDate: Date?
    let location: AssetLocation?
    let resourceType: Int
    let representation: ExportRepresentation
    let originalFilename: String
}

struct BackupManifest: Codable {
    var entries: [String: ManifestEntry] = [:]
}
