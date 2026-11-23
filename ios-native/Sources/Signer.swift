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
        let aes: @convention(block) (String,String,String) -> String = { input,key,iv in
            guard let input = Data(base64Encoded: input),let key = Data(base64Encoded: key),let iv = Data(base64Encoded: iv),let out = try? Crypto.aes(input,key: key,iv: iv,encrypt: true,padding: true) else { return "" }
            return out.base64EncodedString()
        }
        js.setObject(aes,forKeyedSubscript: "nativeAES" as NSString)
        let sessionAES: @convention(block) (String,String,String,Bool,Bool) -> String = { input,key,iv,encrypt,ecb in
            guard let data = Data(base64Encoded: input),let key = Data(base64Encoded: key),let iv = Data(base64Encoded: iv),
                  let output = try? Crypto.aes(data,key: key,iv: iv,encrypt: encrypt,padding: true,ecb: ecb) else { return "" }
            return output.base64EncodedString()
        }
        let sessionZip: @convention(block) (String,Bool) -> String = { input,inflate in
            guard let data = Data(base64Encoded: input),data.count <= 131072,
                  let output = try? (inflate ? Crypto.inflate(data) : Crypto.gzip(data,window: 15)) else { return "" }
            return output.base64EncodedString()
        }
        js.setObject(sessionAES,forKeyedSubscript: "nativeSessionAES" as NSString)
        js.setObject(sessionZip,forKeyedSubscript: "nativeSessionZip" as NSString)
        js.evaluateScript(try String(contentsOf: url))
        guard js.exception == nil else { throw HGError.message("签名组件初始化失败") }
        context = js
        return js
    }
    func request(base: String, values: [String: String], body: Data? = nil, playback: Bool = false, mobileV5: Bool = false) async throws -> URLRequest {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let js = try self.runtime(); js.exception = nil
                    let args: [Any] = mobileV5 ? [base,values,(body ?? Data()).base64EncodedString()] : [base, values, body.map { $0.base64EncodedString() } as Any? ?? NSNull(), playback]
                    guard let result = js.objectForKeyedSubscript(mobileV5 ? "hgSignV5" : "hgSign")?.call(withArguments: args)?.toString(), js.exception == nil,
                          let data = result.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let path = object["url"] as? String, let url = URL(string: path), let headers = object["headers"] as? [String: String] else { throw HGError.message("请求签名失败") }
                    var request = URLRequest(url: url); request.allHTTPHeaderFields = headers
                    request.httpMethod = body == nil ? "GET" : "POST"; request.httpBody = body
                    if mobileV5 {
                        request.httpShouldHandleCookies = false
                        request.setValue(nil,forHTTPHeaderField: "Cookie")
                        if body == nil {
                            for name in ["Content-Type","Content-Encoding","x-ss-stub"] { request.setValue(nil,forHTTPHeaderField: name) }
                        }
                    }
                    continuation.resume(returning: request)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func sm3(_ text: String) throws -> String {
        try queue.sync { try runtime().objectForKeyedSubscript("hgSM3").call(withArguments: [text]).toString() }
    }
    func dramaCall(_ name: String,_ arguments: [Any]) async throws -> String {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let js = try self.runtime(); js.exception = nil
                    guard let value = js.objectForKeyedSubscript(name)?.call(withArguments: arguments)?.toString(),js.exception == nil else { throw HGError.message("播放会话协议处理失败") }
                    continuation.resume(returning: value)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    func singleRequest(id: String,profile: [String:String]) async throws -> URLRequest {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let allowed: Set<String> = ["ac","channel","aid","app_name","version_code","version_name","device_platform","os","ssmix","device_type","device_brand","language","os_api","os_version","manifest_version_code","resolution","dpi","update_version_code","device_id","iid"]
                    var values = profile.filter { allowed.contains($0.key) }
                    let now = Int64(Date().timeIntervalSince1970 * 1000)
                    values.merge(["version_code":"73532","version_name":"7.3.5.32","manifest_version_code":"73532","update_version_code":"73532","_rticket":String(now)]) { _,n in n }
                    let query = values.keys.sorted().map { Repository.encode($0) + "=" + Repository.encode(values[$0]!) }.joined(separator: "&")
                    let payload: JSON = ["biz_param":["need_all_video_definition":true,"video_platform":3],"content_type":1,"video_id":id]
                    let body = try JSONSerialization.data(withJSONObject: payload)
                    let js = try self.runtime(); js.exception = nil
                    guard let result = js.objectForKeyedSubscript("hgPlayerHeaders")?.call(withArguments: [query,body.base64EncodedString(),profile["device_id"] ?? "",now,Crypto.random(11).base64EncodedString()])?.toString(),js.exception == nil,
                          let data = result.data(using: .utf8),let headers = try JSONSerialization.jsonObject(with: data) as? [String:String] else { throw HGError.message("播放签名失败") }
                    var request = URLRequest(url: URL(string: "https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_model/v1/?" + query)!)
                    request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
                    request.allHTTPHeaderFields = headers.merging(["User-Agent":"com.phoenix.read/73532 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)","Content-Type":"application/json; charset=utf-8","Accept":"application/json","Sdk-Version":"2","X-XS-From-Web":"0"]) { _,n in n }
                    continuation.resume(returning: request)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
