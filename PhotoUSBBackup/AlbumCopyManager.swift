import Foundation
import Photos
import BackgroundTasks

@MainActor
final class AlbumCopyManager: ObservableObject {
    static let shared = AlbumCopyManager()
    static let taskIdentifier = "com.paritosh.PhotoUSBBackup.albumCopy"

    @Published var photoAccessGranted = false
    @Published var photoTree: [PhotoTreeNode] = []
    @Published var selectedSource: PhotoTreeNode?
    @Published var destinationURL: URL?
    @Published var status = "Choose Photos access, a source album/folder, and a USB folder."
    @Published var isRunning = false
    @Published var stats = CopyStats()
    @Published var failures: [CopyFailure] = []

    private var shouldStop = false
    private var taskRegistered = false

    private init() {
        refreshPermission()
        registerBackgroundTask()
    }

    func refreshPermission() {
        let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited
        if photoAccessGranted { refreshPhotoTree() }
    }

    func requestPhotoPermission() async {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = authorization == .authorized || authorization == .limited
        if photoAccessGranted {
            status = authorization == .limited ? "Limited Photos access granted." : "Full Photos access granted."
            refreshPhotoTree()
        } else {
            status = "Photos access was not granted."
        }
    }

    func setDestination(_ url: URL) {
        destinationURL = url
        status = "USB destination selected."
    }

    func selectSource(_ node: PhotoTreeNode) {
        selectedSource = node
        status = "Selected \(node.title)"
    }

    func refreshPhotoTree() {
        guard photoAccessGranted else { return }
        var roots: [PhotoTreeNode] = []
        let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        top.enumerateObjects { collection, _, _ in
            if let list = collection as? PHCollectionList {
                roots.append(self.buildNode(from: list))
            } else if let album = collection as? PHAssetCollection {
                roots.append(PhotoTreeNode(
                    id: album.localIdentifier,
                    title: album.localizedTitle ?? "Untitled Album",
                    kind: .album,
                    localIdentifier: album.localIdentifier,
                    children: []
                ))
            }
        }
        photoTree = roots.sorted {
            $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    private func buildNode(from list: PHCollectionList) -> PhotoTreeNode {
        let result = PHCollection.fetchCollections(in: list, options: nil)
        var children: [PhotoTreeNode] = []
        result.enumerateObjects { collection, _, _ in
            if let subList = collection as? PHCollectionList {
                children.append(self.buildNode(from: subList))
            } else if let album = collection as? PHAssetCollection {
                children.append(PhotoTreeNode(
                    id: album.localIdentifier,
                    title: album.localizedTitle ?? "Untitled Album",
                    kind: .album,
                    localIdentifier: album.localIdentifier,
                    children: []
                ))
            }
        }
        children.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return PhotoTreeNode(
            id: list.localIdentifier,
            title: list.localizedTitle ?? "Untitled Folder",
            kind: .folder,
            localIdentifier: list.localIdentifier,
            children: children
        )
    }

    private func registerBackgroundTask() {
        guard !taskRegistered else { return }
        taskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
            guard let continued = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor [weak self] in
                guard let self else {
                    continued.setTaskCompleted(success: false)
                    return
                }
                continued.expirationHandler = { [weak self] in
                    Task { @MainActor in self?.shouldStop = true }
                }
                if self.isRunning {
                    self.status = "Copy running — background continuation attached."
                    return
                }
                continued.setTaskCompleted(success: true)
            }
        }
    }

    func startCopy() {
        guard let selectedSource else { status = "Choose an album or folder first."; return }
        guard destinationURL != nil else { status = "Choose a USB folder first."; return }
        guard !isRunning else { return }

        isRunning = true
        shouldStop = false
        stats = CopyStats()
        failures = []
        status = "Preparing \(selectedSource.title)…"

        let request = BGContinuedProcessingTaskRequest(
            identifier: Self.taskIdentifier,
            title: "Copying Photos Album",
            subtitle: selectedSource.title
        )
        request.strategy = .fail
        try? BGTaskScheduler.shared.submit(request)

        Task { await performCopy(source: selectedSource) }
    }

    private func performCopy(source: PhotoTreeNode) async {
        guard let destinationURL else { isRunning = false; return }
        let hasAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasAccess { destinationURL.stopAccessingSecurityScopedResource() }
            isRunning = false
        }

        do {
            stats.totalAssets = countAssets(in: source)
            let rootDestination = destinationURL.appendingPathComponent(sanitize(source.title), isDirectory: true)
            try createDirectory(rootDestination)
            try await copyNode(source, to: rootDestination, includeOwnFolderName: false)
            status = shouldStop
                ? "Stopped — run again to resume."
                : "Complete — \(stats.copiedFiles) copied, \(stats.skippedFiles) skipped."
        } catch {
            status = "Copy stopped: \(error.localizedDescription)"
        }
    }

    private func countAssets(in node: PhotoTreeNode) -> Int {
        switch node.kind {
        case .album:
            guard let album = fetchAlbum(node.localIdentifier) else { return 0 }
            return PHAsset.fetchAssets(in: album, options: nil).count
        case .folder:
            return node.children.reduce(0) { $0 + countAssets(in: $1) }
        }
    }

    private func copyNode(_ node: PhotoTreeNode, to destination: URL, includeOwnFolderName: Bool) async throws {
        if shouldStop { return }
        switch node.kind {
        case .album:
            let target = includeOwnFolderName
                ? destination.appendingPathComponent(sanitize(node.title), isDirectory: true)
                : destination
            try createDirectory(target)
            try await copyAlbum(node, to: target)

        case .folder:
            let target = includeOwnFolderName
                ? destination.appendingPathComponent(sanitize(node.title), isDirectory: true)
                : destination
            try createDirectory(target)
            for child in node.children {
                if shouldStop { return }
                try await copyNode(child, to: target, includeOwnFolderName: true)
            }
        }
    }

    private func copyAlbum(_ node: PhotoTreeNode, to destination: URL) async throws {
        guard let album = fetchAlbum(node.localIdentifier) else {
            throw CopyError.albumUnavailable(node.title)
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(in: album, options: options)

        for index in 0..<assets.count {
            if shouldStop { return }
            let asset = assets.object(at: index)
            status = "\(node.title): \(index + 1) / \(assets.count)"
            do {
                let result = try await copyAsset(asset, to: destination)
                stats.copiedFiles += result.copied
                stats.skippedFiles += result.skipped
            } catch {
                stats.failedFiles += 1
                failures.append(CopyFailure(path: "\(node.title) / asset \(index + 1)", reason: error.localizedDescription))
                if failures.count > 30 { failures.removeFirst(failures.count - 30) }
            }
            stats.processedAssets += 1
            if stats.processedAssets % 25 == 0 { await Task.yield() }
        }
    }

    private func copyAsset(_ asset: PHAsset, to destination: URL) async throws -> (copied: Int, skipped: Int) {
        guard let resource = preferredCurrentResource(for: asset) else { throw CopyError.noUsableResource }
        let filename = sanitizeFilename(resource.originalFilename)
        let finalURL = destination.appendingPathComponent(filename)

        if FileManager.default.fileExists(atPath: finalURL.path), fileSize(of: finalURL) > 0 {
            return (0, 1)
        }

        let localTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + "-" + filename)
        try? FileManager.default.removeItem(at: localTemp)
        defer { try? FileManager.default.removeItem(at: localTemp) }

        try await writeResource(resource, to: localTemp)
        let localBytes = fileSize(of: localTemp)
        guard localBytes > 0 else { throw CopyError.emptyFile(filename) }

        let partialURL = finalURL.appendingPathExtension("partial")
        try? FileManager.default.removeItem(at: partialURL)

        try streamLocalFileToUSB(
            sourceURL: localTemp,
            partialURL: partialURL,
            finalURL: finalURL,
            expectedBytes: localBytes
        )

        return (1, 0)
    }


    private func streamLocalFileToUSB(
        sourceURL: URL,
        partialURL: URL,
        finalURL: URL,
        expectedBytes: Int64
    ) throws {
        var sourceHandle: FileHandle?
        var destinationHandle: FileHandle?

        do {
            do {
                sourceHandle = try FileHandle(forReadingFrom: sourceURL)
            } catch {
                throw usbError(
                    stage: "open source",
                    file: sourceURL.lastPathComponent,
                    underlying: error
                )
            }

            guard FileManager.default.createFile(
                atPath: partialURL.path,
                contents: nil
            ) else {
                throw CopyError.usbWrite(
                    stage: "create",
                    filename: partialURL.lastPathComponent,
                    domain: "FileManager",
                    code: -1,
                    message: "Could not create USB .partial file."
                )
            }

            do {
                destinationHandle = try FileHandle(forWritingTo: partialURL)
            } catch {
                throw usbError(
                    stage: "open destination",
                    file: partialURL.lastPathComponent,
                    underlying: error
                )
            }

            let chunkSize = 1024 * 1024
            var written: Int64 = 0

            while true {
                let data: Data
                do {
                    data = try sourceHandle!.read(upToCount: chunkSize) ?? Data()
                } catch {
                    throw usbError(
                        stage: "read local temp",
                        file: sourceURL.lastPathComponent,
                        underlying: error
                    )
                }

                if data.isEmpty {
                    break
                }

                do {
                    try destinationHandle!.write(contentsOf: data)
                    written += Int64(data.count)
                } catch {
                    throw usbError(
                        stage: "write USB",
                        file: partialURL.lastPathComponent,
                        underlying: error
                    )
                }
            }

            do {
                try destinationHandle?.synchronize()
                try destinationHandle?.close()
                destinationHandle = nil
            } catch {
                throw usbError(
                    stage: "flush/close USB",
                    file: partialURL.lastPathComponent,
                    underlying: error
                )
            }

            do {
                try sourceHandle?.close()
                sourceHandle = nil
            } catch {
                throw usbError(
                    stage: "close source",
                    file: sourceURL.lastPathComponent,
                    underlying: error
                )
            }

            let partialBytes = fileSize(of: partialURL)
            guard written == expectedBytes,
                  partialBytes == expectedBytes,
                  partialBytes > 0 else {
                throw CopyError.usbWrite(
                    stage: "verify",
                    filename: partialURL.lastPathComponent,
                    domain: "PhotoUSBBackup",
                    code: -2,
                    message: "Expected \(expectedBytes) bytes, wrote \(written), USB file reports \(partialBytes)."
                )
            }

            do {
                try FileManager.default.moveItem(
                    at: partialURL,
                    to: finalURL
                )
            } catch {
                throw usbError(
                    stage: "rename",
                    file: finalURL.lastPathComponent,
                    underlying: error
                )
            }

            let finalBytes = fileSize(of: finalURL)
            guard finalBytes == expectedBytes else {
                try? FileManager.default.removeItem(at: finalURL)
                throw CopyError.usbWrite(
                    stage: "final verify",
                    filename: finalURL.lastPathComponent,
                    domain: "PhotoUSBBackup",
                    code: -3,
                    message: "Expected \(expectedBytes) bytes, final file reports \(finalBytes)."
                )
            }
        } catch {
            try? destinationHandle?.close()
            try? sourceHandle?.close()
            try? FileManager.default.removeItem(at: partialURL)
            throw error
        }
    }

    private func usbError(
        stage: String,
        file: String,
        underlying error: Error
    ) -> CopyError {
        let nsError = error as NSError
        return .usbWrite(
            stage: stage,
            filename: file,
            domain: nsError.domain,
            code: nsError.code,
            message: nsError.localizedDescription
        )
    }

    private func preferredCurrentResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        switch asset.mediaType {
        case .image:
            return resources.first(where: { $0.type == .fullSizePhoto })
                ?? resources.first(where: { $0.type == .photo })
                ?? resources.first
        case .video:
            return resources.first(where: { $0.type == .fullSizeVideo })
                ?? resources.first(where: { $0.type == .video })
                ?? resources.first
        default:
            return resources.first
        }
    }

    private func writeResource(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private func fetchAlbum(_ identifier: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    private func createDirectory(_ url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }

    private func fileSize(of url: URL) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return Int64(values.fileSize ?? 0)
        } catch { return 0 }
    }

    private func sanitize(_ value: String) -> String {
        let cleaned = value
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled" : cleaned
    }

    private func sanitizeFilename(_ value: String) -> String { sanitize(value) }

    func stopCopy() {
        shouldStop = true
        status = "Stopping after the current file…"
    }
}

enum CopyError: LocalizedError {
    case albumUnavailable(String)
    case noUsableResource
    case emptyFile(String)
    case verificationFailed(String)
    case usbWrite(stage: String, filename: String, domain: String, code: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .albumUnavailable(let name):
            return "The Photos album \(name) is no longer available."
        case .noUsableResource:
            return "Photos did not expose a usable resource for this asset."
        case .emptyFile(let name):
            return "Photos produced an empty file for \(name)."
        case .verificationFailed(let name):
            return "USB verification failed for \(name)."
        case .usbWrite(let stage, let filename, let domain, let code, let message):
            return "USB \(stage) failed for \(filename) [\(domain) \(code)]: \(message)"
        }
    }
}
