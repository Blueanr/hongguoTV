// SPDX-License-Identifier: GPL-3.0-only
// Port of MediaCrypto.prepare/decryptPartial. AVFoundation requests decrypted byte ranges on demand.
import Foundation
import AVFoundation
import UniformTypeIdentifiers

struct MP4Index {
    struct Box { let start: Int; let body: Int; let end: Int; let type: String }
    struct Sample { let start: Int; let end: Int; let iv: Data; let encryptedOffset: Int }
    let header: Data
    let samples: [Sample]
    init(header: Data,samples: [Sample]) { self.header = header; self.samples = samples.sorted { $0.start < $1.start } }
    static func uint(_ data: Data, _ at: Int, _ width: Int = 4) throws -> Int {
        guard at >= 0, width > 0, at <= data.count - width else { throw HGError.message("视频索引截断") }
        var value: UInt64 = 0
        for byte in data[at..<(at + width)] { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int.max) else { throw HGError.message("视频索引越界") }
        return Int(value)
    }
    static func box(_ data: Data, _ at: Int, _ limit: Int) throws -> Box {
        guard at >= 0, at + 8 <= limit, limit <= data.count else { throw HGError.message("视频容器截断") }
        var length = try uint(data, at), header = 8
        if length == 1 { length = try uint(data, at + 8, 8); header = 16 }
        if length == 0 { length = limit - at }
        guard length >= header, length <= limit - at else { throw HGError.message("视频容器越界") }
        return Box(start: at, body: at + header, end: at + length, type: String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self))
    }
    static func find(_ data: Data, _ type: String, _ start: Int, _ end: Int) -> Box? {
        guard start >= 0, end <= data.count, start <= end - 8 else { return nil }
        for at in start...(end - 8) where String(decoding: data[(at + 4)..<(at + 8)], as: UTF8.self) == type {
            if let box = try? box(data, at, end) { return box }
        }
        return nil
    }
    static func headerLength(_ data: Data, total: Int) throws -> Int {
        let ftyp = try box(data, 0, data.count)
        guard ftyp.type == "ftyp", ftyp.end + 8 <= data.count,
              String(decoding: data[(ftyp.end + 4)..<(ftyp.end + 8)], as: UTF8.self) == "moov" else { throw HGError.message("视频索引不在文件开头") }
        let end = try uint(data, ftyp.end) + ftyp.end
        guard end > ftyp.end + 8, end <= total, end <= 8 * 1024 * 1024 else { throw HGError.message("视频索引大小异常") }
        return end
    }
    init(data: Data, encrypted: Bool) throws {
        guard encrypted else { header = data; samples = []; return }
        var patched = data, result: [Sample] = []
        let moov = try Self.box(data, Self.uint(data, 0), data.count)
        guard moov.type == "moov" else { throw HGError.message("视频索引缺失") }
        var cursor = moov.body
        while cursor < moov.end {
            let track = try Self.box(data, cursor, moov.end); cursor = track.end
            guard track.type == "trak", let table = Self.find(data,"stbl",track.body,track.end), let saiz = Self.find(data,"saiz",table.body,table.end) else { continue }
            guard let saio = Self.find(data,"saio",table.body,table.end), let stsz = Self.find(data,"stsz",table.body,table.end), let stsc = Self.find(data,"stsc",table.body,table.end), let chunks = Self.find(data,"stco",table.body,table.end) ?? Self.find(data,"co64",table.body,table.end) else { throw HGError.message("视频样本索引缺失") }
            func number(_ box: Box, _ at: Int, _ width: Int = 4) throws -> Int {
                guard at >= box.body, at <= box.end - width else { throw HGError.message("视频索引越界") }
                return try Self.uint(data, at, width)
            }
            func count(_ box: Box, _ at: Int) throws -> Int {
                let n = try number(box, at); guard n <= 200_000 else { throw HGError.message("视频样本过多") }; return n
            }
            let n = try count(stsz, stsz.body + 8), defaultSize = try number(stsz,stsz.body + 4)
            let sizes = try (0..<n).map { defaultSize > 0 ? defaultSize : try number(stsz,stsz.body + 12 + $0 * 4) }
            let chunkCount = try count(chunks,chunks.body + 4), width = chunks.type == "co64" ? 8 : 4
            let offsets = try (0..<chunkCount).map { try number(chunks,chunks.body + 8 + $0 * width,width) }
            let entryCount = try count(stsc,stsc.body + 4)
            guard entryCount > 0 else { throw HGError.message("视频块索引为空") }
            let entries = try (0..<entryCount).map { (try number(stsc,stsc.body + 8 + $0 * 12), try number(stsc,stsc.body + 12 + $0 * 12)) }
            let sizeBase = saiz.body + 4 + ((try number(saiz,saiz.body) & 1) != 0 ? 8 : 0)
            let auxDefault = try number(saiz,sizeBase,1), auxCount = try count(saiz,sizeBase + 1)
            guard auxCount == n else { throw HGError.message("加密索引数量不一致") }
            let auxSizes = try (0..<n).map { auxDefault > 0 ? auxDefault : try number(saiz,sizeBase + 5 + $0,1) }
            let offsetBase = saio.body + 4 + ((try number(saio,saio.body) & 1) != 0 ? 8 : 0)
            guard try count(saio,offsetBase) == 1 else { throw HGError.message("加密索引布局不支持") }
            var aux = try number(saio,offsetBase + 4, data[saio.body] == 1 ? 8 : 4)
            guard aux <= data.count, auxSizes.reduce(0,+) <= data.count - aux else { throw HGError.message("加密辅助数据越界") }
            var sampleIndex = 0, entry = 0
            for chunk in offsets.indices {
                while entry + 1 < entries.count && entries[entry + 1].0 <= chunk + 1 { entry += 1 }
                let count = entries[entry].1
                guard count <= n - sampleIndex, entries[entry].0 <= chunk + 1 else { throw HGError.message("样本与块数量不一致") }
                var position = offsets[chunk]
                for _ in 0..<count {
                    let length = sizes[sampleIndex], auxSize = auxSizes[sampleIndex]
                    guard length > 0, position <= Int.max - length, auxSize >= 8 else { throw HGError.message("视频样本格式异常") }
                    let iv = Data(data[aux..<(aux + 8)]) + Data(repeating: 0, count: 8)
                    if auxSize == 8 { result.append(Sample(start: position,end: position + length,iv: iv,encryptedOffset: 0)) }
                    else {
                        let subs = try Self.uint(data,aux + 8,2)
                        guard auxSize == 10 + subs * 6 else { throw HGError.message("加密子样本格式异常") }
                        var offset = position, encrypted = 0
                        for sub in 0..<subs {
                            let at = aux + 10 + sub * 6, clear = try Self.uint(data,at,2), size = try Self.uint(data,at + 2)
                            guard clear <= position + length - offset else { throw HGError.message("视频子样本越界") }
                            offset += clear
                            guard size <= position + length - offset else { throw HGError.message("视频子样本越界") }
                            if size > 0 { result.append(Sample(start: offset,end: offset + size,iv: iv,encryptedOffset: encrypted)) }
                            offset += size; encrypted += size
                        }
                        guard offset == position + length else { throw HGError.message("视频子样本长度异常") }
                    }
                    position += length; aux += auxSize; sampleIndex += 1
                }
            }
            guard sampleIndex == n else { throw HGError.message("视频样本不完整") }
            var at = table.body
            while let sinf = Self.find(data,"sinf",at,table.end) {
                guard let frma = Self.find(data,"frma",sinf.body,sinf.end), frma.body + 4 <= frma.end else { throw HGError.message("原始编码缺失") }
                var search = sinf.start - 1
                while search >= table.body {
                    let type = String(decoding: data[search..<(search + 4)], as: UTF8.self)
                    if type == "encv" || type == "enca" { patched.replaceSubrange(search..<(search + 4), with: data[frma.body..<(frma.body + 4)]); break }
                    search -= 1
                }
                patched.replaceSubrange((sinf.start + 4)..<(sinf.start + 8), with: Data("free".utf8)); at = sinf.end
                patched.replaceSubrange(sinf.body..<sinf.end,with: Data(repeating: 0,count: sinf.end - sinf.body))
            }
        }
        let sorted = result.sorted { $0.start < $1.start }
        guard !sorted.isEmpty, !zip(sorted,sorted.dropFirst()).contains(where: { $0.end > $1.start }) else { throw HGError.message("视频加密索引不可用或样本重叠") }
        header = patched; samples = sorted
    }
    func decrypt(_ data: Data, start: Int, key: Data?) throws -> Data {
        var out = data; let end = start + data.count
        if let key = key {
            for sample in samples {
                if sample.start >= end { break }
                if sample.end <= start { continue }
                let lower = max(start,sample.start), upper = min(end,sample.end)
                let encryptedOffset = sample.encryptedOffset + lower - sample.start
                var iv = Array(sample.iv), carry = encryptedOffset / 16
                for i in stride(from: 15, through: 0, by: -1) {
                    let value = Int(iv[i]) + (carry & 255); iv[i] = UInt8(value & 255); carry = (carry >> 8) + (value >> 8)
                }
                let skip = encryptedOffset % 16
                let bytes = Data(repeating: 0,count: skip) + Data(data[(lower - start)..<(upper - start)])
                let plain = try Crypto.aes(bytes,key: key,iv: Data(iv),ctr: true)
                out.replaceSubrange((lower - start)..<(upper - start),with: plain.dropFirst(skip))
            }
        }
        if start < header.count {
            let upper = min(end,header.count)
            out.replaceSubrange(0..<(upper - start),with: header[start..<upper])
        }
        return out
    }
}

actor MediaBytes {
    let rendition: Rendition
    private var prepared: (MP4Index,Int)?
    init(_ rendition: Rendition) { self.rendition = rendition }
    private func remote(_ start: Int, _ end: Int) async throws -> (Data,Int) {
        var request = URLRequest(url: rendition.url)
        request.setValue("bytes=\(start)-\(end)",forHTTPHeaderField: "Range")
        request.setValue(Repository.appUA,forHTTPHeaderField: "User-Agent")
        let (bytes,response) = try await HTTP.shared.data(request,limit: end - start + 1)
        guard response.statusCode == 206, let range = response.value(forHTTPHeaderField: "Content-Range"),
              let total = Int(range.split(separator: "/").last ?? ""),
              range.hasPrefix("bytes \(start)-"), total > end, bytes.count == end - start + 1 else { throw HGError.message("视频服务器未返回有效分段") }
        return (bytes,total)
    }
    func prepare() async throws -> (MP4Index,Int) {
        if let prepared = prepared { return prepared }
        let (first,total) = try await remote(0,1023)
        let end = try MP4Index.headerLength(first,total: total)
        let header: Data
        if end <= first.count { header = Data(first.prefix(end)) }
        else { let (rest,_) = try await remote(first.count,end - 1); header = first + rest }
        let result = (try MP4Index(data: header,encrypted: rendition.key != nil),total)
        prepared = result; return result
    }
    func read(_ start: Int, _ end: Int) async throws -> Data {
        let (index,total) = try await prepare()
        guard start >= 0, start <= end, end < total else { throw HGError.message("播放请求越界") }
        let (data,_) = try await remote(start,end)
        return try index.decrypt(data,start: start,key: rendition.key)
    }
}

final class MediaResource: NSObject, AVAssetResourceLoaderDelegate {
    let queue = DispatchQueue(label: "com.hongguotv.media-loader")
    let bytes: MediaBytes
    private var tasks: [ObjectIdentifier: Task<Void,Never>] = [:]
    private let diagnosticLock = NSLock()
    private var requestCount = 0
    private var deliveredBytes = 0
    private var lastFailure: String?
    var diagnostic: String {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        return lastFailure ?? "资源加载器：\(requestCount) 次请求，已交付 \(deliveredBytes) 字节"
    }
    private func record(request: Bool = false,bytes: Int = 0,failure: String? = nil) {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        if request { requestCount += 1 }; deliveredBytes += bytes
        if let failure = failure { lastFailure = failure }
    }
    init(_ rendition: Rendition) { bytes = MediaBytes(rendition) }
    func asset() -> AVURLAsset {
        let asset = AVURLAsset(url: URL(string: "hongguo-media://episode/\(UUID().uuidString).mp4")!)
        asset.resourceLoader.setDelegate(self,queue: queue)
        return asset
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        record(request: true)
        let id = ObjectIdentifier(request)
        tasks[id] = Task {
            var stage = "CDN 视频索引读取／解析"
            do {
                let (_,total) = try await bytes.prepare()
                let info = request.contentInformationRequest
                info?.contentType = UTType.mpeg4Movie.identifier
                info?.contentLength = Int64(total); info?.isByteRangeAccessSupported = true
                if let data = request.dataRequest {
                    var at = Int(max(data.requestedOffset,data.currentOffset))
                    let end = data.requestsAllDataToEndOfResource ? total : min(total,Int(data.requestedOffset) + data.requestedLength)
                    while at < end {
                        try Task.checkCancellation()
                        let upper = min(end,at + 512 * 1024)
                        stage = "CDN 视频分段读取／解密"
                        let chunk = try await bytes.read(at,upper - 1)
                        try Task.checkCancellation(); data.respond(with: chunk); at = upper
                        record(bytes: chunk.count)
                    }
                }
                if !Task.isCancelled { request.finishLoading() }
            } catch {
                if !Task.isCancelled {
                    let failure = PlaybackFailure(stage: stage,cause: error)
                    record(failure: failure.localizedDescription)
                    request.finishLoading(with: error)
                }
            }
            queue.async { self.tasks.removeValue(forKey: id) }
        }
        return true
    }
    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) { tasks.removeValue(forKey: ObjectIdentifier(request))?.cancel() }
    func cancel() { queue.async { self.tasks.values.forEach { $0.cancel() }; self.tasks.removeAll() } }
}
