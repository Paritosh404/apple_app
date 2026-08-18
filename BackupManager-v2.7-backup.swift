import Foundation
import Photos
import BackgroundTasks
import CoreLocation
import ImageIO
import UniformTypeIdentifiers
import CryptoKit

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    static let taskIdentifier = "com.paritosh.PhotoUSBBackup.userExport"

    @Published var status = "Choose Photos access and a USB folder."
    @Published var completedItems = 0
    @Published var totalItems = 0
    @Published var copiedFiles = 0
    @Published var originalFiles = 0
    @Published var fallbackFiles = 0
    @Published var disputedFiles = 0
    @Published var mergedFiles = 0
    @Published var skippedFiles = 0
    @Published var adoptedFiles = 0
    @Published var conflictFiles = 0
    @Published var failedItems: [FailedItem] = []
    @Published var destinationURL: URL?
    @Published var photoAccessGranted = false
    @Published var isRunning = false

    private var shouldCancel = false
    private var taskRegistered = false
    private var activeRunID: UUID?
    private var duplicateReport: [DuplicateReportItem] = []

    // v2.8: one startup scan instead of recursive scanning per asset.
    private var filenameIndex: [String: [URL]] = [:]

    private init() {
        refreshPermission()
        registerContinuedProcessingTask()
    }

    func refreshPermission() {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited
    }

    func requestPhotoPermission() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited

        switch authorization {
        case .authorized:
            status = "Full Photos access granted."
        case .limited:
            status = "Limited Photos access granted. Only selected photos will be backed up."
        case .denied, .restricted:
            status = "Photos access was not granted."
        case .notDetermined:
            status = "Photos permission is still undetermined."
        @unknown default:
            status = "Unknown Photos permission state."
        }
    }

    func setDestination(_ url: URL) {
        destinationURL = url
        status = "Destination selected: \(url.lastPathComponent)"
    }

    private func registerContinuedProcessingTask() {
        guard !taskRegistered else { return }

        taskRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.taskIdentifier,
            using: nil
        ) { [weak self] task in
            guard let continuedTask = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }

            Task { @MainActor [weak self] in
                guard let self else {
                    continuedTask.setTaskCompleted(success: false)
                    return
                }

                continuedTask.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        self?.shouldCancel = true
                    }
                }

                if self.isRunning {
                    self.status = "Backup running — background continuation attached."
                    return
                }

                continuedTask.setTaskCompleted(success: true)
            }
        }
    }

    func startBackup() {
        guard photoAccessGranted else {
            status = "Allow Photos access first."
            return
        }

        guard destinationURL != nil else {
            status = "Choose a USB folder first."
            return
        }

        guard !isRunning else { return }

        isRunning = true
        shouldCancel = false
        completedItems = 0
        copiedFiles = 0
        originalFiles = 0
        fallbackFiles = 0
        disputedFiles = 0
        mergedFiles = 0
        skippedFiles = 0
        adoptedFiles = 0
        conflictFiles = 0
        failedItems = []
        duplicateReport = []
        filenameIndex = [:]

        let runID = UUID()
        activeRunID = runID
        status = "Reading Photos library…"

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Copying Original Photos",
            subtitle: "Preparing your library"
        )
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)

        Task {
            await performBackup(runID: runID)
        }
    }

    private func performBackup(runID: UUID) async {
        guard activeRunID == runID else { return }
        guard let destinationURL else {
            isRunning = false
            activeRunID = nil
            return
        }

        let hasSecurityAccess = destinationURL.startAccessingSecurityScopedResource()

        defer {
            if hasSecurityAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
            if activeRunID == runID {
                activeRunID = nil
                isRunning = false
            }
        }

        do {
            try createFolderStructure(in: destinationURL)
        } catch {
            status = "Could not create backup folders: \(error.localizedDescription)"
            return
        }

        status = "Indexing existing backup filenames…"
        filenameIndex = buildFilenameIndex(root: destinationURL)

        var manifest = loadManifest(from: destinationURL)

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]

        let assets = PHAsset.fetchAssets(with: fetchOptions)
        totalItems = assets.count
        status = "Found \(totalItems) Photos assets."

        for index in 0..<assets.count {
            if shouldCancel {
                saveManifest(manifest, to: destinationURL)
                saveFailures(to: destinationURL)
                saveDuplicateReport(to: destinationURL)
                status = "Stopped at \(completedItems) / \(totalItems). Run again to resume."
                return
            }

            let asset = assets.object(at: index)
            status = "Asset \(index + 1) / \(totalItems)"

            do {
                let result = try await exportAsset(
                    asset,
                    root: destinationURL,
                    manifest: &manifest
                )

                copiedFiles += result.copied
                originalFiles += result.original
                fallbackFiles += result.fallback
                disputedFiles += result.disputed
                mergedFiles += result.merged
                skippedFiles += result.skipped
                adoptedFiles += result.adopted
                conflictFiles += result.conflicts
            } catch {
                failedItems.append(
                    FailedItem(
                        assetIdentifier: asset.localIdentifier,
                        filename: "Asset \(index + 1)",
                        reason: error.localizedDescription
                    )
                )
            }

            completedItems += 1

            // Still frequent, but no heavy hashing in the ordinary path.
            if completedItems % 5 == 0 {
                saveManifest(manifest, to: destinationURL)
                saveFailures(to: destinationURL)
                saveDuplicateReport(to: destinationURL)
            }
        }

        saveManifest(manifest, to: destinationURL)
        saveFailures(to: destinationURL)
        saveDuplicateReport(to: destinationURL)

        status = failedItems.isEmpty
            ? "Complete — \(skippedFiles) skipped, \(adoptedFiles) adopted, \(conflictFiles) true conflicts."
            : "Finished — \(failedItems.count) failed, \(adoptedFiles) adopted."
    }

    private func createFolderStructure(in root: URL) throws {
        let fm = FileManager.default

        let folders = [
            root.appendingPathComponent("Originals", isDirectory: true),
            root.appendingPathComponent("Metadata-Disputed/Original", isDirectory: true),
            root.appendingPathComponent("Metadata-Disputed/GPS-Merged", isDirectory: true),
            root.appendingPathComponent(".PhotoUSBBackup-Staging", isDirectory: true)
        ]

        for folder in folders {
            try fm.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )
        }
    }

    private func exportAsset(
        _ asset: PHAsset,
        root: URL,
        manifest: inout BackupManifest
    ) async throws -> (
        copied: Int,
        original: Int,
        fallback: Int,
        disputed: Int,
        merged: Int,
        skipped: Int,
        adopted: Int,
        conflicts: Int
    ) {
        let groups = resourceCandidateGroups(for: asset)

        var copied = 0
        var originalCount = 0
        var fallbackCount = 0
        var disputedCount = 0
        var mergedCount = 0
        var skipped = 0
        var adopted = 0
        var conflicts = 0

        for group in groups {
            if shouldCancel { break }

            var exported = false
            var lastError: Error?

            for candidate in group {
                let resource = candidate.resource

                // FAST PATH #1:
                // Manifest + file exists + recorded size => skip immediately.
                // No Photos fetch, no staging, no hashing.
                if let existing = findVerifiedManifestEntryFast(
                    asset: asset,
                    resource: resource,
                    manifest: manifest,
                    root: root
                ) {
                    skipped += 1
                    if existing.metadataDisposition == .disputed {
                        disputedCount += 1
                        if existing.mergedFilename != nil {
                            mergedCount += 1
                        }
                    }
                    exported = true
                    break
                }

                do {
                    // Only now do we fetch/stage the Photos resource.
                    let stagedURL = try await stageResourceWithRetries(
                        resource,
                        root: root
                    )

                    let stagedSize = fileSize(of: stagedURL)
                    guard stagedSize > 0 else {
                        throw BackupError.emptyOutput(resource.originalFilename)
                    }

                    let photosLocation = archiveLocation(asset.location)
                    let embeddedLocation = embeddedGPS(from: stagedURL)
                    let isDisputed = gpsIsDisputed(
                        photos: photosLocation,
                        embedded: embeddedLocation
                    )

                    let destinationFolder: URL
                    let disposition: MetadataDisposition

                    if isDisputed {
                        destinationFolder = root
                            .appendingPathComponent("Metadata-Disputed/Original", isDirectory: true)
                        disposition = canMergeMetadata(for: stagedURL)
                            ? .disputed
                            : .mergeUnsupported
                    } else {
                        destinationFolder = root
                            .appendingPathComponent("Originals", isDirectory: true)
                        disposition = .normal
                    }

                    let filename = safeFilename(resource.originalFilename)
                    let desiredURL = destinationFolder.appendingPathComponent(filename)

                    // FAST PATH #2 / COLLISION-ONLY CHECK:
                    // If no same-name candidate exists, copy immediately.
                    // Hashing occurs ONLY if a same-name file already exists.
                    let sameNameCandidates = filenameIndex[filename] ?? []

                    if !sameNameCandidates.isEmpty {
                        if let identical = try findIdenticalCollision(
                            stagedURL: stagedURL,
                            candidates: sameNameCandidates
                        ) {
                            let key = manifestKey(
                                asset: asset,
                                resource: resource,
                                filename: identical.url.lastPathComponent
                            )

                            manifest.entries[key] = ManifestEntry(
                                assetIdentifier: asset.localIdentifier,
                                filename: relativePath(identical.url, from: root),
                                byteCount: identical.size,
                                completedAt: Date(),
                                creationDate: asset.creationDate,
                                modificationDate: asset.modificationDate,
                                photosLocation: photosLocation,
                                embeddedLocation: embeddedGPS(from: identical.url),
                                resourceType: resource.type.rawValue,
                                representation: candidate.representation,
                                originalFilename: resource.originalFilename,
                                metadataDisposition: disposition,
                                mergedFilename: nil,
                                sha256: identical.sha256
                            )

                            duplicateReport.append(
                                DuplicateReportItem(
                                    sourceFilename: resource.originalFilename,
                                    existingPath: relativePath(identical.url, from: root),
                                    action: "adopted-existing-identical",
                                    sourceSize: stagedSize,
                                    existingSize: identical.size,
                                    sourceSHA256: identical.sha256,
                                    existingSHA256: identical.sha256
                                )
                            )

                            try? FileManager.default.removeItem(at: stagedURL)
                            skipped += 1
                            adopted += 1
                            exported = true
                            break
                        }
                    }

                    // No identical same-name file. Only now do we allow a suffix.
                    let finalURL: URL
                    if FileManager.default.fileExists(atPath: desiredURL.path) {
                        finalURL = conflictSafeURL(for: desiredURL)
                        conflicts += 1
                    } else {
                        finalURL = desiredURL
                    }

                    try FileManager.default.moveItem(at: stagedURL, to: finalURL)
                    let bytes = fileSize(of: finalURL)
                    guard bytes > 0 else {
                        throw BackupError.emptyOutput(finalURL.lastPathComponent)
                    }

                    // v2.8: NO routine SHA-256 here.
                    // Add the new file to the in-memory filename index immediately.
                    addToFilenameIndex(finalURL)

                    var mergedFilename: String?

                    if isDisputed {
                        disputedCount += 1

                        let mergedFolder = root
                            .appendingPathComponent("Metadata-Disputed/GPS-Merged", isDirectory: true)

                        if canMergeMetadata(for: finalURL) {
                            let mergedURL = mergedFolder.appendingPathComponent(finalURL.lastPathComponent)
                            let safeMergedURL = FileManager.default.fileExists(atPath: mergedURL.path)
                                ? conflictSafeURL(for: mergedURL)
                                : mergedURL

                            try createGPSMergedCopy(
                                sourceURL: finalURL,
                                destinationURL: safeMergedURL,
                                photosLocation: photosLocation,
                                creationDate: asset.creationDate,
                                modificationDate: asset.modificationDate
                            )

                            mergedFilename = relativePath(safeMergedURL, from: root)
                            mergedCount += 1
                            addToFilenameIndex(safeMergedURL)
                        } else {
                            let xmpURL = mergedFolder
                                .appendingPathComponent(finalURL.lastPathComponent + ".xmp")

                            try writeXMPSidecar(
                                for: asset,
                                exportedFilename: finalURL.lastPathComponent,
                                representation: candidate.representation,
                                resourceType: resource.type.rawValue,
                                to: xmpURL
                            )

                            mergedFilename = relativePath(xmpURL, from: root)
                            addToFilenameIndex(xmpURL)
                        }
                    }

                    let key = manifestKey(
                        asset: asset,
                        resource: resource,
                        filename: finalURL.lastPathComponent
                    )

                    manifest.entries[key] = ManifestEntry(
                        assetIdentifier: asset.localIdentifier,
                        filename: relativePath(finalURL, from: root),
                        byteCount: bytes,
                        completedAt: Date(),
                        creationDate: asset.creationDate,
                        modificationDate: asset.modificationDate,
                        photosLocation: photosLocation,
                        embeddedLocation: embeddedLocation,
                        resourceType: resource.type.rawValue,
                        representation: candidate.representation,
                        originalFilename: resource.originalFilename,
                        metadataDisposition: disposition,
                        mergedFilename: mergedFilename,
                        sha256: nil
                    )

                    copied += 1
                    if candidate.representation == .original {
                        originalCount += 1
                    } else {
                        fallbackCount += 1
                    }

                    exported = true
                    break
                } catch {
                    lastError = error
                }
            }

            if !exported {
                throw lastError ?? BackupError.noUsableResource
            }
        }

        return (
            copied,
            originalCount,
            fallbackCount,
            disputedCount,
            mergedCount,
            skipped,
            adopted,
            conflicts
        )
    }

    private struct ResourceCandidate {
        let resource: PHAssetResource
        let representation: ExportRepresentation
    }

    private func resourceCandidateGroups(for asset: PHAsset) -> [[ResourceCandidate]] {
        let resources = PHAssetResource.assetResources(for: asset)
        var groups: [[ResourceCandidate]] = []

        switch asset.mediaType {
        case .image:
            var stillCandidates: [ResourceCandidate] = []

            if let r = resources.first(where: { $0.type == .photo }) {
                stillCandidates.append(.init(resource: r, representation: .original))
            }
            if let r = resources.first(where: { $0.type == .adjustmentBasePhoto }) {
                stillCandidates.append(.init(resource: r, representation: .adjustmentBase))
            }
            if let r = resources.first(where: { $0.type == .fullSizePhoto }) {
                stillCandidates.append(.init(resource: r, representation: .renderedFallback))
            }

            if !stillCandidates.isEmpty {
                groups.append(stillCandidates)
            }

            for alt in resources.filter({ $0.type == .alternatePhoto }) {
                groups.append([
                    .init(resource: alt, representation: .original)
                ])
            }

            var liveCandidates: [ResourceCandidate] = []

            if let r = resources.first(where: { $0.type == .pairedVideo }) {
                liveCandidates.append(.init(resource: r, representation: .original))
            }
            if let r = resources.first(where: { $0.type == .fullSizePairedVideo }) {
                liveCandidates.append(.init(resource: r, representation: .renderedFallback))
            }

            if !liveCandidates.isEmpty {
                groups.append(liveCandidates)
            }

        case .video:
            var videoCandidates: [ResourceCandidate] = []

            if let r = resources.first(where: { $0.type == .video }) {
                videoCandidates.append(.init(resource: r, representation: .original))
            }
            if let r = resources.first(where: { $0.type == .adjustmentBaseVideo }) {
                videoCandidates.append(.init(resource: r, representation: .adjustmentBase))
            }
            if let r = resources.first(where: { $0.type == .fullSizeVideo }) {
                videoCandidates.append(.init(resource: r, representation: .renderedFallback))
            }

            if !videoCandidates.isEmpty {
                groups.append(videoCandidates)
            }

        default:
            break
        }

        return groups
    }

    private func stageResourceWithRetries(
        _ resource: PHAssetResource,
        root: URL
    ) async throws -> URL {
        let stagingFolder = root
            .appendingPathComponent(".PhotoUSBBackup-Staging", isDirectory: true)

        let tempName = UUID().uuidString + "-" + safeFilename(resource.originalFilename)
        let stagedURL = stagingFolder.appendingPathComponent(tempName + ".partial")

        var lastError: Error?

        for attempt in 1...3 {
            if shouldCancel { throw BackupError.cancelled }
            try? FileManager.default.removeItem(at: stagedURL)

            do {
                try await writeResourceDirect(resource, to: stagedURL)
                guard fileSize(of: stagedURL) > 0 else {
                    throw BackupError.emptyOutput(resource.originalFilename)
                }
                return stagedURL
            } catch {
                lastError = error

                if attempt < 3 {
                    let delay = UInt64(attempt) * 800_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        try? FileManager.default.removeItem(at: stagedURL)

        do {
            try await streamResource(resource, to: stagedURL)
            guard fileSize(of: stagedURL) > 0 else {
                throw BackupError.emptyOutput(resource.originalFilename)
            }
            return stagedURL
        } catch {
            try? FileManager.default.removeItem(at: stagedURL)

            throw BackupError.resourceReadFailed(
                resource.originalFilename,
                underlying: "\(lastError?.localizedDescription ?? "direct write failed"); stream fallback: \(error.localizedDescription)"
            )
        }
    }

    private func writeResourceDirect(
        _ resource: PHAssetResource,
        to url: URL
    ) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            PHAssetResourceManager.default().writeData(
                for: resource,
                toFile: url,
                options: options
            ) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func streamResource(
        _ resource: PHAssetResource,
        to url: URL
    ) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in

            var writeError: Error?

            PHAssetResourceManager.default().requestData(
                for: resource,
                options: options
            ) { data in
                guard writeError == nil else { return }

                do {
                    try handle.write(contentsOf: data)
                } catch {
                    writeError = error
                }
            } completionHandler: { error in
                do {
                    try handle.close()
                } catch {
                    if writeError == nil {
                        writeError = error
                    }
                }

                if let writeError {
                    continuation.resume(throwing: writeError)
                } else if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - v2.8 fast index + collision-only hashing

    private func buildFilenameIndex(root: URL) -> [String: [URL]] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var index: [String: [URL]] = [:]

        for case let url as URL in enumerator {
            if url.path.contains("/.PhotoUSBBackup-Staging/") {
                continue
            }

            let values = try? url.resourceValues(forKeys: [.isRegularFileKey])

            guard values?.isRegularFile == true else {
                continue
            }

            index[url.lastPathComponent, default: []].append(url)
        }

        return index
    }

    private func addToFilenameIndex(_ url: URL) {
        filenameIndex[url.lastPathComponent, default: []].append(url)
    }

    private struct CollisionMatch {
        let url: URL
        let size: Int64
        let sha256: String
    }

    private func findIdenticalCollision(
        stagedURL: URL,
        candidates: [URL]
    ) throws -> CollisionMatch? {
        let sourceSize = fileSize(of: stagedURL)
        guard sourceSize > 0 else { return nil }

        let sameSize = candidates.filter {
            FileManager.default.fileExists(atPath: $0.path) &&
            fileSize(of: $0) == sourceSize
        }

        guard !sameSize.isEmpty else {
            return nil
        }

        // Expensive hashing begins only here.
        let sourceHash = try sha256(of: stagedURL)

        for candidate in sameSize {
            let candidateHash = try sha256(of: candidate)

            if candidateHash == sourceHash {
                return CollisionMatch(
                    url: candidate,
                    size: sourceSize,
                    sha256: sourceHash
                )
            }
        }

        return nil
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()

        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }

        return hasher.finalize()
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private func findVerifiedManifestEntryFast(
        asset: PHAsset,
        resource: PHAssetResource,
        manifest: BackupManifest,
        root: URL
    ) -> ManifestEntry? {
        // No SHA-256 here by design.
        return manifest.entries.values.first { entry in
            guard
                entry.assetIdentifier == asset.localIdentifier,
                entry.resourceType == resource.type.rawValue
            else {
                return false
            }

            let fileURL = root.appendingPathComponent(entry.filename)

            return FileManager.default.fileExists(atPath: fileURL.path) &&
                   fileSize(of: fileURL) == entry.byteCount &&
                   entry.byteCount > 0
        }
    }

    // MARK: - GPS reconciliation

    private func embeddedGPS(from url: URL) -> AssetLocation? {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any]
        else {
            return nil
        }

        guard
            let latValue = number(gps[kCGImagePropertyGPSLatitude]),
            let lonValue = number(gps[kCGImagePropertyGPSLongitude])
        else {
            return nil
        }

        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"

        let latitude = latRef.uppercased() == "S" ? -abs(latValue) : abs(latValue)
        let longitude = lonRef.uppercased() == "W" ? -abs(lonValue) : abs(lonValue)

        let altitudeValue = number(gps[kCGImagePropertyGPSAltitude])
        let altitudeRef = number(gps[kCGImagePropertyGPSAltitudeRef]) ?? 0

        let altitude: Double?
        if let altitudeValue {
            altitude = altitudeRef == 1 ? -abs(altitudeValue) : altitudeValue
        } else {
            altitude = nil
        }

        return AssetLocation(
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            horizontalAccuracy: nil,
            verticalAccuracy: nil
        )
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func gpsIsDisputed(
        photos: AssetLocation?,
        embedded: AssetLocation?
    ) -> Bool {
        guard let photos else { return false }
        guard let embedded else { return true }

        let p = CLLocation(latitude: photos.latitude, longitude: photos.longitude)
        let e = CLLocation(latitude: embedded.latitude, longitude: embedded.longitude)

        return p.distance(from: e) > 25.0
    }

    private func canMergeMetadata(for url: URL) -> Bool {
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source) as String?
        else {
            return false
        }

        return type == UTType.jpeg.identifier ||
               type == UTType.heic.identifier ||
               type == UTType.heif.identifier
    }

    private func createGPSMergedCopy(
        sourceURL: URL,
        destinationURL: URL,
        photosLocation: AssetLocation?,
        creationDate: Date?,
        modificationDate: Date?
    ) throws {
        guard
            let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            let type = CGImageSourceGetType(source),
            let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                type,
                1,
                nil
            )
        else {
            throw BackupError.metadataMergeFailed(destinationURL.lastPathComponent)
        }

        var metadata =
            (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        var gps =
            (metadata[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]

        if let photosLocation {
            let latitude = photosLocation.latitude
            let longitude = photosLocation.longitude

            gps[kCGImagePropertyGPSLatitude] = abs(latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = longitude < 0 ? "W" : "E"

            if let altitude = photosLocation.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(altitude)
                gps[kCGImagePropertyGPSAltitudeRef] = altitude < 0 ? 1 : 0
            }
        }

        metadata[kCGImagePropertyGPSDictionary] = gps

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"

        var exif =
            (metadata[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]

        if let creationDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = formatter.string(from: creationDate)
            exif[kCGImagePropertyExifDateTimeDigitized] = formatter.string(from: creationDate)
        }

        metadata[kCGImagePropertyExifDictionary] = exif

        if let modificationDate {
            var tiff =
                (metadata[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]

            tiff[kCGImagePropertyTIFFDateTime] = formatter.string(from: modificationDate)
            metadata[kCGImagePropertyTIFFDictionary] = tiff
        }

        CGImageDestinationAddImageFromSource(
            destination,
            source,
            0,
            metadata as CFDictionary
        )

        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw BackupError.metadataMergeFailed(destinationURL.lastPathComponent)
        }
    }

    private func archiveLocation(_ location: CLLocation?) -> AssetLocation? {
        guard let location else { return nil }

        return AssetLocation(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            horizontalAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
            verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil
        )
    }

    private func writeXMPSidecar(
        for asset: PHAsset,
        exportedFilename: String,
        representation: ExportRepresentation,
        resourceType: Int,
        to sidecarURL: URL
    ) throws {
        let location = asset.location

        let latitude =
            location.map { String(format: "%.8f", $0.coordinate.latitude) } ?? ""

        let longitude =
            location.map { String(format: "%.8f", $0.coordinate.longitude) } ?? ""

        let altitude =
            location.flatMap {
                $0.verticalAccuracy >= 0
                    ? String(format: "%.3f", $0.altitude)
                    : nil
            } ?? ""

        let dateFormatter = ISO8601DateFormatter()
        let created =
            asset.creationDate.map { dateFormatter.string(from: $0) } ?? ""

        let modified =
            asset.modificationDate.map { dateFormatter.string(from: $0) } ?? ""

        let xmp = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:exif="http://ns.adobe.com/exif/1.0/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/"
              xmlns:photos="https://example.invalid/photousbbackup/1.0/"
              exif:GPSLatitude="\(latitude)"
              exif:GPSLongitude="\(longitude)"
              exif:GPSAltitude="\(altitude)"
              xmp:CreateDate="\(created)"
              xmp:ModifyDate="\(modified)"
              photos:AssetLocalIdentifier="\(xmlEscape(asset.localIdentifier))"
              photos:ExportedFilename="\(xmlEscape(exportedFilename))"
              photos:Representation="\(representation.rawValue)"
              photos:ResourceType="\(resourceType)" />
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        try Data(xmp.utf8).write(to: sidecarURL, options: .atomic)
    }

    // MARK: - Manifest/report helpers

    private func manifestKey(
        asset: PHAsset,
        resource: PHAssetResource,
        filename: String
    ) -> String {
        "\(asset.localIdentifier)|\(resource.type.rawValue)|\(filename)"
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path

        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }

        return url.lastPathComponent
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func safeFilename(_ filename: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        return filename.components(separatedBy: invalid).joined(separator: "_")
    }

    private func conflictSafeURL(for original: URL) -> URL {
        let folder = original.deletingLastPathComponent()
        let ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent

        var counter = 1

        while true {
            let name = ext.isEmpty
                ? "\(stem)_\(counter)"
                : "\(stem)_\(counter).\(ext)"

            let candidate = folder.appendingPathComponent(name)

            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }

            counter += 1
        }
    }

    private func fileSize(of url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch {
            return 0
        }
    }

    private var manifestFilename: String { ".PhotoUSBBackup-manifest.json" }
    private var failuresFilename: String { "PhotoUSBBackup-failures.json" }
    private var duplicateReportFilename: String { "PhotoUSBBackup-duplicate-report.json" }

    private func manifestURL(in folder: URL) -> URL {
        folder.appendingPathComponent(manifestFilename)
    }

    private func loadManifest(from folder: URL) -> BackupManifest {
        let url = manifestURL(in: folder)

        guard let data = try? Data(contentsOf: url) else {
            return BackupManifest()
        }

        if let current = try? JSONDecoder().decode(BackupManifest.self, from: data) {
            return current
        }

        return BackupManifest()
    }

    private func saveManifest(_ manifest: BackupManifest, to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(manifest) else { return }

        try? data.write(
            to: manifestURL(in: folder),
            options: .atomic
        )
    }

    private func saveFailures(to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(failedItems) else { return }

        try? data.write(
            to: folder.appendingPathComponent(failuresFilename),
            options: .atomic
        )
    }

    private func saveDuplicateReport(to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(duplicateReport) else { return }

        try? data.write(
            to: folder.appendingPathComponent(duplicateReportFilename),
            options: .atomic
        )
    }

    func cancelBackup() {
        shouldCancel = true
        status = "Stopping after the current file…"
    }
}

enum BackupError: LocalizedError {
    case cancelled
    case noUsableResource
    case emptyOutput(String)
    case resourceReadFailed(String, underlying: String)
    case metadataMergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Backup was cancelled."
        case .noUsableResource:
            return "No usable Photos resource was found for this asset."
        case .emptyOutput(let filename):
            return "PhotoKit produced an empty file for \(filename)."
        case .resourceReadFailed(let filename, let underlying):
            return "Could not read \(filename): \(underlying)"
        case .metadataMergeFailed(let filename):
            return "Could not create GPS-merged copy for \(filename)."
        }
    }
}
