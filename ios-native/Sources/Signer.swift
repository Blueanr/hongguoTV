// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import JavaScriptCore

// Serialized on a private queue: JavaScriptCore contexts must never be entered concurrently.
final class Signer {
    private let queue = DispatchQueue(label: "com.hongguotv.signer")
    private var context: JSContext?
    private func runtime() throws -> JSContext {
        if let context = context { return context }
        guard let js = JSContext(), let url = Bundle.main.url(forResource: "signer", withExtension: "js") else { throw HGError.message("签名组件缺失，请重新安装") }
        let hash: @convention(block) (String, String) -> String = { name, input in
            Crypto.hash(name, Data(base64Encoded: input) ?? Data()).base64EncodedString()
        }
        let nonce: @convention(block) () -> String = { Crypto.random(18).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_") }
        js.setObject(hash, forKeyedSubscript: "nativeHash" as NSString)
        js.setObject(nonce, forKeyedSubscript: "nativeNonce" as NSString)
        js.evaluateScript(try String(contentsOf: url))
        guard js.exception == nil else { throw HGError.message("签名组件初始化失败") }
        context = js
        return js
    }
    func request(base: String, values: [String: String], body: Data? = nil, playback: Bool = false) async throws -> URLRequest {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let js = try self.runtime(); js.exception = nil
                    let args: [Any] = [base, values, body.map { $0.base64EncodedString() } as Any? ?? NSNull(), playback]
                    guard let result = js.objectForKeyedSubscript("hgSign")?.call(withArguments: args)?.toString(), js.exception == nil,
                          let data = result.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let path = object["url"] as? String, let url = URL(string: path), let headers = object["headers"] as? [String: String] else { throw HGError.message("请求签名失败") }
                    var request = URLRequest(url: url); request.allHTTPHeaderFields = headers
                    request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
                    continuation.resume(returning: request)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func sm3(_ text: String) throws -> String {
        try queue.sync { try runtime().objectForKeyedSubscript("hgSM3").call(withArguments: [text]).toString() }
    }
}
