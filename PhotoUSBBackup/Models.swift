import Foundation

enum ExportRepresentation: String, Codable { case original, adjustmentBase, renderedFallback }
enum MetadataDisposition: String, Codable { case normal, disputed, mergeUnsupported }

struct FailedItem: Codable, Identifiable {
    let id: UUID
    let assetIdentifier: String
    let filename: String
    let resourceType: Int?
    let reason: String
    let date: Date
    init(assetIdentifier: String, filename: String, resourceType: Int? = nil, reason: String) {
        id = UUID(); self.assetIdentifier = assetIdentifier; self.filename = filename
        self.resourceType = resourceType; self.reason = reason; date = Date()
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
    let photosLocation: AssetLocation?
    let embeddedLocation: AssetLocation?
    let resourceType: Int
    let representation: ExportRepresentation
    let originalFilename: String
    let metadataDisposition: MetadataDisposition?
    let mergedFilename: String?
}

struct BackupManifest: Codable { var entries: [String: ManifestEntry] = [:] }


struct DuplicateReportItem: Codable, Identifiable {
    let id: UUID
    let sourceFilename: String
    let existingPath: String
    let action: String
    let sourceSize: Int64
    let existingSize: Int64
    let sha256: String
    let date: Date

    init(sourceFilename: String, existingPath: String, action: String, sourceSize: Int64, existingSize: Int64, sha256: String) {
        self.id = UUID()
        self.sourceFilename = sourceFilename
        self.existingPath = existingPath
        self.action = action
        self.sourceSize = sourceSize
        self.existingSize = existingSize
        self.sha256 = sha256
        self.date = Date()
    }
}
