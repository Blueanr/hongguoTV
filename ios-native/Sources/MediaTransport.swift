// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Persistent CDN connections with chunk callbacks: avoid one async iteration
// and Data append for every video byte on older iPads.
final class MediaTransport: NSObject, URLSessionDataDelegate {
    static let shared = MediaTransport()
    private final class Transfer {
        let limit: Int
        let continuation: CheckedContinuation<(Data,HTTPURLResponse),Error>
        var response: HTTPURLResponse?
        var bytes = Data()
        init(limit: Int,continuation: CheckedContinuation<(Data,HTTPURLResponse),Error>) {
            self.limit = limit; self.continuation = continuation
        }
    }
    private final class Cancellation {
        private let lock = NSLock()
        private var cancelled = false
        private var task: URLSessionDataTask?
        func start(_ task: URLSessionDataTask) {
            lock.lock(); defer { lock.unlock() }
            self.task = task
            if cancelled { task.cancel() } else { task.resume() }
        }
        func cancel() {
            lock.lock(); defer { lock.unlock() }
            cancelled = true; task?.cancel()
        }
    }
    private let lock = NSLock()
    private var transfers: [Int:Transfer] = [:]
    private var session: URLSession!
    init(configuration: URLSessionConfiguration = .ephemeral) {
        super.init()
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 45
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration,delegate: self,delegateQueue: queue)
    }
    func invalidate() { session.invalidateAndCancel() }
    func data(_ request: URLRequest,limit: Int) async throws -> (Data,HTTPURLResponse) {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: request)
                lock.lock()
                transfers[task.taskIdentifier] = Transfer(limit: limit,continuation: continuation)
                lock.unlock()
                cancellation.start(task)
            }
        },onCancel: { cancellation.cancel() })
    }
    private func transfer(_ task: URLSessionTask) -> Transfer? {
        lock.lock(); defer { lock.unlock() }; return transfers[task.taskIdentifier]
    }
    private func finish(_ task: URLSessionTask,_ result: Result<(Data,HTTPURLResponse),Error>) {
        lock.lock(); let transfer = transfers.removeValue(forKey: task.taskIdentifier); lock.unlock()
        transfer?.continuation.resume(with: result)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let transfer = transfer(dataTask) else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse,response.statusCode == 206 else {
            completionHandler(.cancel); finish(dataTask,.failure(HGError.message("视频服务器未返回分段响应"))); return
        }
        guard transfer.limit >= 0,response.expectedContentLength <= transfer.limit else {
            completionHandler(.cancel); finish(dataTask,.failure(HGError.message("视频分段超过大小限制"))); return
        }
        transfer.response = response
        transfer.bytes.reserveCapacity(min(transfer.limit,max(0,Int(response.expectedContentLength))))
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        guard let transfer = transfer(dataTask) else { return }
        guard data.count <= transfer.limit - transfer.bytes.count else {
            finish(dataTask,.failure(HGError.message("视频分段超过大小限制"))); dataTask.cancel(); return
        }
        transfer.bytes.append(data)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        guard let transfer = transfer(task) else { return }
        if let error = error {
            finish(task,.failure((error as NSError).code == NSURLErrorCancelled ? CancellationError() : error)); return
        }
        guard let response = transfer.response else { finish(task,.failure(HGError.message("视频响应无效"))); return }
        finish(task,.success((transfer.bytes,response)))
    }
}
