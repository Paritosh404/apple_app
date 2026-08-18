import Foundation
import Photos
import BackgroundTasks

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    static let taskIdentifier = "com.paritosh.PhotoUSBBackup.userExport"

    @Published var status = "Choose Photos access and a USB folder."
    @Published var completedItems = 0
    @Published var totalItems = 0
    @Published var copiedFiles = 0
    @Published var skippedFiles = 0
    @Published var failedItems: [FailedItem] = []
    @Published var destinationURL: URL?
    @Published var photoAccessGranted = false
    @Published var isRunning = false

    private var shouldCancel = false
    private var taskRegistered = false

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

        photoAccessGranted =
            authorization == .authorized ||
            authorization == .limited

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

                await self.performBackup(continuedTask: continuedTask)
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

        shouldCancel = false

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Copying Original Photos",
            subtitle: "Preparing your library"
        )
        request.strategy = .fail

        do {
            try BGTaskScheduler.shared.submit(request)
            status = "Starting originals backup…"
        } catch {
            status = "Background continuation unavailable; continuing while the app is active."
            Task {
                await performBackup(continuedTask: nil)
            }
        }
    }

    private func performBackup(
        continuedTask: BGContinuedProcessingTask?
    ) async {
        guard let destinationURL else {
            continuedTask?.setTaskCompleted(success: false)
            return
        }

        guard !isRunning else {
            continuedTask?.setTaskCompleted(success: false)
            return
        }

        isRunning = true
        completedItems = 0
        copiedFiles = 0
        skippedFiles = 0
        failedItems = []

        let hasSecurityAccess = destinationURL.startAccessingSecurityScopedResource()

        defer {
            if hasSecurityAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
            isRunning = false
        }

        var manifest = loadManifest(from: destinationURL)

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [
            NSSortDescriptor(key: "creationDate", ascending: true)
        ]

        let assets = PHAsset.fetchAssets(with: fetchOptions)
        totalItems = assets.count

        continuedTask?.progress.totalUnitCount = Int64(max(assets.count, 1))
        continuedTask?.progress.completedUnitCount = 0

        for index in 0..<assets.count {
            if shouldCancel {
                saveManifest(manifest, to: destinationURL)
                saveFailures(to: destinationURL)
                status = "Stopped at \(completedItems) / \(totalItems). Run again to resume."
                continuedTask?.setTaskCompleted(success: false)
                return
            }

            let asset = assets.object(at: index)

            do {
                let result = try await copyOriginalResources(
                    for: asset,
                    to: destinationURL,
                    manifest: &manifest
                )
                copiedFiles += result.copied
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
            continuedTask?.progress.completedUnitCount = Int64(completedItems)

            continuedTask?.updateTitle(
                "Copying Original Photos",
                subtitle: "\(completedItems) of \(totalItems) assets"
            )

            status = "Backing up \(completedItems) / \(totalItems)"
        }

        saveManifest(manifest, to: destinationURL)
        saveFailures(to: destinationURL)

        status = failedItems.isEmpty
            ? "Backup complete — \(copiedFiles) copied, \(skippedFiles) skipped."
            : "Backup finished with \(failedItems.count) failed items. Run again to retry."

        continuedTask?.setTaskCompleted(success: failedItems.isEmpty)
    }

    private func copyOriginalResources(
        for asset: PHAsset,
        to folder: URL,
        manifest: inout BackupManifest
    ) async throws -> (copied: Int, skipped: Int) {
        let resources = originalResources(for: asset)

        var copied = 0
        var skipped = 0

        for resource in resources {
            if shouldCancel { break }

            let filename = safeFilename(resource.originalFilename)
            let manifestKey = "\(asset.localIdentifier)|\(resource.type.rawValue)|\(filename)"
            let finalURL = folder.appendingPathComponent(filename)

            if let entry = manifest.entries[manifestKey],
               FileManager.default.fileExists(atPath: finalURL.path),
               fileSize(of: finalURL) == entry.byteCount,
               entry.byteCount > 0 {
                skipped += 1
                continue
            }

            let actualFinalURL: URL

            if FileManager.default.fileExists(atPath: finalURL.path) {
                actualFinalURL = conflictSafeURL(for: finalURL)
            } else {
                actualFinalURL = finalURL
            }

            let partialURL = actualFinalURL.appendingPathExtension("partial")

            if FileManager.default.fileExists(atPath: partialURL.path) {
                try? FileManager.default.removeItem(at: partialURL)
            }

            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            try await writeResource(
                resource,
                to: partialURL,
                options: options
            )

            let bytes = fileSize(of: partialURL)

            guard bytes > 0 else {
                try? FileManager.default.removeItem(at: partialURL)
                throw BackupError.emptyOutput(filename)
            }

            try FileManager.default.moveItem(
                at: partialURL,
                to: actualFinalURL
            )

            let verifiedBytes = fileSize(of: actualFinalURL)

            guard verifiedBytes == bytes, verifiedBytes > 0 else {
                try? FileManager.default.removeItem(at: actualFinalURL)
                throw BackupError.verificationFailed(actualFinalURL.lastPathComponent)
            }

            let key =
                "\(asset.localIdentifier)|\(resource.type.rawValue)|\(actualFinalURL.lastPathComponent)"

            manifest.entries[key] = ManifestEntry(
                assetIdentifier: asset.localIdentifier,
                filename: actualFinalURL.lastPathComponent,
                byteCount: verifiedBytes,
                completedAt: Date()
            )

            copied += 1
        }

        return (copied, skipped)
    }

    private func originalResources(for asset: PHAsset) -> [PHAssetResource] {
        let resources = PHAssetResource.assetResources(for: asset)

        switch asset.mediaType {
        case .image:
            var selected: [PHAssetResource] = []

            if let fullPhoto = resources.first(where: { $0.type == .fullSizePhoto }) {
                selected.append(fullPhoto)
            } else if let photo = resources.first(where: { $0.type == .photo }) {
                selected.append(photo)
            }

            if let pairedVideo = resources.first(where: { $0.type == .pairedVideo }) {
                selected.append(pairedVideo)
            }

            for resource in resources {
                if resource.type == .alternatePhoto &&
                   !selected.contains(where: { $0.originalFilename == resource.originalFilename && $0.type == resource.type }) {
                    selected.append(resource)
                }
            }

            return selected

        case .video:
            if let fullVideo = resources.first(where: { $0.type == .fullSizeVideo }) {
                return [fullVideo]
            }

            if let video = resources.first(where: { $0.type == .video }) {
                return [video]
            }

            return []

        default:
            return []
        }
    }

    private func writeResource(
        _ resource: PHAssetResource,
        to url: URL,
        options: PHAssetResourceRequestOptions
    ) async throws {
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

        guard let data = try? encoder.encode(manifest) else {
            return
        }

        try? data.write(
            to: manifestURL(in: folder),
            options: .atomic
        )
    }

    private func saveFailures(to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard let data = try? encoder.encode(failedItems) else {
            return
        }

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
    case emptyOutput(String)
    case verificationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyOutput(let filename):
            return "PhotoKit produced an empty file for \(filename)."

        case .verificationFailed(let filename):
            return "File-size verification failed for \(filename)."
        }
    }
}
