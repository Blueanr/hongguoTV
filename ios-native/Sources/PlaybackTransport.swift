// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Use the completion/delegate data-task API for body-bearing playback requests.
// This avoids the AsyncBytes POST path on early iOS 15 while preserving the
// exact URL, headers and encrypted/signed body. No automatic application retry.
enum PlaybackTransport {
    static func data(_ request: URLRequest,limit: Int,
                     configuration: URLSessionConfiguration = .ephemeral) async throws -> (Data,HTTPURLResponse) {
        let transfer = PlaybackTransfer(limit: limit)
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                transfer.start(request,configuration: configuration,continuation: continuation)
            }
        },onCancel: { transfer.cancel() })
    }
}

private final class PlaybackTransfer: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private let limit: Int
    private var cancelled = false
    private var finished = false
    private var continuation: CheckedContinuation<(Data,HTTPURLResponse),Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    // Delegate callbacks use a serial operation queue.
    private var response: HTTPURLResponse?
    private var bytes = Data()

    init(limit: Int) { self.limit = limit }
    func start(_ request: URLRequest,configuration: URLSessionConfiguration,
               continuation: CheckedContinuation<(Data,HTTPURLResponse),Error>) {
        lock.lock()
        guard !cancelled else {
            lock.unlock(); continuation.resume(throwing: CancellationError()); return
        }
        self.continuation = continuation
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 45
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: configuration,delegate: self,delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session; self.task = task
        task.resume()
        lock.unlock()
    }
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<(Data,HTTPURLResponse),Error>) {
        lock.lock()
        guard !finished,let continuation = continuation else { lock.unlock(); return }
        finished = true; self.continuation = nil
        let session = self.session; self.session = nil; task = nil
        let wasCancelled = cancelled
        lock.unlock()
        session?.invalidateAndCancel()
        continuation.resume(with: wasCancelled ? .failure(CancellationError()) : result)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); finish(.failure(HGError.message("播放服务响应无效"))); return
        }
        guard [200,206].contains(http.statusCode) else {
            completionHandler(.cancel)
            finish(.failure(HGError.message("播放服务请求失败（HTTP \(http.statusCode)）"))); return
        }
        guard limit >= 0,response.expectedContentLength <= limit else {
            completionHandler(.cancel); finish(.failure(HGError.message("播放服务响应超出限制"))); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession,dataTask: URLSessionDataTask,didReceive data: Data) {
        guard data.count <= limit - bytes.count else {
            finish(.failure(HGError.message("播放服务响应超出限制"))); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,didCompleteWithError error: Error?) {
        if let error = error { finish(.failure(error)); return }
        guard let response = response else { finish(.failure(HGError.message("播放服务响应无效"))); return }
        finish(.success((bytes,response)))
    }
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) {
        // The URL/body are signed together; do not transform a POST on redirect.
        completionHandler(nil)
    }
}
