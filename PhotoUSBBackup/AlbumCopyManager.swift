import Foundation
import Photos
import UIKit

@MainActor
final class AlbumCopyManager: ObservableObject {
    static let shared = AlbumCopyManager()
    @Published var photoAccessGranted = false
    @Published var photoTree: [PhotoTreeNode] = []
    @Published var selectedSource: PhotoTreeNode?
    @Published var destinationURL: URL?
    @Published var transferMode: TransferMode = .usb
    @Published var receiverHost = ""
    @Published var receiverPort = "8765"
    @Published var status = "Choose Photos access, a source album/folder, and destination."
    @Published var isRunning = false
    @Published var isPreparing = false
    @Published var pendingUploads = 0
    @Published var currentItem = ""
    @Published var currentBytesSent: Int64 = 0
    @Published var currentBytesExpected: Int64 = 0
    @Published var stats = CopyStats()
    @Published var failures: [CopyFailure] = []
    private var shouldStop = false
    private var backgroundTaskID:UIBackgroundTaskIdentifier = .invalid
    private var transferTask:Task<Void,Never>?
    private var backgroundExpired = false
    private let backgroundUploader = BackgroundUploadCoordinator.shared
    private lazy var foregroundSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7200
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    var canStart: Bool {
        guard !isPreparing, selectedSource != nil else { return false }
        if pendingUploads > 0 && (stats.totalAssets == 0 || preparationComplete) { return false }
        return transferMode == .usb ? destinationURL != nil : (!receiverHost.trimmingCharacters(in: .whitespaces).isEmpty && Int(receiverPort) != nil)
    }

    var preparationComplete: Bool {
        stats.totalAssets > 0 && stats.processedAssets >= stats.totalAssets
    }

    var primaryActionTitle: String {
        if isPreparing { return "Preparing Transfer…" }
        if pendingUploads > 0 && (stats.totalAssets == 0 || preparationComplete) { return "Uploads Running…" }
        if stats.totalAssets > 0 && stats.processedAssets < stats.totalAssets { return "Resume Preparation" }
        if preparationComplete && stats.failedFiles > 0 { return "Retry Failed Files" }
        if preparationComplete { return "Start New Transfer" }
        return "Start Transfer"
    }

    private init() {
        backgroundUploader.eventHandler = { [weak self] event in
            Task { @MainActor in self?.handleBackgroundUploadEvent(event) }
        }
        backgroundUploader.restoreTasks()
        refreshPermission()
    }

    func refreshPermission() {
        let s = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        photoAccessGranted = s == .authorized || s == .limited
        if photoAccessGranted { refreshPhotoTree() }
    }

    func requestPhotoPermission() async {
        let s = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        photoAccessGranted = s == .authorized || s == .limited
        if photoAccessGranted { refreshPhotoTree(); status = "Photos access granted." }
    }

    func setDestination(_ url: URL) { destinationURL = url; status = "USB destination selected." }
    func selectSource(_ node: PhotoTreeNode) { selectedSource = node; status = "Selected \(node.title)" }
    func stopCopy() {
        shouldStop = true
        transferTask?.cancel()
        status = pendingUploads > 0
            ? "Stopping preparation — queued background uploads will continue."
            : "Stopping after the current file…"
    }

    func refreshPhotoTree() {
        guard photoAccessGranted else { return }
        var roots: [PhotoTreeNode] = []
        let top = PHCollectionList.fetchTopLevelUserCollections(with: nil)
        top.enumerateObjects { c, _, _ in
            if let l = c as? PHCollectionList { roots.append(self.node(l)) }
            else if let a = c as? PHAssetCollection { roots.append(PhotoTreeNode(id:a.localIdentifier,title:a.localizedTitle ?? "Untitled",kind:.album,localIdentifier:a.localIdentifier,children:[])) }
        }
        photoTree = roots.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    private func node(_ list: PHCollectionList) -> PhotoTreeNode {
        var children:[PhotoTreeNode] = []
        PHCollection.fetchCollections(in:list, options:nil).enumerateObjects { c,_,_ in
            if let l = c as? PHCollectionList { children.append(self.node(l)) }
            else if let a = c as? PHAssetCollection { children.append(PhotoTreeNode(id:a.localIdentifier,title:a.localizedTitle ?? "Untitled",kind:.album,localIdentifier:a.localIdentifier,children:[])) }
        }
        return PhotoTreeNode(id:list.localIdentifier,title:list.localizedTitle ?? "Untitled Folder",kind:.folder,localIdentifier:list.localIdentifier,children:children)
    }

    func startCopy() {
        guard canStart, let source = selectedSource else { return }
        if stats.totalAssets == 0 || (stats.processedAssets >= stats.totalAssets && pendingUploads == 0) {
            stats = CopyStats()
            failures = []
        }
        isPreparing = true
        updateRunningState()
        shouldStop = false
        backgroundExpired = false
        beginBackgroundTransfer()
        transferTask = Task {
            await run(source)
            endBackgroundTransfer()
            isPreparing = false
            updateRunningState()
            transferTask = nil
        }
    }

    private func beginBackgroundTransfer() {
        endBackgroundTransfer()
        UIApplication.shared.isIdleTimerDisabled = true
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "PhotoUSB Wi-Fi Transfer") { [weak self] in
            guard let self else { return }
            self.backgroundExpired = true
            self.shouldStop = true
            self.status = self.pendingUploads > 0
                ? "Preparation paused — queued uploads are continuing in the background."
                : "Background time expired — reopen the app, then tap Resume Transfer."
            self.transferTask?.cancel()
            self.endBackgroundTransfer()
        }
    }

    private func endBackgroundTransfer() {
        UIApplication.shared.isIdleTimerDisabled = false
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    private func run(_ source: PhotoTreeNode) async {
        stats.totalAssets = count(source)
        do {
            if transferMode == .usb {
                guard let dest = destinationURL else { return }
                let access = dest.startAccessingSecurityScopedResource(); defer { if access { dest.stopAccessingSecurityScopedResource() } }
                let root = dest.appendingPathComponent(clean(source.title), isDirectory:true)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
                try await copyUSB(source, root, false)
            } else {
                try await retry("PC receiver connection") { try await self.validateReceiver() }
                try await copyWiFi(source, clean(source.title), false)
            }
            if shouldStop {
                status = pendingUploads > 0
                    ? "Preparation paused — \(pendingUploads) queued upload(s) continue in the background."
                    : (backgroundExpired ? "Transfer paused — tap Resume Transfer." : "Stopped — tap Resume Transfer.")
            } else if pendingUploads > 0 {
                status = "Prepared — \(pendingUploads) upload(s) continue in the background. You may leave the app."
            } else {
                status = "Complete — \(stats.copiedFiles) copied, \(stats.skippedFiles) skipped, \(stats.failedFiles) failed."
            }
        } catch is CancellationError {
            status = pendingUploads > 0
                ? "Preparation paused — queued uploads continue in the background."
                : "Transfer paused — tap Resume Transfer."
        } catch { status = "Transfer stopped: \(error.localizedDescription)" }
    }

    private func count(_ n:PhotoTreeNode)->Int {
        if n.kind == .folder { return n.children.reduce(0){$0+count($1)} }
        guard let a = album(n.localIdentifier) else { return 0 }
        return PHAsset.fetchAssets(in:a,options:nil).count
    }

    private func copyUSB(_ n:PhotoTreeNode,_ base:URL,_ own:Bool) async throws {
        if shouldStop { return }
        let here = own ? base.appendingPathComponent(clean(n.title),isDirectory:true) : base
        try FileManager.default.createDirectory(at:here,withIntermediateDirectories:true)
        if n.kind == .folder { for c in n.children { try await copyUSB(c,here,true) }; return }
        guard let a = album(n.localIdentifier) else { return }
        let assets = PHAsset.fetchAssets(in:a,options:nil)
        for i in 0..<assets.count {
            if shouldStop { return }
            do { let r = try await stage(assets.object(at:i)); defer{try? FileManager.default.removeItem(at:r.url)}; let final=here.appendingPathComponent(r.name); if FileManager.default.fileExists(atPath:final.path), size(final)==r.bytes { stats.skippedFiles += 1 } else { try? FileManager.default.removeItem(at:final); try FileManager.default.copyItem(at:r.url,to:final); guard size(final)==r.bytes else { throw CopyError.write }; stats.copiedFiles += 1 } } catch { fail("\(n.title) / asset \(i+1)",error); shouldStop=true; return }
            stats.processedAssets += 1; status="\(n.title): \(i+1) / \(assets.count)"
        }
    }

    private func copyWiFi(_ n:PhotoTreeNode,_ base:String,_ own:Bool) async throws {
        if shouldStop { return }
        let here = own ? base+"/"+clean(n.title) : base
        if n.kind == .folder { for c in n.children { try await copyWiFi(c,here,true) }; return }
        guard let a=album(n.localIdentifier) else{return}; let assets=PHAsset.fetchAssets(in:a,options:nil)
        for i in 0..<assets.count {
            if shouldStop { return }
            let asset=assets.object(at:i)
            var stagedURL: URL?
            var keepStagedFile = false
            do {
                let r=try await retry("iCloud/photo preparation for \(n.title) asset \(i+1)") { try await self.stage(asset, persistent: true) }
                stagedURL = r.url
                try Task.checkCancellation()
                if shouldStop { throw CancellationError() }
                let action=try await retry("PC queue check for \(r.name)") { try await self.queueUpload(r.url,here,r.name,r.bytes) }
                switch action {
                case .skipped:
                    stats.skippedFiles += 1
                case .alreadyQueued:
                    break
                case .enqueued:
                    keepStagedFile = true
                    stats.queuedFiles += 1
                    pendingUploads += 1
                    updateRunningState()
                }
            } catch is CancellationError {
                if let stagedURL, !keepStagedFile { try? FileManager.default.removeItem(at: stagedURL) }
                return
            } catch {
                fail("\(n.title) / asset \(i+1)",error)
            }
            if let stagedURL, !keepStagedFile { try? FileManager.default.removeItem(at: stagedURL) }
            stats.processedAssets+=1
            currentItem = "\(n.title) / \(i+1) of \(assets.count)"
            status="Preparing \(n.title): \(i+1) / \(assets.count) — \(pendingUploads) queued"
        }
    }

    private func stage(_ asset:PHAsset, persistent:Bool = false) async throws -> (url:URL,name:String,bytes:Int64) {
        let rs=PHAssetResource.assetResources(for:asset); guard let r=rs.first(where:{$0.type == .fullSizePhoto || $0.type == .fullSizeVideo}) ?? rs.first else {throw CopyError.resource}
        let name=uniqueAssetName(r.originalFilename, asset.localIdentifier)
        let directory:URL
        if persistent {
            let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)
            directory=support.appendingPathComponent("PhotoUSBUploads",isDirectory:true)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        } else {
            directory=FileManager.default.temporaryDirectory
        }
        let u=directory.appendingPathComponent(UUID().uuidString+"-"+name)
        let o=PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed=true
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in PHAssetResourceManager.default().writeData(for:r,toFile:u,options:o){ e in if let e{c.resume(throwing:e)}else{c.resume()} } }
        let b=size(u); guard b>0 else{throw CopyError.resource}; return(u,name,b)
    }

    func connectFromQRCode(_ value:String) async {
        guard let components=URLComponents(string:value),
              components.scheme?.lowercased()=="photousb",
              components.host?.lowercased()=="connect",
              let host=components.queryItems?.first(where:{$0.name=="host"})?.value,
              let portText=components.queryItems?.first(where:{$0.name=="port"})?.value,
              let port=Int(portText), (1...65535).contains(port), !host.isEmpty else {
            status="That QR code is not a PhotoUSB receiver code."
            return
        }
        receiverHost=host
        receiverPort=String(port)
        status="Validating PhotoUSB receiver…"
        do {
            try await validateReceiver()
            status="Connected to PhotoUSB receiver at \(host):\(port)."
        } catch {
            status="QR found, but receiver validation failed: \(error.localizedDescription)"
        }
    }

    private func validateReceiver() async throws {
        var request=URLRequest(url:try endpoint("/health"))
        request.timeoutInterval=15
        let (data,r)=try await foregroundSession.data(for:request)
        guard (r as? HTTPURLResponse)?.statusCode==200,
              let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              json["service"] as? String=="PhotoUSB Receiver",
              json["protocol_version"] as? Int==1 else { throw CopyError.receiver }
    }
    private func queueUpload(_ file:URL,_ path:String,_ name:String,_ bytes:Int64) async throws -> QueueAction {
        if await backgroundUploader.contains(relativePath:path,filename:name) { return .alreadyQueued }
        var check=URLRequest(url:try endpoint("/check")); check.httpMethod="POST"; check.timeoutInterval=120; check.setValue("application/json",forHTTPHeaderField:"Content-Type"); check.httpBody=try JSONSerialization.data(withJSONObject:["relative_path":path,"filename":name,"size":bytes]); let (d,r)=try await foregroundSession.data(for:check); guard (r as? HTTPURLResponse)?.statusCode==200 else{throw CopyError.receiver}; if let j=try? JSONSerialization.jsonObject(with:d) as? [String:Any], j["exists"] as? Bool == true{return .skipped}
        backgroundUploader.enqueue(fileURL:file,endpoint:try endpoint("/upload"),relativePath:path,filename:name,byteCount:bytes)
        return .enqueued
    }
    private func handleBackgroundUploadEvent(_ event:BackgroundUploadCoordinator.Event) {
        switch event {
        case .restored(let pending):
            pendingUploads = pending
            stats.queuedFiles = max(stats.queuedFiles, pending)
            if pending > 0 {
                status = "Restored \(pending) background upload(s). You may leave the app."
            }
        case .progress(let metadata, let sent, let expected, let pending):
            pendingUploads = pending
            currentItem = metadata.displayPath
            currentBytesSent = sent
            currentBytesExpected = expected
            status = "Uploading in the background — \(pending) remaining."
        case .completed(let metadata, let success, let message, let pending):
            pendingUploads = pending
            currentItem = metadata.displayPath
            currentBytesSent = success ? metadata.byteCount : 0
            currentBytesExpected = metadata.byteCount
            if success {
                stats.copiedFiles += 1
                status = pending > 0
                    ? "Upload saved — \(pending) remaining."
                    : "Complete — \(stats.copiedFiles) copied, \(stats.skippedFiles) skipped, \(stats.failedFiles) failed."
            } else {
                fail(metadata.displayPath, TransferMessageError(message ?? "Background upload failed."))
                status = pending > 0
                    ? "Upload failed; continuing with \(pending) remaining."
                    : "Transfer finished with \(stats.failedFiles) failure(s). Tap Resume Transfer to retry."
            }
        }
        updateRunningState()
    }
    private func updateRunningState() {
        isRunning = isPreparing || pendingUploads > 0
    }
    private func endpoint(_ p:String)throws->URL { guard let u=URL(string:"http://\(receiverHost):\(receiverPort)\(p)") else{throw CopyError.receiver}; return u }
    private func album(_ id:String)->PHAssetCollection? { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:[id],options:nil).firstObject }
    private func size(_ u:URL)->Int64 { Int64((try? u.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
    private func clean(_ s:String)->String { let x=s.replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:":",with:"_").trimmingCharacters(in:.whitespacesAndNewlines); return x.isEmpty ? "Untitled" : x }
    private func retry<T>(_ phase:String,attempts:Int=3,_ operation:() async throws -> T) async throws -> T {
        var lastError:Error?
        for attempt in 1...attempts {
            try Task.checkCancellation()
            if shouldStop { throw CancellationError() }
            do { return try await operation() }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError where error.code == .cancelled { throw CancellationError() }
            catch {
                lastError=error
                if attempt < attempts {
                    status="\(phase) failed — retry \(attempt+1) of \(attempts)…"
                    try await Task.sleep(nanoseconds:UInt64(attempt)*2_000_000_000)
                }
            }
        }
        throw TransferPhaseError(phase:phase,underlying:lastError ?? CopyError.receiver)
    }
    private func uniqueAssetName(_ original:String,_ assetIdentifier:String)->String {
        let cleaned=clean(original)
        let file=cleaned as NSString
        let ext=file.pathExtension
        let stem=file.deletingPathExtension
        let rawID=assetIdentifier.split(separator:"/").first.map(String.init) ?? assetIdentifier
        let suffix=rawID.filter { $0.isLetter || $0.isNumber }
        let stable=suffix.isEmpty ? "asset" : suffix
        let maxStem=max(1,180-stable.count-ext.count-2)
        let shortStem=String(stem.prefix(maxStem))
        return ext.isEmpty ? "\(shortStem)_\(stable)" : "\(shortStem)_\(stable).\(ext)"
    }
    private func fail(_ p:String,_ e:Error){stats.failedFiles+=1;failures.append(CopyFailure(path:p,reason:e.localizedDescription));if failures.count>30{failures.removeFirst()}}
}

private enum QueueAction { case skipped, alreadyQueued, enqueued }

private struct TransferMessageError: LocalizedError {
    let message:String
    init(_ message:String) { self.message=message }
    var errorDescription:String? { message }
}

struct TransferPhaseError: LocalizedError {
    let phase:String
    let underlying:Error
    var errorDescription:String? { "\(phase) failed after 3 attempts: \(underlying.localizedDescription)" }
}

enum CopyError: LocalizedError { case resource,receiver,write; var errorDescription:String? { switch self { case .resource:return "Photos could not provide this file."; case .receiver:return "PC receiver could not be reached."; case .write:return "Destination verification failed." } } }
