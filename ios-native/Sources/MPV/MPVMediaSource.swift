// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// libmpv calls these synchronous callbacks only on its demux thread. URLSession
// and CENC work stay asynchronous; cancellation wakes the blocked reader at once.
final class MPVMediaSource: NSObject, HGMPVSource {
    let length: Int64
    private let bytes: MediaBytes
    private let condition = NSCondition()
    private var cancelled = false
    private var request: Task<Void,Never>?
    private var result: Result<Data,Error>?
    private(set) var failure: String?

    init(bytes: MediaBytes,length: Int) { self.bytes = bytes; self.length = Int64(length) }

    func read(atOffset offset: Int64,count: UInt) -> Data? {
        condition.lock(); defer { condition.unlock() }
        guard !cancelled,offset >= 0,offset <= length else { return nil }
        if offset == length || count == 0 { return Data() }
        let end = offset + min(Int64(min(count,512 * 1024)),length - offset) - 1
        result = nil
        let bytes = self.bytes
        request = Task.detached { [weak self] in
            let result: Result<Data,Error>
            do { result = .success(try await bytes.read(Int(offset),Int(end))) }
            catch { result = .failure(error) }
            self?.complete(result)
        }
        let deadline = Date().addingTimeInterval(35)
        while result == nil && !cancelled {
            if !condition.wait(until: deadline) {
                cancelled = true; failure = "mpv 解密数据读取超时"
                request?.cancel()
            }
        }
        request = nil
        guard !cancelled,let result = result else { return nil }
        switch result {
        case .success(let data): return data
        case .failure(let error): failure = error.localizedDescription; return nil
        }
    }
    private func complete(_ result: Result<Data,Error>) {
        condition.lock(); defer { condition.unlock() }
        self.result = result; condition.broadcast()
    }
    func cancel() {
        condition.lock(); defer { condition.unlock() }
        cancelled = true; request?.cancel(); condition.broadcast()
    }
}
