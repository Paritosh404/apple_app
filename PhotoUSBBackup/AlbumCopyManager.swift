import Foundation
import Photos

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
    @Published var stats = CopyStats()
    @Published var failures: [CopyFailure] = []
    private var shouldStop = false
    private lazy var wifiSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7200
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 1
        return URLSession(configuration: configuration)
    }()

    var canStart: Bool {
        guard !isRunning, selectedSource != nil else { return false }
        return transferMode == .usb ? destinationURL != nil : (!receiverHost.trimmingCharacters(in: .whitespaces).isEmpty && Int(receiverPort) != nil)
    }

    private init() { refreshPermission() }

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
    func stopCopy() { shouldStop = true; status = "Stopping after current file…" }

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
        isRunning = true; shouldStop = false; stats = CopyStats(); failures = []
        Task { await run(source); isRunning = false }
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
                try await retry("PC receiver connection") { try await self.ping() }
                try await copyWiFi(source, clean(source.title), false)
            }
            status = shouldStop ? "Stopped — run again to resume." : "Complete — \(stats.copiedFiles) copied, \(stats.skippedFiles) skipped, \(stats.failedFiles) failed."
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
            do {
                let r=try await retry("iCloud/photo preparation for \(n.title) asset \(i+1)") { try await self.stage(asset) }
                defer { try? FileManager.default.removeItem(at:r.url) }
                let skipped=try await retry("PC upload for \(r.name)") { try await self.upload(r.url,here,r.name,r.bytes) }
                if skipped { stats.skippedFiles+=1 } else { stats.copiedFiles+=1 }
            } catch is CancellationError {
                return
            } catch {
                fail("\(n.title) / asset \(i+1)",error)
            }
            stats.processedAssets+=1
            status="\(n.title): \(i+1) / \(assets.count) — \(stats.failedFiles) failed"
        }
    }

    private func stage(_ asset:PHAsset) async throws -> (url:URL,name:String,bytes:Int64) {
        let rs=PHAssetResource.assetResources(for:asset); guard let r=rs.first(where:{$0.type == .fullSizePhoto || $0.type == .fullSizeVideo}) ?? rs.first else {throw CopyError.resource}
        let name=uniqueAssetName(r.originalFilename, asset.localIdentifier); let u=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString+"-"+name); let o=PHAssetResourceRequestOptions(); o.isNetworkAccessAllowed=true
        try await withCheckedThrowingContinuation { (c:CheckedContinuation<Void,Error>) in PHAssetResourceManager.default().writeData(for:r,toFile:u,options:o){ e in if let e{c.resume(throwing:e)}else{c.resume()} } }
        let b=size(u); guard b>0 else{throw CopyError.resource}; return(u,name,b)
    }

    private func ping() async throws {
        var request=URLRequest(url:try endpoint("/health"))
        request.timeoutInterval=15
        let (_,r)=try await wifiSession.data(for:request)
        guard (r as? HTTPURLResponse)?.statusCode==200 else{throw CopyError.receiver}
    }
    private func upload(_ file:URL,_ path:String,_ name:String,_ bytes:Int64) async throws -> Bool {
        var check=URLRequest(url:try endpoint("/check")); check.httpMethod="POST"; check.timeoutInterval=120; check.setValue("application/json",forHTTPHeaderField:"Content-Type"); check.httpBody=try JSONSerialization.data(withJSONObject:["relative_path":path,"filename":name,"size":bytes]); let (d,r)=try await wifiSession.data(for:check); guard (r as? HTTPURLResponse)?.statusCode==200 else{throw CopyError.receiver}; if let j=try? JSONSerialization.jsonObject(with:d) as? [String:Any], j["exists"] as? Bool == true{return true}
        var q=URLRequest(url:try endpoint("/upload")); q.httpMethod="POST"; q.timeoutInterval=3600; q.setValue(path,forHTTPHeaderField:"X-Relative-Path"); q.setValue(name,forHTTPHeaderField:"X-Filename"); q.setValue(String(bytes),forHTTPHeaderField:"X-File-Size"); q.setValue("application/octet-stream",forHTTPHeaderField:"Content-Type"); let (_,ur)=try await wifiSession.upload(for:q,fromFile:file); guard let h=ur as? HTTPURLResponse,(200...201).contains(h.statusCode) else{throw CopyError.receiver}; return false
    }
    private func endpoint(_ p:String)throws->URL { guard let u=URL(string:"http://\(receiverHost):\(receiverPort)\(p)") else{throw CopyError.receiver}; return u }
    private func album(_ id:String)->PHAssetCollection? { PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:[id],options:nil).firstObject }
    private func size(_ u:URL)->Int64 { Int64((try? u.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0) }
    private func clean(_ s:String)->String { let x=s.replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:":",with:"_").trimmingCharacters(in:.whitespacesAndNewlines); return x.isEmpty ? "Untitled" : x }
    private func retry<T>(_ phase:String,attempts:Int=3,_ operation:() async throws -> T) async throws -> T {
        var lastError:Error?
        for attempt in 1...attempts {
            if shouldStop { throw CancellationError() }
            do { return try await operation() }
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

struct TransferPhaseError: LocalizedError {
    let phase:String
    let underlying:Error
    var errorDescription:String? { "\(phase) failed after 3 attempts: \(underlying.localizedDescription)" }
}

enum CopyError: LocalizedError { case resource,receiver,write; var errorDescription:String? { switch self { case .resource:return "Photos could not provide this file."; case .receiver:return "PC receiver could not be reached."; case .write:return "Destination verification failed." } } }
