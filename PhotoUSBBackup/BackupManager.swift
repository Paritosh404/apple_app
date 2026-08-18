import Foundation
import Photos
import BackgroundTasks
import CoreLocation

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
    @Published var skippedFiles = 0
    @Published var failedItems: [FailedItem] = []
    @Published var destinationURL: URL?
    @Published var photoAccessGranted = false
    @Published var isRunning = false

    private var shouldCancel = false
    private var taskRegistered = false
    private var activeRunID: UUID?

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
        skippedFiles = 0
        failedItems = []

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
                status = "Stopped at \(completedItems) / \(totalItems). Run again to resume."
                return
            }

            let asset = assets.object(at: index)
            status = "Asset \(index + 1) / \(totalItems)"

            do {
                let result = try await exportAsset(
                    asset,
                    to: destinationURL,
                    manifest: &manifest
                )
                copiedFiles += result.copied
                originalFiles += result.original
                fallbackFiles += result.fallback
                skippedFiles += result.skipped
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

            // Save frequently so a lock/crash loses minimal progress.
            if completedItems % 20 == 0 {
                saveManifest(manifest, to: destinationURL)
                saveFailures(to: destinationURL)
            }
        }

        saveManifest(manifest, to: destinationURL)
        saveFailures(to: destinationURL)

        status = failedItems.isEmpty
            ? "Complete — \(originalFiles) original, \(fallbackFiles) fallback."
            : "Finished — \(originalFiles) original, \(fallbackFiles) fallback, \(failedItems.count) failed."
    }

    private func exportAsset(
        _ asset: PHAsset,
        to folder: URL,
        manifest: inout BackupManifest
    ) async throws -> (copied: Int, original: Int, fallback: Int, skipped: Int) {
        let groups = resourceCandidateGroups(for: asset)

        var copied = 0
        var originalCount = 0
        var fallbackCount = 0
        var skipped = 0

        for group in groups {
            if shouldCancel { break }

            var exported = false
            var lastError: Error?

            for candidate in group {
                let resource = candidate.resource
                let originalName = safeFilename(resource.originalFilename)
                let expectedFinalURL = folder.appendingPathComponent(originalName)

                let existingKey = manifestKey(
                    asset: asset,
                    resource: resource,
                    filename: originalName
                )

                if let entry = manifest.entries[existingKey],
                   FileManager.default.fileExists(atPath: expectedFinalURL.path),
                   fileSize(of: expectedFinalURL) == entry.byteCount,
                   entry.byteCount > 0 {
                    skipped += 1
                    exported = true
                    break
                }

                do {
                    let result = try await exportResourceWithRetries(
                        resource,
                        asset: asset,
                        preferredFinalURL: expectedFinalURL,
                        folder: folder
                    )

                    let finalURL = result.finalURL
                    let bytes = result.bytes
                    let key = manifestKey(
                        asset: asset,
                        resource: resource,
                        filename: finalURL.lastPathComponent
                    )

                    manifest.entries[key] = ManifestEntry(
                        assetIdentifier: asset.localIdentifier,
                        filename: finalURL.lastPathComponent,
                        byteCount: bytes,
                        completedAt: Date(),
                        creationDate: asset.creationDate,
                        modificationDate: asset.modificationDate,
                        location: archiveLocation(asset.location),
                        resourceType: resource.type.rawValue,
                        representation: candidate.representation,
                        originalFilename: resource.originalFilename
                    )

                    try? writeXMPSidecar(
                        for: asset,
                        exportedFilename: finalURL.lastPathComponent,
                        representation: candidate.representation,
                        resourceType: resource.type.rawValue,
                        to: folder
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

        return (copied, originalCount, fallbackCount, skipped)
    }

    private struct ResourceCandidate {
        let resource: PHAssetResource
        let representation: ExportRepresentation
    }

    // One group represents one logical component that should be exported.
    // A Live Photo normally has a still-image group and a paired-video group.
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

            // Alternate photo (for example RAW/secondary source) is exported as its own component.
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

    private func exportResourceWithRetries(
        _ resource: PHAssetResource,
        asset: PHAsset,
        preferredFinalURL: URL,
        folder: URL
    ) async throws -> (finalURL: URL, bytes: Int64) {
        let finalURL: URL
        if FileManager.default.fileExists(atPath: preferredFinalURL.path) {
            finalURL = conflictSafeURL(for: preferredFinalURL)
        } else {
            finalURL = preferredFinalURL
        }

        let partialURL = finalURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        var lastError: Error?

        // First try Apple's direct resource writer up to 3 times.
        for attempt in 1...3 {
            if shouldCancel { throw BackupError.cancelled }

            do {
                try await writeResourceDirect(resource, to: partialURL)
                let bytes = try verifyAndFinalize(partialURL: partialURL, finalURL: finalURL)
                return (finalURL, bytes)
            } catch {
                lastError = error
                try? FileManager.default.removeItem(at: partialURL)

                if attempt < 3 {
                    // 0.8s, then 1.6s.
                    let delay = UInt64(attempt) * 800_000_000
                    try? await Task.sleep(nanoseconds: delay)
                }
            }
        }

        // Direct write can return generic PHPhotosErrorDomain -1 for some
        // iCloud-backed resources. Stream requestData into our own file as fallback.
        do {
            try await streamResource(resource, to: partialURL)
            let bytes = try verifyAndFinalize(partialURL: partialURL, finalURL: finalURL)
            return (finalURL, bytes)
        } catch {
            try? FileManager.default.removeItem(at: partialURL)
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
                do { try handle.close() } catch {
                    if writeError == nil { writeError = error }
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

    private func verifyAndFinalize(
        partialURL: URL,
        finalURL: URL
    ) throws -> Int64 {
        let bytes = fileSize(of: partialURL)
        guard bytes > 0 else {
            throw BackupError.emptyOutput(partialURL.lastPathComponent)
        }

        try FileManager.default.moveItem(at: partialURL, to: finalURL)

        let finalBytes = fileSize(of: finalURL)
        guard finalBytes == bytes, finalBytes > 0 else {
            try? FileManager.default.removeItem(at: finalURL)
            throw BackupError.verificationFailed(finalURL.lastPathComponent)
        }

        return finalBytes
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

    // We intentionally do not inject GPS into HEIC/JPEG/MOV because doing so
    // would modify the "unmodified original". Instead, save standard XMP GPS
    // metadata next to each exported component.
    private func writeXMPSidecar(
        for asset: PHAsset,
        exportedFilename: String,
        representation: ExportRepresentation,
        resourceType: Int,
        to folder: URL
    ) throws {
        let location = asset.location
        let latitude = location.map { String(format: "%.8f", $0.coordinate.latitude) } ?? ""
        let longitude = location.map { String(format: "%.8f", $0.coordinate.longitude) } ?? ""
        let altitude = location.flatMap {
            $0.verticalAccuracy >= 0 ? String(format: "%.3f", $0.altitude) : nil
        } ?? ""

        let dateFormatter = ISO8601DateFormatter()
        let created = asset.creationDate.map { dateFormatter.string(from: $0) } ?? ""
        let modified = asset.modificationDate.map { dateFormatter.string(from: $0) } ?? ""

        let escapedFilename = xmlEscape(exportedFilename)

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
              photos:ExportedFilename="\(escapedFilename)"
              photos:Representation="\(representation.rawValue)"
              photos:ResourceType="\(resourceType)" />
          </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """

        let sidecarURL = folder.appendingPathComponent(exportedFilename + ".xmp")
        try Data(xmp.utf8).write(to: sidecarURL, options: .atomic)
    }

    private func xmlEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func manifestKey(
        asset: PHAsset,
        resource: PHAssetResource,
        filename: String
    ) -> String {
        "\(asset.localIdentifier)|\(resource.type.rawValue)|\(filename)"
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

    private var manifestFilename: String {
        ".PhotoUSBBackup-manifest.json"
    }

    private var failuresFilename: String {
        "PhotoUSBBackup-failures.json"
    }

    private func manifestURL(in folder: URL) -> URL {
        folder.appendingPathComponent(manifestFilename)
    }

    private func loadManifest(from folder: URL) -> BackupManifest {
        let url = manifestURL(in: folder)

        guard
            let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode(BackupManifest.self, from: data)
        else {
            return BackupManifest()
        }

        return decoded
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

    func cancelBackup() {
        shouldCancel = true
        status = "Stopping after the current file…"
    }
}

enum BackupError: LocalizedError {
    case cancelled
    case noUsableResource
    case emptyOutput(String)
    case verificationFailed(String)
    case resourceReadFailed(String, underlying: String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return "Backup was cancelled."
        case .noUsableResource:
            return "No usable Photos resource was found for this asset."
        case .emptyOutput(let filename):
            return "PhotoKit produced an empty file for \(filename)."
        case .verificationFailed(let filename):
            return "File-size verification failed for \(filename)."
        case .resourceReadFailed(let filename, let underlying):
            return "Could not read \(filename): \(underlying)"
        }
    }
}
