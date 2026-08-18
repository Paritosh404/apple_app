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

    private init() {
        refreshPermission()
        registerContinuedProcessingTask()
    }

    func refreshPermission() {
        let a = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = a == .authorized || a == .limited
    }

    func requestPhotoPermission() async {
        let a = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = a == .authorized || a == .limited
        switch a {
        case .authorized: status = "Full Photos access granted."
        case .limited: status = "Limited Photos access granted."
        case .denied, .restricted: status = "Photos access was not granted."
        case .notDetermined: status = "Photos permission is still undetermined."
        @unknown default: status = "Unknown Photos permission state."
        }
    }

    func setDestination(_ url: URL) {
        destinationURL = url
        status = "Destination selected: \(url.lastPathComponent)"
    }

    private func registerContinuedProcessingTask() {
        guard !taskRegistered else { return }
        taskRegistered = BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { [weak self] task in
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
                    Task { @MainActor in self?.shouldCancel = true }
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
        guard photoAccessGranted else { status = "Allow Photos access first."; return }
        guard destinationURL != nil else { status = "Choose a USB folder first."; return }
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

        Task { await performBackup(runID: runID) }
    }

    private func performBackup(runID: UUID) async {
        guard activeRunID == runID, let root = destinationURL else { return }
        let security = root.startAccessingSecurityScopedResource()
        defer {
            if security { root.stopAccessingSecurityScopedResource() }
            if activeRunID == runID { activeRunID = nil; isRunning = false }
        }

        do { try createFolders(root) }
        catch { status = "Could not create backup folders: \(error.localizedDescription)"; return }

        var manifest = loadManifest(from: root)
        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let assets = PHAsset.fetchAssets(with: opts)
        totalItems = assets.count
        status = "Found \(totalItems) Photos assets."

        for index in 0..<assets.count {
            if shouldCancel {
                saveManifest(manifest, to: root)
                saveFailures(to: root)
                saveDuplicateReport(to: root)
                status = "Stopped at \(completedItems) / \(totalItems). Run again to resume."
                return
            }
            let asset = assets.object(at: index)
            status = "Asset \(index + 1) / \(totalItems)"
            do {
                let r = try await exportAsset(asset, root: root, manifest: &manifest)
                copiedFiles += r.copied
                originalFiles += r.original
                fallbackFiles += r.fallback
                disputedFiles += r.disputed
                mergedFiles += r.merged
                skippedFiles += r.skipped
                adoptedFiles += r.adopted
                conflictFiles += r.conflicts
            } catch {
                failedItems.append(FailedItem(assetIdentifier: asset.localIdentifier, filename: "Asset \(index + 1)", reason: error.localizedDescription))
            }
            completedItems += 1
            saveManifest(manifest, to: root)
            saveFailures(to: root)
            saveDuplicateReport(to: root)
        }

        saveManifest(manifest, to: root)
        saveFailures(to: root)
        saveDuplicateReport(to: root)
        status = failedItems.isEmpty
            ? "Complete — \(originalFiles) original, \(disputedFiles) disputed."
            : "Finished — \(originalFiles) original, \(disputedFiles) disputed, \(failedItems.count) failed."
    }

    private func createFolders(_ root: URL) throws {
        for rel in ["Originals", "Metadata-Disputed/Original", "Metadata-Disputed/GPS-Merged", ".PhotoUSBBackup-Staging"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(rel, isDirectory: true), withIntermediateDirectories: true)
        }
    }

    private struct ResourceCandidate {
        let resource: PHAssetResource
        let representation: ExportRepresentation
    }

    private func exportAsset(_ asset: PHAsset, root: URL, manifest: inout BackupManifest) async throws
    -> (copied: Int, original: Int, fallback: Int, disputed: Int, merged: Int, skipped: Int, adopted: Int, conflicts: Int) {
        var copied = 0, originals = 0, fallbacks = 0, disputed = 0, merged = 0, skipped = 0, adopted = 0, conflicts = 0

        for group in resourceCandidateGroups(for: asset) {
            var success = false
            var lastError: Error?

            for candidate in group {
                let resource = candidate.resource

                if let existing = findVerifiedManifestEntry(asset: asset, resource: resource, manifest: manifest, root: root) {
                    skipped += 1
                    if existing.metadataDisposition == .disputed || existing.metadataDisposition == .mergeUnsupported {
                        disputed += 1
                        if existing.mergedFilename != nil { merged += 1 }
                    }
                    success = true
                    break
                }

                do {
                    let staged = try await stageResource(resource, root: root)
                    let stagedBytes = fileSize(of: staged)
                    guard stagedBytes > 0 else { throw BackupError.emptyOutput(resource.originalFilename) }

                    if let match = try findExactExistingFile(forStagedURL: staged, originalFilename: resource.originalFilename, root: root) {
                        let key = manifestKey(asset: asset, resource: resource, filename: match.url.lastPathComponent)
                        manifest.entries[key] = ManifestEntry(
                            assetIdentifier: asset.localIdentifier,
                            filename: relativePath(match.url, from: root),
                            byteCount: match.size,
                            completedAt: Date(),
                            creationDate: asset.creationDate,
                            modificationDate: asset.modificationDate,
                            location: archiveLocation(asset.location),
                            photosLocation: archiveLocation(asset.location),
                            embeddedLocation: embeddedGPS(from: match.url),
                            resourceType: resource.type.rawValue,
                            representation: candidate.representation,
                            originalFilename: resource.originalFilename,
                            metadataDisposition: .normal,
                            mergedFilename: nil
                        )
                        duplicateReport.append(DuplicateReportItem(
                            sourceFilename: resource.originalFilename,
                            existingPath: relativePath(match.url, from: root),
                            action: "adopted-existing-identical",
                            sourceSize: stagedBytes,
                            existingSize: match.size,
                            sha256: match.sha256
                        ))
                        try? FileManager.default.removeItem(at: staged)
                        skipped += 1
                        adopted += 1
                        success = true
                        break
                    }

                    let photosGPS = archiveLocation(asset.location)
                    let embeddedGPSValue = embeddedGPS(from: staged)
                    let isDisputed = gpsIsDisputed(photos: photosGPS, embedded: embeddedGPSValue)
                    let originalFolder = root.appendingPathComponent(isDisputed ? "Metadata-Disputed/Original" : "Originals", isDirectory: true)
                    let wanted = originalFolder.appendingPathComponent(safeFilename(resource.originalFilename))
                    let finalURL: URL
                    if FileManager.default.fileExists(atPath: wanted.path) {
                        finalURL = conflictSafeURL(for: wanted)
                        conflicts += 1
                    } else {
                        finalURL = wanted
                    }
                    try FileManager.default.moveItem(at: staged, to: finalURL)
                    let bytes = fileSize(of: finalURL)
                    guard bytes > 0 else { throw BackupError.emptyOutput(finalURL.lastPathComponent) }

                    var disposition: MetadataDisposition = isDisputed ? .disputed : .normal
                    var mergedPath: String?

                    if isDisputed {
                        disputed += 1
                        let mergedFolder = root.appendingPathComponent("Metadata-Disputed/GPS-Merged", isDirectory: true)
                        if canMergeMetadata(for: finalURL) {
                            let wantedMerged = mergedFolder.appendingPathComponent(finalURL.lastPathComponent)
                            let mergedURL = FileManager.default.fileExists(atPath: wantedMerged.path) ? conflictSafeURL(for: wantedMerged) : wantedMerged
                            try createGPSMergedCopy(sourceURL: finalURL, destinationURL: mergedURL, photosLocation: photosGPS, creationDate: asset.creationDate, modificationDate: asset.modificationDate)
                            merged += 1
                            mergedPath = relativePath(mergedURL, from: root)
                        } else {
                            disposition = .mergeUnsupported
                            let wantedXMP = mergedFolder.appendingPathComponent(finalURL.lastPathComponent + ".xmp")
                            let xmp = FileManager.default.fileExists(atPath: wantedXMP.path) ? conflictSafeURL(for: wantedXMP) : wantedXMP
                            try writeXMPSidecar(for: asset, exportedFilename: finalURL.lastPathComponent, representation: candidate.representation, resourceType: resource.type.rawValue, to: xmp)
                            mergedPath = relativePath(xmp, from: root)
                        }
                    }

                    let key = manifestKey(asset: asset, resource: resource, filename: finalURL.lastPathComponent)
                    manifest.entries[key] = ManifestEntry(
                        assetIdentifier: asset.localIdentifier,
                        filename: relativePath(finalURL, from: root),
                        byteCount: bytes,
                        completedAt: Date(),
                        creationDate: asset.creationDate,
                        modificationDate: asset.modificationDate,
                        location: photosGPS,
                        photosLocation: photosGPS,
                        embeddedLocation: embeddedGPSValue,
                        resourceType: resource.type.rawValue,
                        representation: candidate.representation,
                        originalFilename: resource.originalFilename,
                        metadataDisposition: disposition,
                        mergedFilename: mergedPath
                    )

                    copied += 1
                    if candidate.representation == .original { originals += 1 } else { fallbacks += 1 }
                    success = true
                    break
                } catch { lastError = error }
            }

            if !success { throw lastError ?? BackupError.noUsableResource }
        }
        return (copied, originals, fallbacks, disputed, merged, skipped, adopted, conflicts)
    }

    private func resourceCandidateGroups(for asset: PHAsset) -> [[ResourceCandidate]] {
        let resources = PHAssetResource.assetResources(for: asset)
        var groups: [[ResourceCandidate]] = []
        switch asset.mediaType {
        case .image:
            var still: [ResourceCandidate] = []
            if let r = resources.first(where: { $0.type == .photo }) { still.append(.init(resource: r, representation: .original)) }
            if let r = resources.first(where: { $0.type == .adjustmentBasePhoto }) { still.append(.init(resource: r, representation: .adjustmentBase)) }
            if let r = resources.first(where: { $0.type == .fullSizePhoto }) { still.append(.init(resource: r, representation: .renderedFallback)) }
            if !still.isEmpty { groups.append(still) }
            for r in resources.filter({ $0.type == .alternatePhoto }) { groups.append([.init(resource: r, representation: .original)]) }
            var live: [ResourceCandidate] = []
            if let r = resources.first(where: { $0.type == .pairedVideo }) { live.append(.init(resource: r, representation: .original)) }
            if let r = resources.first(where: { $0.type == .fullSizePairedVideo }) { live.append(.init(resource: r, representation: .renderedFallback)) }
            if !live.isEmpty { groups.append(live) }
        case .video:
            var v: [ResourceCandidate] = []
            if let r = resources.first(where: { $0.type == .video }) { v.append(.init(resource: r, representation: .original)) }
            if let r = resources.first(where: { $0.type == .adjustmentBaseVideo }) { v.append(.init(resource: r, representation: .adjustmentBase)) }
            if let r = resources.first(where: { $0.type == .fullSizeVideo }) { v.append(.init(resource: r, representation: .renderedFallback)) }
            if !v.isEmpty { groups.append(v) }
        default: break
        }
        return groups
    }

    private func stageResource(_ resource: PHAssetResource, root: URL) async throws -> URL {
        let staging = root.appendingPathComponent(".PhotoUSBBackup-Staging", isDirectory: true)
        let url = staging.appendingPathComponent(UUID().uuidString + "-" + safeFilename(resource.originalFilename) + ".partial")
        var last: Error?

        for attempt in 1...3 {
            if shouldCancel { throw BackupError.cancelled }
            try? FileManager.default.removeItem(at: url)
            do {
                try await writeResourceDirect(resource, to: url)
                guard fileSize(of: url) > 0 else { throw BackupError.emptyOutput(resource.originalFilename) }
                return url
            } catch {
                last = error
                if attempt < 3 { try? await Task.sleep(nanoseconds: UInt64(attempt) * 800_000_000) }
            }
        }

        try? FileManager.default.removeItem(at: url)
        do {
            try await streamResource(resource, to: url)
            guard fileSize(of: url) > 0 else { throw BackupError.emptyOutput(resource.originalFilename) }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw BackupError.resourceReadFailed(resource.originalFilename, underlying: "\(last?.localizedDescription ?? "direct write failed"); stream fallback: \(error.localizedDescription)")
        }
    }

    private func writeResourceDirect(_ resource: PHAssetResource, to url: URL) async throws {
        let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: o) { error in
                if let error { c.resume(throwing: error) } else { c.resume() }
            }
        }
    }

    private func streamResource(_ resource: PHAssetResource, to url: URL) async throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let o = PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            var writeError: Error?
            PHAssetResourceManager.default().requestData(for: resource, options: o) { data in
                guard writeError == nil else { return }
                do { try handle.write(contentsOf: data) } catch { writeError = error }
            } completionHandler: { error in
                do { try handle.close() } catch { if writeError == nil { writeError = error } }
                if let writeError { c.resume(throwing: writeError) }
                else if let error { c.resume(throwing: error) }
                else { c.resume() }
            }
        }
    }

    private func embeddedGPS(from url: URL) -> AssetLocation? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
              let lat0 = number(gps[kCGImagePropertyGPSLatitude]),
              let lon0 = number(gps[kCGImagePropertyGPSLongitude]) else { return nil }
        let latRef = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
        let lonRef = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
        let lat = latRef.uppercased() == "S" ? -abs(lat0) : abs(lat0)
        let lon = lonRef.uppercased() == "W" ? -abs(lon0) : abs(lon0)
        let alt0 = number(gps[kCGImagePropertyGPSAltitude])
        let altRef = number(gps[kCGImagePropertyGPSAltitudeRef]) ?? 0
        let alt = alt0.map { altRef == 1 ? -abs($0) : $0 }
        return AssetLocation(latitude: lat, longitude: lon, altitude: alt, horizontalAccuracy: nil, verticalAccuracy: nil)
    }

    private func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private func gpsIsDisputed(photos: AssetLocation?, embedded: AssetLocation?) -> Bool {
        guard let photos else { return false }
        guard let embedded else { return true }
        let a = CLLocation(latitude: photos.latitude, longitude: photos.longitude)
        let b = CLLocation(latitude: embedded.latitude, longitude: embedded.longitude)
        return a.distance(from: b) > 25.0
    }

    private func canMergeMetadata(for url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(source) else { return false }
        let id = type as String
        return id == UTType.jpeg.identifier || id == UTType.heic.identifier || id == UTType.heif.identifier
    }

    private func createGPSMergedCopy(sourceURL: URL, destinationURL: URL, photosLocation: AssetLocation?, creationDate: Date?, modificationDate: Date?) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(destinationURL as CFURL, type, 1, nil)
        else { throw BackupError.metadataMergeFailed(destinationURL.lastPathComponent) }

        var meta = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        var gps = (meta[kCGImagePropertyGPSDictionary] as? [CFString: Any]) ?? [:]
        if let p = photosLocation {
            gps[kCGImagePropertyGPSLatitude] = abs(p.latitude)
            gps[kCGImagePropertyGPSLatitudeRef] = p.latitude < 0 ? "S" : "N"
            gps[kCGImagePropertyGPSLongitude] = abs(p.longitude)
            gps[kCGImagePropertyGPSLongitudeRef] = p.longitude < 0 ? "W" : "E"
            if let alt = p.altitude {
                gps[kCGImagePropertyGPSAltitude] = abs(alt)
                gps[kCGImagePropertyGPSAltitudeRef] = alt < 0 ? 1 : 0
            }
        }
        meta[kCGImagePropertyGPSDictionary] = gps

        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy:MM:dd HH:mm:ss"
        var exif = (meta[kCGImagePropertyExifDictionary] as? [CFString: Any]) ?? [:]
        if let creationDate {
            exif[kCGImagePropertyExifDateTimeOriginal] = df.string(from: creationDate)
            exif[kCGImagePropertyExifDateTimeDigitized] = df.string(from: creationDate)
        }
        meta[kCGImagePropertyExifDictionary] = exif
        if let modificationDate {
            var tiff = (meta[kCGImagePropertyTIFFDictionary] as? [CFString: Any]) ?? [:]
            tiff[kCGImagePropertyTIFFDateTime] = df.string(from: modificationDate)
            meta[kCGImagePropertyTIFFDictionary] = tiff
        }

        CGImageDestinationAddImageFromSource(dest, source, 0, meta as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            try? FileManager.default.removeItem(at: destinationURL)
            throw BackupError.metadataMergeFailed(destinationURL.lastPathComponent)
        }
    }

    private func archiveLocation(_ l: CLLocation?) -> AssetLocation? {
        guard let l else { return nil }
        return AssetLocation(latitude: l.coordinate.latitude, longitude: l.coordinate.longitude,
                             altitude: l.verticalAccuracy >= 0 ? l.altitude : nil,
                             horizontalAccuracy: l.horizontalAccuracy >= 0 ? l.horizontalAccuracy : nil,
                             verticalAccuracy: l.verticalAccuracy >= 0 ? l.verticalAccuracy : nil)
    }

    private func writeXMPSidecar(for asset: PHAsset, exportedFilename: String, representation: ExportRepresentation, resourceType: Int, to url: URL) throws {
        let l = asset.location
        let lat = l.map { String(format: "%.8f", $0.coordinate.latitude) } ?? ""
        let lon = l.map { String(format: "%.8f", $0.coordinate.longitude) } ?? ""
        let alt = l.flatMap { $0.verticalAccuracy >= 0 ? String(format: "%.3f", $0.altitude) : nil } ?? ""
        let iso = ISO8601DateFormatter()
        let created = asset.creationDate.map { iso.string(from: $0) } ?? ""
        let modified = asset.modificationDate.map { iso.string(from: $0) } ?? ""
        let xmp = """
        <?xpacket begin="﻿" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:photos="https://example.invalid/photousbbackup/1.0/" exif:GPSLatitude="\(lat)" exif:GPSLongitude="\(lon)" exif:GPSAltitude="\(alt)" xmp:CreateDate="\(created)" xmp:ModifyDate="\(modified)" photos:AssetLocalIdentifier="\(xmlEscape(asset.localIdentifier))" photos:ExportedFilename="\(xmlEscape(exportedFilename))" photos:Representation="\(representation.rawValue)" photos:ResourceType="\(resourceType)" /></rdf:RDF></x:xmpmeta>
        <?xpacket end="w"?>
        """
        try Data(xmp.utf8).write(to: url, options: .atomic)
    }

    private struct ExistingMatch {
        let url: URL
        let size: Int64
        let sha256: String
    }

    private func findExactExistingFile(forStagedURL staged: URL, originalFilename: String, root: URL) throws -> ExistingMatch? {
        let sourceSize = fileSize(of: staged)
        guard sourceSize > 0 else { return nil }
        let expected = safeFilename(originalFilename)
        let candidates = recursiveFiles(named: expected, under: root).filter { !$0.path.contains("/.PhotoUSBBackup-Staging/") }
        let sameSize = candidates.filter { fileSize(of: $0) == sourceSize }
        guard !sameSize.isEmpty else { return nil }
        let sourceHash = try sha256(of: staged)
        for candidate in sameSize {
            let candidateHash = try sha256(of: candidate)
            if candidateHash == sourceHash {
                return ExistingMatch(url: candidate, size: sourceSize, sha256: candidateHash)
            }
        }
        return nil
    }

    private func recursiveFiles(named filename: String, under root: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [URL] = []
        for case let u as URL in e {
            if u.lastPathComponent == filename { out.append(u) }
        }
        return out
    }

    private func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let d = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if d.isEmpty { break }
            hasher.update(data: d)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func findVerifiedManifestEntry(asset: PHAsset, resource: PHAssetResource, manifest: BackupManifest, root: URL) -> ManifestEntry? {
        manifest.entries.values.first { entry in
            guard entry.assetIdentifier == asset.localIdentifier, entry.resourceType == resource.type.rawValue else { return false }
            let u = root.appendingPathComponent(entry.filename)
            return FileManager.default.fileExists(atPath: u.path) && fileSize(of: u) == entry.byteCount && entry.byteCount > 0
        }
    }

    private func manifestKey(asset: PHAsset, resource: PHAssetResource, filename: String) -> String {
        "\(asset.localIdentifier)|\(resource.type.rawValue)|\(filename)"
    }

    private func relativePath(_ url: URL, from root: URL) -> String {
        let r = root.standardizedFileURL.path, f = url.standardizedFileURL.path
        return f.hasPrefix(r + "/") ? String(f.dropFirst(r.count + 1)) : url.lastPathComponent
    }

    private func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func safeFilename(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "_")
    }

    private func conflictSafeURL(for original: URL) -> URL {
        let folder = original.deletingLastPathComponent(), ext = original.pathExtension, stem = original.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = ext.isEmpty ? "\(stem)_\(n)" : "\(stem)_\(n).\(ext)"
            let c = folder.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: c.path) { return c }
            n += 1
        }
    }

    private func fileSize(of u: URL) -> Int64 {
        Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    private var manifestFilename: String { ".PhotoUSBBackup-manifest.json" }
    private var failuresFilename: String { "PhotoUSBBackup-failures.json" }
    private var duplicateReportFilename: String { "PhotoUSBBackup-duplicate-report.json" }
    private func manifestURL(in f: URL) -> URL { f.appendingPathComponent(manifestFilename) }

    private func loadManifest(from f: URL) -> BackupManifest {
        guard let d = try? Data(contentsOf: manifestURL(in: f)), let m = try? JSONDecoder().decode(BackupManifest.self, from: d) else { return BackupManifest() }
        return m
    }

    private func saveManifest(_ m: BackupManifest, to f: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(m) { try? d.write(to: manifestURL(in: f), options: .atomic) }
    }

    private func saveFailures(to f: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(failedItems) { try? d.write(to: f.appendingPathComponent(failuresFilename), options: .atomic) }
    }

    private func saveDuplicateReport(to f: URL) {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let d = try? e.encode(duplicateReport) { try? d.write(to: f.appendingPathComponent(duplicateReportFilename), options: .atomic) }
    }

    func cancelBackup() { shouldCancel = true; status = "Stopping after the current file…" }
}

enum BackupError: LocalizedError {
    case cancelled, noUsableResource
    case emptyOutput(String)
    case resourceReadFailed(String, underlying: String)
    case metadataMergeFailed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Backup was cancelled."
        case .noUsableResource: return "No usable Photos resource was found for this asset."
        case .emptyOutput(let f): return "PhotoKit produced an empty file for \(f)."
        case .resourceReadFailed(let f, let u): return "Could not read \(f): \(u)"
        case .metadataMergeFailed(let f): return "Could not create GPS-merged copy for \(f)."
        }
    }
}
