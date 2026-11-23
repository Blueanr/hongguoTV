// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import CommonCrypto
import Security
import zlib

enum HGError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

enum Crypto {
    static func hash(_ name: String, _ data: Data) -> Data {
        let count = name == "md5" ? 16 : (name == "sha512" ? 64 : (name == "sha1" ? 20 : 32))
        var out = [UInt8](repeating: 0, count: count)
        data.withUnsafeBytes { bytes in
            switch name {
            case "md5": _ = CC_MD5(bytes.baseAddress, CC_LONG(data.count), &out)
            case "sha1": _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &out)
            case "sha512": _ = CC_SHA512(bytes.baseAddress, CC_LONG(data.count), &out)
            default: _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &out)
            }
        }
        return Data(out)
    }
    static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        precondition(SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess)
        return Data(bytes)
    }
    static func aes(_ data: Data, key: Data, iv: Data, encrypt: Bool = false, ctr: Bool = false, padding: Bool = false, ecb: Bool = false) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw HGError.message("内容密钥格式异常") }
        var ref: CCCryptorRef?
        let status = key.withUnsafeBytes { k in iv.withUnsafeBytes { v in
            CCCryptorCreateWithMode(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCMode(ecb ? kCCModeECB : (ctr ? kCCModeCTR : kCCModeCBC)), CCAlgorithm(kCCAlgorithmAES), CCPadding(padding ? ccPKCS7Padding : ccNoPadding), v.baseAddress, k.baseAddress, key.count, nil, 0, 0, CCModeOptions(ctr ? kCCModeOptionCTR_BE : 0), &ref)
        }}
        guard status == kCCSuccess, let ref = ref else { throw HGError.message("无法初始化视频解码") }
        defer { CCCryptorRelease(ref) }
        var out = [UInt8](repeating: 0, count: data.count + 32), written = 0, final = 0
        let update = data.withUnsafeBytes { bytes in
            CCCryptorUpdate(ref, bytes.baseAddress, data.count, &out, out.count, &written)
        }
        let finish = out.withUnsafeMutableBytes { bytes in
            CCCryptorFinal(ref, bytes.baseAddress!.advanced(by: written), bytes.count - written, &final)
        }
        guard update == kCCSuccess, finish == kCCSuccess else { throw HGError.message("视频数据解码失败") }
        return Data(out.prefix(written + final))
    }
    static func gzip(_ data: Data, window: Int32 = 31) throws -> Data {
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, window, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw HGError.message("压缩初始化失败") }
        defer { deflateEnd(&stream) }
        var out = [UInt8](repeating: 0, count: Int(deflateBound(&stream, uLong(data.count))))
        let code = data.withUnsafeBytes { bytes -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return out.withUnsafeMutableBytes { dest in
                stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress
                stream.avail_out = uInt(dest.count)
                return deflate(&stream, Z_FINISH)
            }
        }
        guard code == Z_STREAM_END else { throw HGError.message("压缩失败") }
        return Data(out.prefix(Int(stream.total_out)))
    }
    static let salt = Data(hex: "4dd4c2e6b83162090e52b3c7a6733ba41cb2462b829ab58a196b39db57177524f49baf7f08e8d68d26a72e37c1a95a2f1f05a51892aef2949732b62a38aadd58")!
    static func inflate(_ data: Data, window: Int32 = 15, limit: Int = 65536) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream,window,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw HGError.message("解压初始化失败") }
        defer { inflateEnd(&stream) }
        var out = [UInt8](repeating: 0,count: limit + 1)
        let code = data.withUnsafeBytes { bytes -> Int32 in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: UInt8.self).baseAddress)
            stream.avail_in = uInt(data.count)
            return out.withUnsafeMutableBytes { dest in
                stream.next_out = dest.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(dest.count)
                return zlib.inflate(&stream,Z_FINISH)
            }
        }
        guard code == Z_STREAM_END,stream.avail_in == 0,stream.total_out <= limit else { throw HGError.message("压缩数据不完整或超出限制") }
        return Data(out.prefix(Int(stream.total_out)))
    }
    static func encryptRegistration(_ data: Data) throws -> Data {
        let seed = random(32), derived = hash("sha512", hash("sha512", seed) + salt)
        return Data([0x74,0x63,5,0x10,0,0]) + seed + (try aes(hash("sha512", data) + data, key: Data(derived.prefix(16)), iv: Data(derived[16..<32]), encrypt: true, padding: true))
    }
    static func contentKey(_ value: String) throws -> Data {
        guard let raw = Data(base64URL: value), raw.count >= 3 else { throw HGError.message("内容密钥无效") }
        let length = min(raw.count - Int(raw[0] ^ raw[1] ^ raw[2]) + 47, raw.count - 1)
        guard length >= 33 else { throw HGError.message("内容密钥截断") }
        var bytes = Array(raw[1...length]), a = 85, b = 246
        for i in bytes.indices {
            let old = Int(bytes[i]), previous = i & 1 != 0 ? a : b
            if i & 1 != 0 { a = old } else { b = old }
            bytes[i] = UInt8(truncatingIfNeeded: -21 - i.nonzeroBitCount + (previous ^ old))
        }
        guard let text = String(bytes: bytes[1..<33], encoding: .ascii), let key = Data(hex: text), key.count == 16 else { throw HGError.message("内容密钥格式异常") }
        return key
    }
    static func mediaURL(_ value: String, seed: String) throws -> URL {
        if let url = URL(string: value), ["https", "http"].contains(url.scheme) { return url }
        guard let raw = Data(base64URL: value) else { throw HGError.message("播放地址无效") }
        var decoded = raw
        if !seed.isEmpty, let seed = Data(base64URL: seed) {
            guard raw.count >= 20, raw[0] == 0xa8, raw[2] == 1, raw[3] == 0 else { throw HGError.message("播放地址格式异常") }
            let derived = hash("sha512", hash("sha512", seed) + salt)
            decoded = try aes(Data(raw[4..<(4 + (raw.count - 4) / 16 * 16)]), key: Data(derived.prefix(16)), iv: Data(derived[16..<32]), padding: true)
        }
        guard let text = String(data: decoded, encoding: .utf8), let url = URL(string: text.trimmingCharacters(in: .controlCharacters)), ["https", "http"].contains(url.scheme) else { throw HGError.message("播放地址无效") }
        return url
    }
}
extension Data {
    init?(hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8](); var at = hex.startIndex
        while at < hex.endIndex {
            let end = hex.index(at, offsetBy: 2)
            guard let byte = UInt8(hex[at..<end], radix: 16) else { return nil }
            out.append(byte); at = end
        }
        self.init(out)
    }
    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
