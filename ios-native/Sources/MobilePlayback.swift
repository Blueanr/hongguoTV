// SPDX-License-Identifier: GPL-3.0-only
// Port of Kotlin 0.16.14, ef328f3: preload protocol and compatible VOD negotiation.
import Foundation

enum PlaybackResponseError: Error { case empty }

enum MobilePlayback {
    static let primaryHost = "reading.snssdk.com"
    static let alternateHost = "api5-normal-sinfonlineb.fqnovel.com"
    static func profile(_ device: [String:String]) throws -> [String:String] {
        var values = ["aid":"8662","app_name":"novelread","version_code":"74532","version_name":"7.4.5.32",
                      "update_version_code":"74532","manifest_version_code":"74532","os":"android","ssmix":"a",
                      "channel":"update_64","device_platform":"android","device_type":"25053RT47C","device_brand":"Redmi",
                      "os_version":"16","os_api":"36","ac":"wifi","language":"zh","host_abi":"arm64-v8a"]
        for key in ["iid","cdid","device_id"] {
            guard let value = device[key], !value.isEmpty else { throw HGError.message("播放设备资料不完整") }
            values[key] = value
        }
        return values
    }
    static func request(id: String,device: [String:String],signer: Signer,tab: Bool = false,host: String = primaryHost) async throws -> URLRequest {
        guard id.range(of: "^[0-9]{1,30}$",options: .regularExpression) != nil else { throw HGError.message("分集编号无效") }
        try Task.checkCancellation()
        var values = try profile(device)
        let path: String, body: Data?
        if tab {
            path = "/reading/bookapi/video_tab/multi_video_model/v1/"
            values.merge(["video_id":id,"video_id_type":"0","device_level":"1","need_all_video_definition":"1","need_mp4_align":"0","use_os_player":"0","video_platform":"1024","source":"0","from_video_id":""]) { _,new in new }
            body = nil
        } else {
            path = "/novel/player/multi_video_model/preload/v1"
            let payload: JSON = ["biz_param":["detail_page_version":0,"device_level":2,"disable_digg_stat":false,"disable_video_relate_book":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024],"mixed_video_id_map":["1004":[id]],"dr_scene":"preload"]
            body = try Crypto.gzip(JSONSerialization.data(withJSONObject: payload,options: [.sortedKeys]))
        }
        var request = try await signer.request(base: "https://" + host + path,values: values,body: body,mobileV5: true)
        request.setValue(tab ? "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)" : "okhttp/4.12.0",forHTTPHeaderField: "User-Agent")
        request.setValue(tab ? "application/json; charset=utf-8" : "application/json",forHTTPHeaderField: "Accept")
        if tab { request.setValue("zh-CN,zh;q=0.9",forHTTPHeaderField: "Accept-Language") }
        else { request.setValue("gzip",forHTTPHeaderField: "Content-Encoding") }
        try Task.checkCancellation()
        return request
    }
    static func decode(_ bytes: Data,response: HTTPURLResponse,id: String,tab: Bool) throws -> JSON {
        let text = String(decoding: bytes,as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            if let retry = response.value(forHTTPHeaderField: "Retry-After"), !retry.isEmpty { throw HGError.message("播放服务繁忙，请稍后重试") }
            throw PlaybackResponseError.empty
        }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? JSON else { throw HGError.message("播放信息格式异常") }
        guard root.number("code") == 0,root.number("Code") == 0 else { throw HGError.message("上游拒绝播放请求（\(root.text("Code").isEmpty ? root.text("code") : root.text("Code"))）") }
        let data = root.object("data")
        let entries = tab ? (data["video_model_data"] as? JSON ?? data) : (data["1004"] as? JSON ?? data)
        // Never select another episode from a batch response.
        let model = Repository.jsonValue(entries.object(id)["video_model"])
        guard !model.isEmpty else { throw HGError.message("未返回当前分集的播放信息") }
        return model
    }
    static func streams(id: String,device: [String:String],signer: Signer,
                         fetch: (URLRequest) async throws -> (Data,HTTPURLResponse) = { try await PlaybackTransport.data($0,limit: 2 * 1024 * 1024) }) async throws -> [Rendition] {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        func model(tab: Bool,host: String) async throws -> JSON {
            try Task.checkCancellation()
            var request = try await Self.request(id: id,device: device,signer: signer,tab: tab,host: host)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw HGError.message("播放请求超时，请重试") }
            request.timeoutInterval = remaining
            let started = ProcessInfo.processInfo.systemUptime
            let (bytes,response) = try await fetch(request)
#if DEBUG
            // Transport facts only: never emit signed URLs, IDs, cookies or bodies.
            print("Playback model \(tab ? "GET" : "POST") \(host): HTTP \(response.statusCode), \(bytes.count) bytes, \(Int((ProcessInfo.processInfo.systemUptime - started) * 1000)) ms")
#endif
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HGError.message("播放请求超时，请重试") }
            return try decode(bytes,response: response,id: id,tab: tab)
        }
        func compatible(_ model: JSON) async throws -> [Rendition] {
            let rows = Repository.renditions(model)
            if !rows.isEmpty { return rows }
            guard let endpoint = fallback(model) else { throw HGError.message("没有兼容的播放资源") }
            for codec in ["1","3"] {
                try Task.checkCancellation()
                var components = URLComponents(url: endpoint,resolvingAgainstBaseURL: false)!
                var items = (components.queryItems ?? []).filter { $0.name != "codec_type" }
                items.append(URLQueryItem(name: "codec_type",value: codec)); components.queryItems = items
                guard let url = components.url else { throw HGError.message("视频协商地址无效") }
                var request = URLRequest(url: url); request.httpShouldHandleCookies = false
                request.setValue("application/json",forHTTPHeaderField: "Accept")
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw HGError.message("播放请求超时，请重试") }
                request.timeoutInterval = remaining
                let (bytes,_) = try await fetch(request)
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw HGError.message("播放请求超时，请重试") }
                guard let root = try? JSONSerialization.jsonObject(with: bytes) as? JSON,
                      let data = root.object("video_info")["data"] as? JSON else { throw HGError.message("视频协商响应格式异常") }
                let rows = Repository.renditions(data)
                if !rows.isEmpty { return rows }
            }
            throw HGError.message("没有兼容的 H.264/HEVC 播放资源")
        }
        do {
            return try await compatible(model(tab: false,host: primaryHost))
        } catch PlaybackResponseError.empty {
            do {
                let rows = Repository.renditions(try await model(tab: true,host: alternateHost))
                if !rows.isEmpty { return rows }
                // 0.16.13: video-tab may return only bytevc2; same host's POST can supply HEVC.
                return try await compatible(model(tab: false,host: alternateHost))
            } catch PlaybackResponseError.empty { throw HGError.message("播放接口暂时返回空响应，请稍后重试") }
        }
    }
    static func fallback(_ model: JSON) -> URL? {
        let raw = model["fallback_api"]
        let text = (raw as? [String])?.first ?? (Repository.jsonValue(raw)["fallback_api"] as? String) ?? (raw as? String) ?? ""
        let cleaned = text.replacingOccurrences(of: "\\u0026",with: "&").replacingOccurrences(of: "\\/",with: "/").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else { return nil }
        return url
    }
}
