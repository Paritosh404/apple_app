import Foundation

enum ExportRepresentation: String, Codable {
    case original
    case adjustmentBase
    case renderedFallback
}

enum MetadataDisposition: String, Codable {
    case normal
    case disputed
    case mergeUnsupported
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
    let completedAt: Date?
    let creationDate: Date?
    let modificationDate: Date?
    let photosLocation: AssetLocation?
    let embeddedLocation: AssetLocation?
    let resourceType: Int
    let representation: ExportRepresentation?
    let originalFilename: String?
    let metadataDisposition: MetadataDisposition?
    let mergedFilename: String?
    let sha256: String?

    init(
        assetIdentifier: String,
        filename: String,
        byteCount: Int64,
        completedAt: Date? = Date(),
        creationDate: Date? = nil,
        modificationDate: Date? = nil,
        photosLocation: AssetLocation? = nil,
        embeddedLocation: AssetLocation? = nil,
        resourceType: Int,
        representation: ExportRepresentation? = nil,
        originalFilename: String? = nil,
        metadataDisposition: MetadataDisposition? = nil,
        mergedFilename: String? = nil,
        sha256: String? = nil
    ) {
        self.assetIdentifier = assetIdentifier
        self.filename = filename
        self.byteCount = byteCount
        self.completedAt = completedAt
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.photosLocation = photosLocation
        self.embeddedLocation = embeddedLocation
        self.resourceType = resourceType
        self.representation = representation
        self.originalFilename = originalFilename
        self.metadataDisposition = metadataDisposition
        self.mergedFilename = mergedFilename
        self.sha256 = sha256
    }
}

struct BackupManifest: Codable {
    var entries: [String: ManifestEntry] = [:]
}

struct DuplicateReportItem: Codable, Identifiable {
    let id: UUID
    let sourceFilename: String
    let existingPath: String
    let action: String
    let sourceSize: Int64
    let existingSize: Int64
    let sourceSHA256: String?
    let existingSHA256: String?
    let date: Date

    init(
        sourceFilename: String,
        existingPath: String,
        action: String,
        sourceSize: Int64,
        existingSize: Int64,
        sourceSHA256: String?,
        existingSHA256: String?
    ) {
        self.id = UUID()
        self.sourceFilename = sourceFilename
        self.existingPath = existingPath
        self.action = action
        self.sourceSize = sourceSize
        self.existingSize = existingSize
        self.sourceSHA256 = sourceSHA256
        self.existingSHA256 = existingSHA256
        self.date = Date()
    }
}
