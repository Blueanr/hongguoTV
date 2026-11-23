// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Openhongguo

// One persistent anonymous SDK client across episodes/repositories. SDK owns
// registration, signatures, bounded device recovery and request cancellation.
actor SDKPlayback {
    static let shared = SDKPlayback()
    private var client: OpenhongguoClient?
    private func sdk() throws -> OpenhongguoClient {
        if let client = client { return client }
        let value = try OpenhongguoClient.create(options: ClientOptions(retryAttempts: 3,deviceResets: 2))
        client = value
        return value
    }
    func streams(_ id: String) async throws -> [Rendition] {
        guard id.range(of: "^[0-9]{1,30}$",options: .regularExpression) != nil else { throw HGError.message("分集编号无效") }
        try Task.checkCancellation()
        let client = try sdk()
        do {
            return try await withThrowingTaskGroup(of: [Rendition].self) { group in
                group.addTask {
                    let result = try await client.resolvePlayback(id)
                    try Task.checkCancellation()
                    return try Self.renditions(result.playback,key: result.contentKey,episode: id)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    throw HGError.message("播放解析超时，请重试")
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
        } catch is CancellationError { throw CancellationError() }
        catch let error as OpenhongguoError { throw HGError.message(Self.message(error)) }
    }
    static func renditions(_ playback: Openhongguo.Playback,key: Openhongguo.ContentKey?,episode: String) throws -> [Rendition] {
        guard playback.episodeId == episode else { throw HGError.message("SDK 返回了不匹配的分集") }
        let decodedKey = key.flatMap { Data(hex: $0.key) }.flatMap { $0.count == 16 ? $0 : nil }
        var missingKey = false
        let rows: [Rendition] = playback.streams.compactMap { stream in
            let codec = stream.codec.lowercased()
            guard !codec.contains("bytevc2"), !codec.contains("bvc2"), !stream.dash, !stream.hls else { return nil }
            let encrypted = stream.protected || playback.protected
            if encrypted && decodedKey == nil { missingKey = true; return nil }
            guard !encrypted || stream.encryption.isEmpty || stream.encryption == "cenc-aes-ctr" else { return nil }
            let url = [stream.url,stream.backupUrl].compactMap { URL(string: $0) }.first {
                ["http","https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.user == nil && $0.password == nil
            }
            guard let url = url else { return nil }
            let dimension = min(stream.width,stream.height)
            let label = stream.definition.isEmpty ? stream.quality : stream.definition
            let quality = [2160,1440,1080,720,540,480,360,240].first { label.contains(String($0)) } ?? max(0,dimension)
            return Rendition(url: url,key: encrypted ? decodedKey : nil,quality: quality,codec: codec)
        }.sorted { $0.quality > $1.quality }
        guard !rows.isEmpty else { throw HGError.message(missingKey ? "SDK 未能取得有效内容密钥，请重试" : "SDK 未返回兼容的 MP4 播放资源") }
        return rows
    }
    static func message(_ error: OpenhongguoError) -> String {
        switch error.code {
        case .anonymousLimited: return "播放接口仍返回空结果（SDK 已完成有限重试），请稍后再试"
        case .deviceRejected: return "播放设备被拒绝（SDK 已尝试恢复），请稍后再试"
        case .rateLimited: return "播放服务限流，请稍后再试\(error.retryAfterMs > 0 ? "（建议等待 \(max(1,error.retryAfterMs / 1000)) 秒）" : "")"
        case .authenticationRequired: return "此内容需要登录授权，匿名 SDK 无法播放"
        case .challengeRequired: return "服务端要求验证，匿名 SDK 无法继续"
        case .contentUnavailable: return "此分集暂不可用或已下架"
        case .signatureRejected, .signerUnavailable: return "播放 SDK 签名暂不可用，请稍后再试"
        case .transport: return "播放网络请求失败，请检查网络后重试"
        default: return "播放解析失败（\(error.code.rawValue)）"
        }
    }
}
