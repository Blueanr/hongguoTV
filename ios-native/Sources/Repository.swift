// SPDX-License-Identifier: GPL-3.0-only
// Protocol port of kotlin-tv/core ContentRepository, DeviceRegister, PlaybackModels.
import Foundation

final class HTTP {
    static let shared = HTTP()
    let session: URLSession
    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 45
        config.httpCookieAcceptPolicy = .always
        session = URLSession(configuration: config)
    }
    func data(_ request: URLRequest, limit: Int = 16 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        // Streaming bounds apply even when Content-Length is missing or dishonest.
        let (stream, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw HGError.message("请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)）")
        }
        guard response.expectedContentLength <= limit else { throw HGError.message("服务响应过大") }
        var bytes = Data(); bytes.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in stream {
            if bytes.count >= limit { throw HGError.message("服务响应超过限制") }
            bytes.append(byte)
        }
        return (bytes, response)
    }
    func json(_ request: URLRequest) async throws -> JSON {
        let (bytes, _) = try await data(request)
        guard !bytes.isEmpty else { throw HGError.message("接口返回空响应，请稍后重试") }
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? JSON else { throw HGError.message("服务响应格式异常") }
        return object
    }
}

actor DeviceSession {
    struct Profile { let values: [String: String]; let cookie: String }
    private var cached: Profile?
    private var pending: Task<Profile, Error>?
    static let base: [String: String] = [
        "iid":"1905892595382586", "device_id":"1905892595378490", "ac":"wifi", "channel":"update_64", "aid":"8662", "app_name":"novelread",
        "version_code":"71332", "version_name":"7.1.3.32", "device_platform":"android", "os":"android", "ssmix":"a", "device_type":"25053RT47C",
        "device_brand":"Redmi", "language":"zh", "os_api":"36", "os_version":"16", "manifest_version_code":"71332", "resolution":"1280*2772",
        "dpi":"520", "update_version_code":"71332", "host_abi":"arm64-v8a", "dragon_device_type":"phone", "pv_player":"71332",
        "compliance_status":"0", "need_personal_recommend":"1", "player_so_load":"1", "is_android_pad_screen":"0"
    ]
    func profile() async throws -> Profile {
        if let cached = cached { return cached }
        if let pending = pending { return try await pending.value }
        let task = Task { try await Self.register() }; pending = task
        do { let result = try await task.value; cached = result; pending = nil; return result }
        catch { pending = nil; throw error }
    }
    private static func register() async throws -> Profile {
        let now = Int64(Date().timeIntervalSince1970 * 1000), cdid = UUID().uuidString.lowercased()
        let header: JSON = [
            "display_name":"红果免费短剧", "update_version_code":73932, "manifest_version_code":73932, "app_version_minor":"7.3.9.32",
            "aid":8662, "channel":"update_64", "package":"com.phoenix.read", "app_version":"7.3.9.32", "version_code":73932,
            "sdk_version":"3.7.0-rc.34-fanqie-xiaoshuo", "sdk_target_version":29, "git_hash":"3a88f4e", "os":"Android", "os_version":"16", "os_api":36,
            "device_model":"25053RT47C", "device_brand":"Redmi", "device_manufacturer":"Redmi", "cpu_abi":"arm64-v8a", "release_build":"b5e187f",
            "density_dpi":520, "display_density":"mdpi", "resolution":"1280x2772", "language":"zh", "timezone":8, "access":"wifi", "not_request_sender":0,
            "carrier":"CHINA MOBILE", "mcc_mnc":"46000", "rom":"eng.root.20231116.160340", "rom_version":"W528JS release-keys", "cdid":cdid,
            "sig_hash":"56a962410c494bbaf0b58dba20cae56f", "openudid":Crypto.random(8).hex, "clientudid":UUID().uuidString.lowercased(), "ipv6_list":[],
            "region":"CN", "tz_name":"Asia/Shanghai", "tz_offset":28800, "sim_region":"cn", "sim_serial_number":[], "oaid_may_support":false,
            "req_id":UUID().uuidString.lowercased(), "device_platform":"android", "custom":["account_region_src":"fallback", "host_bit":64, "account_region":"cn", "dragon_device_type":"phone"],
            "pre_installed_channel":"", "apk_first_install_time":now, "is_system_app":0, "sdk_flavor":"china", "guest_mode":0
        ]
        let json = try JSONSerialization.data(withJSONObject: ["magic_tag":"ss_app_log", "header":header, "_gen_time":now])
        let body = try Crypto.encryptRegistration(Crypto.gzip(json))
        var request = URLRequest(url: URL(string: "https://log5-applog-lf.fqnovel.com/service/2/device_register/?tt_data=a&cronet_version=8d40f833_2026-03-03&ttnet_version=4.2.243.31-douyin&use_store_region_cookie=1")!)
        request.httpMethod = "POST"; request.httpBody = body
        request.allHTTPHeaderFields = ["User-Agent":Repository.appUA, "Content-Type":"application/octet-stream;tt-data=a", "log-encode-type":"gzip", "x-ss-dp":"8662", "x-ss-req-ticket":String(now), "x-vc-bdturing-sdk-version":"4.0.3.cn", "lc":"101", "sdk-version":"2", "passport-sdk-version":"5051452", "x-neptune":"-8|50:51:59:30:40:47:49:39", "x-ss-stub":Crypto.hash("md5",body).hex.uppercased()]
        request.httpShouldHandleCookies = false
        let (data, response) = try await HTTP.shared.data(request)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSON else { throw HGError.message("播放设备初始化失败") }
        let device = object.text("device_id_str").isEmpty ? object.text("device_id") : object.text("device_id_str")
        let install = object.text("install_id_str").isEmpty ? object.text("install_id") : object.text("install_id_str")
        guard [device,install].allSatisfy({ $0.range(of: "^[1-9][0-9]{0,29}$", options: .regularExpression) != nil }) else { throw HGError.message("播放设备注册失败，请稍后重试") }
        var values = base; values["device_id"] = device; values["iid"] = install; values["cdid"] = cdid
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: request.url!)
            .filter { ["install_id", "ttreq", "store-region", "store-region-src"].contains($0.name) }
            .map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return Profile(values: values, cookie: cookies)
    }
}

final class Repository {
    static let shared = Repository()
    static let site = "https://hongguoduanju.com"
    static let appUA = "com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)"
    let signer = Signer()
    let device = DeviceSession()
    func router(_ path: String) async throws -> JSON {
        guard let url = URL(string: Self.site + path) else { throw HGError.message("地址无效") }
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await HTTP.shared.data(request)
        return try RouterParser.extract(String(decoding: data, as: UTF8.self))
    }
    func catalog(_ kind: CatalogKind, page: Int = 1, query: String = "") async throws -> CatalogPage {
        if !query.isEmpty {
            var request = URLRequest(url: URL(string: Self.site + "/api/search/result?query=\(Self.encode(query))&page=\(page)")!)
            request.setValue(Self.appUA,forHTTPHeaderField: "User-Agent")
            let section = try await HTTP.shared.json(request)
            guard let rows = section["searchList"] as? [JSON] else { throw HGError.message("搜索数据格式已变化") }
            let more = section["hasMore"] != nil ? section.flag("hasMore") : (section.number("totalPages") > 0 ? page < section.number("totalPages") : page < 100)
            return CatalogPage(items: unique(rows.map(Series.init).filter(\.valid)),more: !rows.isEmpty && more && page < 100)
        }
        let path: String
        if !query.isEmpty { path = "/search/\(Self.encode(query))?page=\(page)" }
        else if kind == .ranking { return try await ranking(page: page) }
        else if kind == .recommended { path = "/category?tab=1&sort_type=1&page=\(page)" }
        else { path = "/category/\(kind.route)?page=\(page)" }
        let data = try await router(path)
        let section = !query.isEmpty ? (data["search_(keyword)/page"] as? JSON ?? data.object("search_page")) : (data["category_page"] as? JSON ?? data.object("category_$"))
        let key = query.isEmpty ? "recommendList" : "searchList"
        guard let rows = section[key] as? [JSON] ?? section.object("categoryData")[key] as? [JSON] else { throw HGError.message("片单数据格式已变化") }
        let items = unique(rows.map(Series.init).filter(\.valid))
        let total = section.object("pagination").number("totalPages")
        return CatalogPage(items: items, more: !items.isEmpty && page < (total > 0 ? min(total,100) : 100))
    }
    func ranking(page: Int) async throws -> CatalogPage {
        let data = try await router("/rank/hot-drama?page=\(page)")
        let route = data.object("rank_hot-drama/page"), section = route.object("content")
        guard route.text("rankKey") == "hongguo",route.number("pageNum") == page,section.flag("isSuccess"),let rows = section["rankList"] as? [JSON] else { throw HGError.message("榜单数据格式已变化") }
        let items = rows.map { row in
            Series(id: row.text("seriesId").isEmpty ? row.text("id") : row.text("seriesId"),title: row.text("title"),cover: row.text("cover"),summary: row.text("description"),badge: "第 \(row.number("rank")) 名 · \(row.text("heatText"))",tags: (row["tags"] as? [String] ?? []).prefix(5).joined(separator: " · "))
        }
        return CatalogPage(items: unique(items.filter(\.valid)),more: page < min(100,section.object("pagination").number("totalPages")))
    }
    func detail(_ id: String) async throws -> Detail {
        guard id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil else { throw HGError.message("剧集编号无效") }
        let data = try await router("/detail?series_id=\(id)")
        let row = data.object("detail_page").object("seriesDetail")
        let episodes = (row["vid_list"] as? [Any] ?? []).map { String(describing: $0) }
        guard !episodes.isEmpty, Set(episodes).count == episodes.count, episodes.allSatisfy({ $0.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil }) else { throw HGError.message("分集暂不可用") }
        return Detail(series: Series(row), episodes: episodes)
    }
    func streams(_ id: String) async throws -> [Rendition] {
        let profile = try await device.profile()
        var values = profile.values
        for key in ["version_code", "manifest_version_code", "update_version_code", "pv_player"] { values[key] = "73932" }
        values["version_name"] = "7.3.9.32"
        let extra = ["video_id":id,"video_id_type":"0","device_level":"1","need_all_video_definition":"1","need_mp4_align":"0","use_os_player":"0","video_platform":"1024","source":"0","from_video_id":""]
        var failure: Error = HGError.message("没有可播放的视频资源")
        for post in [false, true] {
            try Task.checkCancellation()
            do {
                let base = "https://api5-normal-sinfonlineb.fqnovel.com" + (post ? "/novel/player/multi_video_model/v1/" : "/reading/bookapi/video_tab/multi_video_model/v1/")
                let payload: JSON = ["biz_param":["detail_page_version":0,"device_level":1,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024],"mixed_video_id_map":["1004":[id]]]
                let body = post ? try JSONSerialization.data(withJSONObject: payload) : nil
                var request = try await signer.request(base: base, values: post ? values : values.merging(extra) { _, n in n }, body: body, playback: true)
                request.setValue(profile.cookie, forHTTPHeaderField: "Cookie")
                let root = try await HTTP.shared.json(request)
                guard root.number("code") == 0, root.number("Code") == 0 else { throw HGError.message("播放接口返回错误 \(root.text("code"))") }
                let data = root.object("data"), rows = data["video_model_data"] as? JSON ?? data
                let entry = rows[id] as? JSON ?? (rows["video_model"] != nil ? rows : [:])
                var model = Self.jsonValue(entry["video_model"])
                if model["video_list"] == nil {
                    let fallback = model.text("fallback_api")
                    if let url = URL(string: fallback), url.scheme == "https" {
                        model = try await HTTP.shared.json(URLRequest(url: url))
                    }
                }
                let result = Self.renditions(model)
                if !result.isEmpty { return result }
                throw HGError.message("未返回兼容的播放资源")
            } catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        throw failure
    }
    static func jsonValue(_ value: Any?) -> JSON {
        if let object = value as? JSON { return object }
        if let text = value as? String, let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? JSON { return object }
        return [:]
    }
    static func renditions(_ model: JSON) -> [Rendition] {
        let rows = model["video_list"] as? [JSON] ?? Array((model["video_list"] as? [String: JSON] ?? [:]).values)
        return rows.compactMap { row in
            let meta = row.object("video_meta"), enc = row.object("encrypt_info")
            let codec = (row.text("codec_type") + " " + meta.text("codec_type") + " " + row.text("gear_des_key")).lowercased()
            guard !codec.contains("bytevc2"), !codec.contains("bvc2") else { return nil }
            do {
                let keyValue = enc.text("spade_a").isEmpty ? row.text("spade_a") : enc.text("spade_a")
                let key = keyValue.isEmpty ? nil : try Crypto.contentKey(keyValue)
                if !enc.isEmpty && key == nil && !["0","false"].contains(enc.text("encrypt")) { return nil }
                var url: URL?
                for field in ["main_url","play_url","backup_url_1"] {
                    if let candidate = try? Crypto.mediaURL(row.text(field), seed: model.text("key_seed")) { url = candidate; break }
                }
                guard let url = url else { return nil }
                let label = row.text("quality_desc").isEmpty ? meta.text("definition") : row.text("quality_desc")
                let quality = ["1080":1080,"720":720,"540":540,"480":480,"360":360].first { label.contains($0.key) }?.value ?? min(meta.number("vwidth"),meta.number("vheight"))
                return Rendition(url: url, key: key, quality: quality, codec: codec)
            } catch { return nil }
        }.sorted { $0.quality > $1.quality }
    }
    static func encode(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_.~"))) ?? "" }
    private func unique(_ rows: [Series]) -> [Series] { var seen = Set<String>(); return rows.filter { seen.insert($0.id).inserted } }
}
