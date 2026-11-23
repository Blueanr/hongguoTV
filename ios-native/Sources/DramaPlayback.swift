// SPDX-License-Identifier: GPL-3.0-only
// Native session transport for jackotom/hongguo-drama's SDK playback protocol.
import Foundation

actor DramaPlayback {
    static let shared = DramaPlayback()
    private let signer = Signer()
    struct Identity: Codable { let params: [String:String]; let cookies: [String:String] }
    private var identity: Identity?
    private var ready = false
    private var token = ""
    private var ladon = 0
    private var materialsLoaded = false
    private var busy = false
    private var retryAt: TimeInterval = 0
    private var root: URL {
        get throws {
            var directory = try FileManager.default.url(for: .applicationSupportDirectory,in: .userDomainMask,appropriateFor: nil,create: true).appendingPathComponent("drama-playback",isDirectory: true)
            try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            return directory
        }
    }
    private func fetch(_ request: URLRequest,limit: Int) async throws -> (Data,HTTPURLResponse) {
        try await PlaybackTransport.data(request,limit: limit)
    }
    private func assets() async throws {
        if materialsLoaded { return }
        let directory = try root
        let specs: [(String,Int,String,Int,Int,String,Int)] = [
            ("libmetasec_ml.so",4501136,"c6831ab265a0cb76dacfa3b7041e9ea0f706490106a74e12f39058671cc14fe3",115882007,1497823,"3839797f0a1e0ef6c604d639d0054a527b99ed1fa6aa9ecd2e80a9d87c8d133f",4501136),
            ("sdk-app-config.encoded",304,"584a01183f1e6783326bff49d4f1319f33fcce678afb93ca0dc8b60a56b65855",68002997,3914490,"e7c9cc2356ed194f4971c9f45687425d8dd7a2c445266a5a6f4fc3947417872d",10367780)
        ]
        var loaded: [Data] = []
        for (name,size,hash,start,count,packedHash,unpacked) in specs {
            let path = directory.appendingPathComponent(name)
            if let existing = try? Data(contentsOf: path),existing.count == size,Crypto.hash("sha256",existing).hex == hash { loaded.append(existing); continue }
            var request = URLRequest(url: URL(string: "https://lf9-apk.ugapk.cn/package/apk/novelread/12267_74532/novelread_69321526a_v12267_74532_46e0_1794485793.apk?v=1794485793")!)
            request.setValue("bytes=\(start)-\(start + count - 1)",forHTTPHeaderField: "Range")
            request.setValue("identity",forHTTPHeaderField: "Accept-Encoding")
            // Anonymous CDN download may redirect; never forward a session signature.
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false; config.httpCookieStorage = nil
            config.timeoutIntervalForResource = 45
            let download = URLSession(configuration: config)
            defer { download.invalidateAndCancel() }
            let (stream,response) = try await download.bytes(for: request)
            guard let http = response as? HTTPURLResponse,http.statusCode == 206,
                  http.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(start + count - 1)/156400488" else { throw HGError.message("SDK 初始化资料下载失败，请稍后重试") }
            var packed = Data()
            for try await byte in stream {
                guard packed.count < count else { throw HGError.message("SDK 初始化资料超出限制") }
                packed.append(byte)
            }
            guard packed.count == count,Crypto.hash("sha256",packed).hex == packedHash else { throw HGError.message("SDK 初始化资料校验失败") }
            let inflated = try Crypto.inflate(packed,window: -15,limit: unpacked)
            guard inflated.count == unpacked else { throw HGError.message("SDK 初始化资料长度错误") }
            let result = name == "sdk-app-config.encoded" ? Data(inflated[1918408..<(1918408 + 304)]) : inflated
            guard result.count == size,Crypto.hash("sha256",result).hex == hash else { throw HGError.message("SDK 初始化资料校验失败") }
            try result.write(to: path,options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
            loaded.append(result)
        }
        _ = try await signer.dramaCall("hgDramaMaterials",[loaded[1].base64EncodedString(),loaded[0].base64EncodedString()])
        materialsLoaded = true
    }
    private func register() async throws -> Identity {
        if let identity = identity { return identity }
        let path = try root.appendingPathComponent("device.json")
        if let data = try? Data(contentsOf: path),data.count <= 131072,let value = try? JSONDecoder().decode(Identity.self,from: data),Self.valid(value) {
            identity = value; return value
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000),cdid = UUID().uuidString.lowercased(),openudid = Crypto.random(8).hex
        let params = Self.registrationParams(now: now,cdid: cdid,openudid: openudid)
        let header: JSON = [
            "access":"wifi","aid":8662,"app_version":"7.3.9.32","app_version_minor":"","apk_first_install_time":now,"cdid":cdid,"channel":"xiaomi_8662_64",
            "clientudid":UUID().uuidString.lowercased(),"cpu_abi":"arm64-v8a","density_dpi":460,"device_brand":"xiaomi","device_category":"phone","device_manufacturer":"Xiaomi","device_model":"Xiaomi 14","device_platform":"android","display_density":"xxhdpi","display_name":"红果短剧","git_hash":"fe95b95","guest_mode":0,"ipv6_list":[],"is_system_app":0,"language":"zh","manifest_version_code":73932,"not_request_sender":0,"oaid_may_support":true,"openudid":openudid,"os":"Android","os_api":34,"os_version":"14","package":"com.phoenix.read","region":"CN","release_build":"UKQ1.230804.001_1701234567","req_id":UUID().uuidString.lowercased(),"resolution":"2670x1200","rom":"hyperos","rom_version":"OS1.0.32.0.UNCCNXM","sdk_flavor":"china","sdk_target_version":29,"sdk_version":"3.7.3-rc.116-douyin","sig_hash":"aea615ab910015038f73c47e45d21466","sim_serial_number":[],"timezone":8,"tz_name":"Asia/Shanghai","tz_offset":28800,"update_version_code":73932,"version_code":73932,
            "custom":["is_android_fold":0,"filter_warn":0,"is_android_pad":0,"client_ipv4":"0.0.0.0","web_ua":"Mozilla/5.0 (Linux; Android 14; Xiaomi 14 Build/UKQ1.230804.001; wv) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/120.0.0.0 Mobile Safari/537.36"]
        ]
        let json = try JSONSerialization.data(withJSONObject: ["magic_tag":"ss_app_log","header":header,"_gen_time":now])
        let body = try Crypto.encryptRegistration(Crypto.gzip(json))
        let query = params.keys.sorted().map { Repository.encode($0) + "=" + Repository.encode(params[$0]!) }.joined(separator: "&")
        var request = URLRequest(url: URL(string: "https://log.snssdk.com/service/2/device_register/?" + query)!)
        request.httpMethod = "POST"; request.httpBody = body; request.httpShouldHandleCookies = false
        var seconds = UInt32(now / 1000).littleEndian
        let argus = withUnsafeBytes(of: &seconds) { Data($0).base64EncodedString() }
        request.allHTTPHeaderFields = ["Content-Type":"application/octet-stream;tt-data=a","Content-Encoding":"gzip","Accept-Encoding":"gzip","User-Agent":"com.phoenix.read/73932 (Linux; U; Android 14; zh_CN; Xiaomi 14; Build/UKQ1.230804.001; Cronet/TTNetVersion:8d40f833 QuicVersion:462f352c 2026-08-31)","Accept":"application/json; charset=utf-8,application/x-protobuf","X-SS-STUB":Crypto.hash("md5",body).hex.uppercased(),"X-SS-DP":"8662","X-SS-REQ-TICKET":String(now),"X-Khronos":String(now / 1000),"X-Argus":argus,"X-TT-Request-Tag":"t=0;n=1","Log-Encode-Type":"gzip","Passport-SDK-Version":"60755","Passport-SDK-Settings":"device_transfer_s_0,device_transfer_ab_1","Sdk-Version":"2","lc":"102","X-TT-Store-Region":"cn","X-TT-Store-Region-Src":"did","X-VC-Bdturing-SDK-Version":"4.0.3.cn"]
        let (data,response) = try await fetch(request,limit: 2 * 1024 * 1024)
        guard let object = try JSONSerialization.jsonObject(with: data) as? JSON else { throw HGError.message("匿名播放设备注册失败") }
        var values = params
        values["device_id"] = object.text("device_id_str").isEmpty ? object.text("device_id") : object.text("device_id_str")
        values["iid"] = object.text("install_id_str").isEmpty ? object.text("install_id") : object.text("install_id_str")
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers,for: request.url!).filter { ["odin_tt","ttreq","store-region","store-region-src"].contains($0.name) }
        let result = Identity(params: values,cookies: Dictionary(cookies.map { ($0.name,$0.value) },uniquingKeysWith: { _,new in new }))
        guard Self.valid(result) else { throw HGError.message("匿名播放设备资料不完整") }
        try JSONEncoder().encode(result).write(to: path,options: [.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        identity = result; return result
    }
    static func valid(_ value: Identity) -> Bool {
        value.params["aid"] == "8662" && ["device_id","iid"].allSatisfy { value.params[$0]?.range(of: "^[1-9][0-9]{4,29}$",options: .regularExpression) != nil } &&
        ["cdid","device_type","device_brand","os_version","os_api","dpi","resolution"].allSatisfy { !(value.params[$0] ?? "").isEmpty } && value.cookies["store-region-src"] != "uid"
    }
    static func registrationParams(now: Int64,cdid: String,openudid: String) -> [String:String] {
        ["aid":"8662","app_name":"novelread","channel":"xiaomi_8662_64","version_code":"73932","version_name":"7.3.9.32","manifest_version_code":"73932","update_version_code":"73932","device_platform":"android","os":"android","ssmix":"a","device_type":"23127PN0CC","device_brand":"xiaomi","os_api":"34","os_version":"14","resolution":"1200*2670","dpi":"460","ac":"wifi","language":"zh","openudid":openudid,"cdid":cdid,"tt_data":"a","_rticket":String(now),"ts":String(now / 1000),"package":"com.phoenix.read","first_launch_timestamp":String(now / 1000),"last_deeplink_update_version_code":"0","cpu_support64":"true","host_abi":"arm64-v8a","is_guest_mode":"0","app_type":"normal","minor_status":"0","appTheme":"light","is_preinstall":"0","need_personal_recommend":"1","is_android_pad":"0","is_android_fold":"0","md":"0","cronet_version":"8d40f833_2026-03-03","ttnet_version":"4.2.243.31-douyin","use_store_region_cookie":"1"]
    }
    static func body(_ id: String) throws -> Data {
        try Crypto.gzip(JSONSerialization.data(withJSONObject: ["dr_scene":"player","mixed_video_id_map":["1004":[id]],"biz_param":["detail_page_version":0,"device_level":4,"disable_digg_stat":false,"need_all_video_definition":true,"need_mp4_align":false,"use_os_player":false,"use_server_dns":false,"video_platform":1024]]))
    }
    private func prepared(_ identity: Identity,id: String) async throws -> URLRequest {
        let body = id.isEmpty ? Data() : try Self.body(id)
        let text = try await signer.dramaCall("hgDramaRequest",[identity.params,identity.cookies,id,token,ladon,Int64(Date().timeIntervalSince1970 * 1000),body.base64EncodedString()])
        guard let bytes = text.data(using: .utf8),let object = try JSONSerialization.jsonObject(with: bytes) as? JSON,
              let url = URL(string: object.text("url")),let headers = object["headers"] as? [String:String],let payload = Data(base64Encoded: object.text("body")) else { throw HGError.message("播放会话签名失败") }
        ladon = object.number("ladon")
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = payload
        request.httpShouldHandleCookies = false; request.allHTTPHeaderFields = headers
        return request
    }
    private func initialize(_ identity: Identity) async throws {
        if ready { return }
        token = ""; ladon = 0
        for _ in 0..<2 {
            let request = try await prepared(identity,id: "")
            let (bytes,_) = try await fetch(request,limit: 131072)
            guard !bytes.isEmpty else { throw HGError.message("播放会话初始化返回空响应") }
            let text = try await signer.dramaCall("hgDramaResponse",[bytes.base64EncodedString()])
            guard let data = text.data(using: .utf8),let value = try JSONSerialization.jsonObject(with: data) as? JSON else { throw HGError.message("播放会话初始化失败") }
            token = value.text("token")
            if value.number("status") == 200 { ready = true; return }
            guard value.number("status") == 202 else { throw HGError.message("播放会话被服务端拒绝") }
        }
        throw HGError.message("播放会话仍在初始化，请稍后重试")
    }
    func streams(_ id: String) async throws -> [Rendition] {
        guard id.range(of: "^[1-9][0-9]{7,23}$",options: .regularExpression) != nil else { throw HGError.message("分集编号无效") }
        // Actor reentrancy must not interleave bootstrap/ladon state across episodes.
        while busy { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation(); busy = true
        defer { busy = false }
        guard ProcessInfo.processInfo.systemUptime >= retryAt else { throw HGError.message("播放服务暂不可用，请 10 秒后重试") }
        var stage = "SDK 资料初始化"
        do {
            try await assets()
            stage = "匿名设备注册"
            let profile = try await register()
            stage = "SDK 会话初始化"
            try await initialize(profile)
            stage = "播放模型请求"
            let request = try await prepared(profile,id: id)
            let (bytes,response) = try await fetch(request,limit: 2 * 1024 * 1024)
            stage = "播放模型解析"
            let model = try MobilePlayback.decode(bytes,response: response,id: id,tab: false)
            let rows = Repository.renditions(model)
            guard !rows.isEmpty else { throw HGError.message("当前分集没有兼容的 H.264/HEVC 播放资源") }
            return rows
        } catch {
            if Task.isCancelled { throw CancellationError() }
            retryAt = ProcessInfo.processInfo.systemUptime + 10
            // One new session may be initialized on the next user request; never rotate identities in a loop.
            ready = false; token = ""; ladon = 0
            if error is PlaybackResponseError { throw HGError.message("会话播放接口返回空响应，请稍后重试") }
            throw PlaybackFailure(stage: stage,cause: error)
        }
    }
}
