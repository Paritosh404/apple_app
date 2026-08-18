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

    private init() { refreshPermission(); registerBackgroundTask() }

    func refreshPermission() {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = s == .authorized || s == .limited
    }

    func requestPhotoPermission() async {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = s == .authorized || s == .limited
        status = photoAccessGranted ? "Photos access granted." : "Photos access denied."
    }

    func setDestination(_ url: URL) { destinationURL = url; status = "Destination: \(url.lastPathComponent)" }

    private func registerBackgroundTask() {
        guard !taskRegistered else { return }
        taskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let t = task as? BGContinuedProcessingTask else { task.setTaskCompleted(success: false); return }
            Task { @MainActor [weak self] in
                guard let self else { t.setTaskCompleted(success: false); return }
                t.expirationHandler = { Task { @MainActor in self.shouldCancel = true } }
                await self.performBackup(backgroundTask: t)
            }
        }
    }

    func startBackup() {
        guard photoAccessGranted, destinationURL != nil, !isRunning else { return }
        shouldCancel = false
        let req = BGContinuedProcessingTaskRequest(identifier: Self.taskIdentifier, title: "Copying Original Photos", subtitle: "Preparing library")
        req.strategy = .fail
        do { try BGTaskScheduler.shared.submit(req); status = "Starting originals backup…" }
        catch { Task { await performBackup(backgroundTask: nil) } }
    }

    private func performBackup(backgroundTask: BGContinuedProcessingTask?) async {
        guard let folder = destinationURL else { backgroundTask?.setTaskCompleted(success: false); return }
        guard !isRunning else { backgroundTask?.setTaskCompleted(success: false); return }
        isRunning = true; completedItems = 0; copiedFiles = 0; skippedFiles = 0; failedItems = []
        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() }; isRunning = false }
        var manifest = loadManifest(from: folder)
        let opts = PHFetchOptions(); opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: opts); totalItems = assets.count
        backgroundTask?.progress.totalUnitCount = Int64(max(assets.count, 1))
        for i in 0..<assets.count {
            if shouldCancel { saveManifest(manifest, to: folder); saveFailures(to: folder); backgroundTask?.setTaskCompleted(success: false); return }
            let asset = assets.object(at: i)
            do {
                let r = try await copyOriginalResources(for: asset, to: folder, manifest: &manifest)
                copiedFiles += r.copied; skippedFiles += r.skipped
            } catch {
                failedItems.append(FailedItem(assetIdentifier: asset.localIdentifier, filename: "Asset \(i+1)", reason: error.localizedDescription))
            }
            completedItems += 1
            backgroundTask?.progress.completedUnitCount = Int64(completedItems)
            backgroundTask?.updateTitle("Copying Original Photos", subtitle: "\(completedItems) of \(totalItems) assets")
            status = "Backing up \(completedItems) / \(totalItems)"
        }
        saveManifest(manifest, to: folder); saveFailures(to: folder)
        status = failedItems.isEmpty ? "Backup complete." : "Backup finished with \(failedItems.count) failed items."
        backgroundTask?.setTaskCompleted(success: failedItems.isEmpty)
    }

    private func originalResources(for asset: PHAsset) -> [PHAssetResource] {
        let rs = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            var out: [PHAssetResource] = []
            if let r = rs.first(where: {$0.type == .fullSizePhoto}) ?? rs.first(where: {$0.type == .photo}) { out.append(r) }
            if let r = rs.first(where: {$0.type == .pairedVideo}) { out.append(r) }
            for r in rs where r.type == .alternatePhoto { out.append(r) }
            return out
        case .video:
            if let r = rs.first(where: {$0.type == .fullSizeVideo}) ?? rs.first(where: {$0.type == .video}) { return [r] }
            return []
        default: return []
        }
    }

    private func copyOriginalResources(for asset: PHAsset, to folder: URL, manifest: inout BackupManifest) async throws -> (copied:Int, skipped:Int) {
        var copied = 0, skipped = 0
        for r in originalResources(for: asset) {
            let originalName = safeFilename(r.originalFilename)
            let baseKey = "\(asset.localIdentifier)|\(r.type.rawValue)|\(originalName)"
            let baseURL = folder.appendingPathComponent(originalName)
            if let entry = manifest.entries[baseKey], FileManager.default.fileExists(atPath: baseURL.path), fileSize(baseURL) == entry.byteCount, entry.byteCount > 0 { skipped += 1; continue }
            let finalURL = FileManager.default.fileExists(atPath: baseURL.path) ? conflictSafeURL(baseURL) : baseURL
            let partialURL = finalURL.appendingPathExtension("partial")
            try? FileManager.default.removeItem(at: partialURL)
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            try await writeResource(r, to: partialURL, options: options)
            let bytes = fileSize(partialURL)
            guard bytes > 0 else { try? FileManager.default.removeItem(at: partialURL); throw BackupError.emptyOutput(originalName) }
            try FileManager.default.moveItem(at: partialURL, to: finalURL)
            let finalBytes = fileSize(finalURL)
            guard finalBytes == bytes else { throw BackupError.verificationFailed(finalURL.lastPathComponent) }
            let key = "\(asset.localIdentifier)|\(r.type.rawValue)|\(finalURL.lastPathComponent)"
            manifest.entries[key] = ManifestEntry(assetIdentifier: asset.localIdentifier, filename: finalURL.lastPathComponent, byteCount: finalBytes, completedAt: Date())
            copied += 1
        }
        return (copied, skipped)
    }

    private func writeResource(_ resource: PHAssetResource, to url: URL, options: PHAssetResourceRequestOptions) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { e in
                if let e { c.resume(throwing: e) } else { c.resume() }
            }
        }
    }

    private func fileSize(_ url: URL) -> Int64 { Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    private func safeFilename(_ name: String) -> String { name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_") }
    private func conflictSafeURL(_ url: URL) -> URL {
        let folder = url.deletingLastPathComponent(), ext = url.pathExtension, stem = url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            let candidate = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
    private func manifestURL(_ f: URL) -> URL { f.appendingPathComponent(".PhotoUSBBackup-manifest.json") }
    private func loadManifest(from f: URL) -> BackupManifest {
        guard let d = try? Data(contentsOf: manifestURL(f)), let m = try? JSONDecoder().decode(BackupManifest.self, from: d) else { return BackupManifest() }
        return m
    }
    private func saveManifest(_ m: BackupManifest, to f: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(m) { try? d.write(to: manifestURL(f), options: .atomic) }
    }
    private func saveFailures(to f: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(failedItems) { try? d.write(to: f.appendingPathComponent("PhotoUSBBackup-failures.json"), options: .atomic) }
    }
    func cancelBackup() { shouldCancel = true; status = "Stopping after current file…" }
}

enum BackupError: LocalizedError {
    case emptyOutput(String), verificationFailed(String)
    var errorDescription: String? {
        switch self {
        case .emptyOutput(let f): return "Empty output for \(f)."
        case .verificationFailed(let f): return "Verification failed for \(f)."
        }
    }
}
