import Foundation

final class BackgroundUploadCoordinator: NSObject, URLSessionTaskDelegate, URLSessionDelegate {
    static let shared = BackgroundUploadCoordinator()
    static let sessionIdentifier = "com.paritosh.PhotoUSBBackup.backgroundUploads"

    struct UploadMetadata: Codable, Equatable {
        let relativePath: String
        let filename: String
        let byteCount: Int64
        let localFilePath: String

        var displayPath: String { relativePath + "/" + filename }
    }

    enum Event {
        case restored(pending: Int, paused: Bool)
        case progress(metadata: UploadMetadata, sent: Int64, expected: Int64, pending: Int)
        case completed(metadata: UploadMetadata, success: Bool, message: String?, pending: Int)
        case queueState(paused: Bool, pending: Int)
        case stopped(cancelled: Int)
    }

    var eventHandler: ((Event) -> Void)?
    private var systemCompletionHandler: (() -> Void)?
    private var userCancelledTaskIDs = Set<Int>()

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = false
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.timeoutIntervalForRequest = 3600
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()

    private override init() {
        super.init()
    }

    func restoreTasks() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                let active = tasks.filter { $0.state != .completed }
                let paused = !active.isEmpty && active.allSatisfy { $0.state == .suspended }
                self?.eventHandler?(.restored(pending: active.count, paused: paused))
            }
        }
    }

    func pauseAll() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                let active = tasks.filter { $0.state != .completed }
                active.forEach { $0.suspend() }
                self?.eventHandler?(.queueState(paused: true, pending: active.count))
            }
        }
    }

    func resumeAll() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                let active = tasks.filter { $0.state != .completed }
                active.forEach { $0.resume() }
                self?.eventHandler?(.queueState(paused: false, pending: active.count))
            }
        }
    }

    func cancelAll() {
        session.getAllTasks { [weak self] tasks in
            DispatchQueue.main.async {
                guard let self else { return }
                let active = tasks.filter { $0.state != .completed }
                for task in active {
                    self.userCancelledTaskIDs.insert(task.taskIdentifier)
                    if let metadata = self.metadata(for: task) {
                        try? FileManager.default.removeItem(atPath: metadata.localFilePath)
                    }
                    task.cancel()
                }
                self.eventHandler?(.stopped(cancelled: active.count))
            }
        }
    }

    func contains(relativePath: String, filename: String) async -> Bool {
        let tasks = await allTasks()
        return tasks.contains { task in
            guard task.state != .completed, let metadata = metadata(for: task) else { return false }
            return metadata.relativePath == relativePath && metadata.filename == filename
        }
    }

    @discardableResult
    func enqueue(fileURL: URL, endpoint: URL, relativePath: String, filename: String, byteCount: Int64) -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.setValue(relativePath, forHTTPHeaderField: "X-Relative-Path")
        request.setValue(filename, forHTTPHeaderField: "X-Filename")
        request.setValue(String(byteCount), forHTTPHeaderField: "X-File-Size")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let metadata = UploadMetadata(
            relativePath: relativePath,
            filename: filename,
            byteCount: byteCount,
            localFilePath: fileURL.path
        )
        let task = session.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = encode(metadata)
        task.countOfBytesClientExpectsToSend = byteCount
        task.countOfBytesClientExpectsToReceive = 512
        task.resume()
        return task.taskIdentifier
    }

    func setSystemCompletionHandler(_ handler: @escaping () -> Void) {
        systemCompletionHandler = handler
        _ = session
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        guard let metadata = metadata(for: task) else { return }
        pendingCount { [weak self] pending in
            self?.eventHandler?(.progress(
                metadata: metadata,
                sent: totalBytesSent,
                expected: max(totalBytesExpectedToSend, metadata.byteCount),
                pending: pending
            ))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if userCancelledTaskIDs.remove(task.taskIdentifier) != nil { return }
        guard let metadata = metadata(for: task) else { return }
        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let success = error == nil && statusCode.map { (200...299).contains($0) } == true
        let message: String?
        if let error {
            message = error.localizedDescription
        } else if let statusCode, !success {
            message = "PC receiver returned HTTP \(statusCode)."
        } else {
            message = nil
        }

        try? FileManager.default.removeItem(atPath: metadata.localFilePath)
        pendingCount { [weak self] pending in
            self?.eventHandler?(.completed(metadata: metadata, success: success, message: message, pending: pending))
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = systemCompletionHandler
        systemCompletionHandler = nil
        handler?()
    }

    private func allTasks() async -> [URLSessionTask] {
        await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
    }

    private func pendingCount(_ completion: @escaping (Int) -> Void) {
        session.getAllTasks { tasks in
            DispatchQueue.main.async {
                completion(tasks.filter { $0.state != .completed }.count)
            }
        }
    }

    private func metadata(for task: URLSessionTask) -> UploadMetadata? {
        guard let text = task.taskDescription, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(UploadMetadata.self, from: data)
    }

    private func encode(_ metadata: UploadMetadata) -> String? {
        guard let data = try? JSONEncoder().encode(metadata) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
