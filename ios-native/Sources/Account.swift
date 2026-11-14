// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import Security
import SwiftUI

enum AccountKeychain {
    private static let query: [String: Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:"com.hongguotv.ipad.account",kSecAttrAccount as String:"session"]
    static func read() -> String? {
        var q = query; q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary,&result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data,encoding: .utf8)
    }
    static func save(_ cookie: String) throws {
        let values: [String: Any] = [kSecValueData as String:Data(cookie.utf8),kSecAttrAccessible as String:kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary,values as CFDictionary)
        if update == errSecItemNotFound {
            guard SecItemAdd(query.merging(values) { _,new in new } as CFDictionary,nil) == errSecSuccess else { throw HGError.message("登录态保存失败") }
        } else if update != errSecSuccess { throw HGError.message("登录态保存失败") }
    }
    static func delete() { SecItemDelete(query as CFDictionary) }
}

@MainActor final class Account: ObservableObject {
    static let shared = Account()
    @Published private(set) var loggedIn = AccountKeychain.read() != nil
    @Published var nickname = "红果账号"
    @Published var error: String?
    private var cookie = AccountKeychain.read() ?? ""
    private var generation = UUID()
    private let signer = Signer()
    func login(cookie: String) async throws {
        self.cookie = cookie
        do {
            let root = try await call("/reading/user/info/v1/")
            guard !root.object("data").text("biz_user_id").isEmpty else { throw HGError.message("请先在官方红果 App 登录并建立账号资料") }
            try AccountKeychain.save(cookie); nickname = root.object("data").text("user_name"); loggedIn = true; generation = UUID()
        } catch { self.cookie = AccountKeychain.read() ?? ""; throw error }
    }
    func logout() { generation = UUID(); cookie = ""; loggedIn = false; nickname = "红果账号"; AccountKeychain.delete() }
    func call(_ path: String,params: [String: String] = [:],body: JSON? = nil) async throws -> JSON {
        guard !cookie.isEmpty else { throw HGError.message("请先登录红果账号") }
        let expected = generation, sessionCookie = cookie
        let profile = try await Repository.shared.device.profile()
        var values = profile.values
        for key in ["version_code","manifest_version_code","update_version_code","pv_player"] { values[key] = body == nil ? "72232" : "73932" }
        values["version_name"] = body == nil ? "7.2.2.32" : "7.3.9.32"
        let bytes = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        var request = try await signer.request(base: "https://api5-normal-sinfonlinea.fqnovel.com" + path,values: values.merging(params) { _,new in new },body: bytes)
        guard generation == expected else { throw CancellationError() }
        request.setValue(sessionCookie,forHTTPHeaderField: "Cookie")
        request.httpShouldHandleCookies = false
        let root = try await HTTP.shared.json(request)
        guard generation == expected else { throw CancellationError() }
        guard root["code"] != nil, root.number("code") == 0 else { throw HGError.message("账号接口错误 \(root.text("code"))，请重新登录或稍后重试") }
        return root
    }
    func favorites() async throws -> [Series] {
        let root = try await call("/reading/bookapi/bookshelf/video/info/v1/"), data = root.object("data")
        guard data["video_shelf_info"] != nil else { throw HGError.message("账号收藏格式已变化") }
        return unique(data.rows("video_shelf_info").map { row in
            let video = row["video_data"] as? JSON ?? row
            return Series(id: first(video.text("series_id"),row.text("series_id"),row.text("book_id")),title: first(row.text("series_title"),video.text("title"),row.text("book_name")),cover: first(row.text("series_cover_url"),video.text("cover"),video.text("cover_url"),video.text("thumb_url"),row.text("thumb_url")),summary: first(row.text("series_intro"),video.text("video_desc"),row.text("abstract")))
        }.filter(\.valid))
    }
    func setFavorite(_ series: Series,add: Bool) async throws {
        var entry: JSON = ["book_id":series.id,"book_type":2,"modify_time":Int64(Date().timeIntervalSince1970 * 1000),"video_shelf_operate_type":add ? 0 : 1]
        if !add { entry["group_name"] = "" }
        var body: JSON = ["is_cancelled":false,"update_bookshelf_video_list":[entry]]
        if add { body["shark_extra"] = ["enter_from":"MainFragmentActivity","previous_page":"","page_list":"MainFragmentActivity","is_active_behavior":"true","inactive_type":"0"] }
        _ = try await call("/reading/bookapi/bookshelf/video/update/v1/",body: body)
        let rows = try await favorites()
        guard rows.contains(where: { $0.id == series.id }) == add else { throw HGError.message("账号收藏尚未确认，请刷新后重试") }
    }
    func history() async throws -> [WatchProgress] {
        let root = try await call("/reading/bookapi/read_progress/list/v1/",params: ["book_types":"2","limit":"50"])
        guard let rows = root["video_data"] as? [JSON] ?? root.object("data")["video_data"] as? [JSON] else { throw HGError.message("云端历史格式已变化") }
        var progress = rows.compactMap { row -> WatchProgress? in
            let id = first(row.text("series_id"),row.text("book_id")), episode = row.text("vid")
            guard !id.isEmpty, !episode.isEmpty else { return nil }
            let stamp = row.number("last_watch_time")
            return WatchProgress(series: Series(id: id,title: "剧集 \(id)"),episodeID: episode,index: max(0,row.number("vid_index") - 1),position: Double(max(0,row.number("current_play_time"))) / 1000,duration: Double(max(0,row.number("current_total_time"))) / 1000,updatedAt: Date(timeIntervalSince1970: Double(stamp) / (stamp > 9_999_999_999 ? 1000 : 1)))
        }
        if !progress.isEmpty {
            let details = try await call("/reading/bookapi/multi-detail/v1/",params: ["book_id":progress.map { $0.series.id }.joined(separator: ","),"book_type":"2"])
            for row in details.rows("data") {
                for i in progress.indices where progress[i].series.id == row.text("book_id") {
                    progress[i].series = Series(id: row.text("book_id"),title: row.text("book_name"),cover: row.text("thumb_url"),summary: row.text("abstract"))
                }
            }
        }
        return progress.sorted { $0.updatedAt > $1.updatedAt }
    }
    func reservations(online: Bool) async throws -> [Series] {
        let root = try await call("/reading/user/subscribe/list/v0/",params: ["offset":"0","limit":"20","is_online":String(online),"tab_type":"13","subscribe_order_type":"0","swipe_type":"0","need_calendar_schema":"false","subscribe_offset":"0"])
        let data = root.object("data")
        guard data["subscribe_items"] != nil else { throw HGError.message("预约数据格式已变化") }
        return unique(data.rows("subscribe_items").compactMap { row in
            let video = row["subscribe_data"] as? JSON ?? row["video_data"] as? JSON ?? row
            let id = first(video.text("series_id"),row.text("series_id"),row.text("book_id"),row.text("item_id"))
            let title = first(row.text("series_title"),video.text("title"),video.text("book_name"),row.text("name"))
            guard !id.isEmpty,!title.isEmpty else { return nil }
            return Series(id: online ? id : "reservation:" + id,title: title,cover: first(row.text("series_cover_url"),video.text("cover"),video.text("cover_url")),badge: online ? "已上线" : "待上线")
        })
    }
    func upload(_ progress: WatchProgress,count: Int) async {
        guard loggedIn else { return }
        let entry: JSON = ["book_id":progress.series.id,"item_id":progress.episodeID,"vid_index":progress.index + 1,"current_play_time":Int64(progress.position * 1000),"current_total_time":Int64(progress.duration * 1000),"episode_count":count,"read_timestamp_ms":Int64(progress.updatedAt.timeIntervalSince1970 * 1000),"book_type":2,"progress_rate":String(progress.duration > 0 ? min(1,progress.position / progress.duration) : 0),"player_cumulative_total_duration":Int64(progress.position * 1000)]
        do { _ = try await call("/reading/bookapi/read_progress/upload/v1/",body: ["books":[entry],"write_mode":1]) }
        catch is CancellationError { }
        catch { self.error = "云端进度同步失败：\(error.localizedDescription)" }
    }
    private func first(_ strings: String...) -> String { strings.first { !$0.isEmpty } ?? "" }
    private func unique(_ rows: [Series]) -> [Series] { var ids = Set<String>(); return rows.filter { ids.insert($0.id).inserted } }
}

// Each QR flow has an isolated, in-memory cookie jar. Account secrets persist only in Keychain.
final class QRLogin: NSObject, URLSessionTaskDelegate {
    private var cookies: [HTTPCookie] = []
    private var token = ""
    private lazy var session = URLSession(configuration: .ephemeral,delegate: self,delegateQueue: nil)
    private static let base = URL(string: Repository.site)!
    func urlSession(_ session: URLSession,task: URLSessionTask,willPerformHTTPRedirection response: HTTPURLResponse,newRequest request: URLRequest,completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    private func request(_ url: URL) async throws -> (Data,HTTPURLResponse) {
        var request = URLRequest(url: url); request.httpShouldHandleCookies = false; request.timeoutInterval = 20
        request.allHTTPHeaderFields = ["User-Agent":"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/141.0.0.0 Safari/537.36","Referer":Repository.site + "/","Origin":Repository.site,"Accept":"application/json, text/javascript"]
        request.setValue(cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; "),forHTTPHeaderField: "Cookie")
        if let csrf = cookies.first(where: { $0.name == "passport_csrf_token" }) { request.setValue(csrf.value,forHTTPHeaderField: "x-tt-passport-csrf-token") }
        let (data,response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= 2 * 1024 * 1024 else { throw HGError.message("登录响应异常") }
        let headers = response.allHeaderFields.reduce(into: [String:String]()) { $0[String(describing: $1.key)] = String(describing: $1.value) }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: headers,for: url) {
            cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path }
            if cookie.expiresDate == nil || cookie.expiresDate! > Date() { cookies.append(cookie) }
        }
        return (data,response)
    }
    private func call(_ path: String,params: [String:String] = [:]) async throws -> JSON {
        var components = URLComponents(string: Repository.site + path)!
        let base = ["aid":"513755","passport_jssdk_version":"3.4.10","passport_jssdk_type":"normal","account_sdk_source":"web","is_from_ttaccountsdk":"1","language":"zh"]
        components.queryItems = base.merging(params) { _,n in n }.map { URLQueryItem(name: $0.key,value: $0.value) }
        let (bytes,response) = try await request(components.url!)
        guard (200...299).contains(response.statusCode), let root = try JSONSerialization.jsonObject(with: bytes) as? JSON else { throw HGError.message("官网登录请求失败") }
        guard root.text("message") == "success" else { throw HGError.message(root.object("data").text("description").isEmpty ? "官网登录失败，请重新获取二维码" : root.object("data").text("description")) }
        return root.object("data")
    }
    func qr() async throws -> Data {
        let data = try await call("/passport/web/get_qrcode/",params: ["next":Repository.site + "/"])
        token = data.text("token")
        let encoded = data.text("qrcode").components(separatedBy: "base64,").last ?? ""
        guard !token.isEmpty, let image = Data(base64Encoded: encoded) else { throw HGError.message("二维码格式异常") }
        return image
    }
    func poll() async throws -> String? {
        let data = try await call("/passport/web/check_qrconnect/",params: ["next":Repository.site + "/","token":token])
        if ["5","expired"].contains(data.text("status")) { throw HGError.message("二维码已过期，请刷新") }
        if ["3","confirmed"].contains(data.text("status")), !data.text("redirect_url").isEmpty {
            var next = URL(string: data.text("redirect_url"),relativeTo: Self.base)?.absoluteURL
            for _ in 0..<5 {
                guard let url = next else { break }
                guard url.scheme == "https",url.host == "hongguoduanju.com",url.user == nil,url.password == nil else { throw HGError.message("登录确认跳转异常") }
                let (_,response) = try await request(url)
                next = (300...399).contains(response.statusCode) ? response.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0,relativeTo: url)?.absoluteURL } : nil
            }
        }
        guard cookies.contains(where: { ["sessionid","sessionid_ss"].contains($0.name) }) else { return nil }
        _ = try await call("/passport/account/info/v2/")
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
    func cancel() { session.invalidateAndCancel() }
}

struct AccountScreen: View {
    @ObservedObject private var account = Account.shared
    @State private var image: UIImage?
    @State private var error: String?
    @State private var status = ""
    @State private var refresh = 0
    @State private var selection = "收藏"
    @State private var rows: [Series] = []
    @State private var cloudProgress: [String:WatchProgress] = [:]
    @State private var loading = false
    var body: some View {
        VStack {
            if account.loggedIn {
                HStack { Text(account.nickname).font(.headline); Spacer(); Button("退出账号",role: .destructive) { account.logout(); rows = []; cloudProgress = [:] } }.padding()
                Picker("账户片单",selection: $selection) { ForEach(["收藏","历史","已上线预约","待上线预约"],id: \.self) { Text($0).tag($0) } }.pickerStyle(.segmented).padding(.horizontal)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 140,maximum: 220))]) {
                        ForEach(rows) { row in
                            if row.id.hasPrefix("reservation:") { Poster(series: row) }
                            else { NavigationLink(destination: DetailScreen(series: row,cloudResume: cloudProgress[row.id])) { Poster(series: row) }.buttonStyle(.plain) }
                        }
                    }.padding()
                    if loading { ProgressView() }
                    if rows.isEmpty && !loading && error == nil { Text("暂无记录").foregroundColor(.secondary) }
                    Text("云端历史最近 50 部；预约每类最近 20 部。").font(.footnote).foregroundColor(.secondary)
                }.refreshable { refresh += 1 }
            } else {
                Spacer()
                if let image = image { Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 240,height: 240).padding().background(Color.white).cornerRadius(12) }
                else if error == nil { ProgressView("正在获取二维码…") }
                Text("使用手机红果 App 扫码并确认登录").font(.headline).padding()
                Text(status).foregroundColor(.secondary)
                Button("刷新二维码") { refresh += 1 }
                Spacer()
            }
            if let error = error { Text(error).foregroundColor(.red).padding(); Button("重试") { refresh += 1 } }
            if let syncError = account.error { Text(syncError).font(.footnote).foregroundColor(.orange).padding() }
        }.navigationTitle("红果账号")
            .task(id: "\(refresh):\(selection):\(account.loggedIn)") {
                error = nil
                if account.loggedIn {
                    loading = true; rows = []; cloudProgress = [:]
                    do {
                        if selection == "收藏" { rows = try await account.favorites() }
                        else if selection == "历史" {
                            let progress = try await account.history()
                            rows = progress.map(\.series); cloudProgress = Dictionary(progress.map { ($0.series.id,$0) },uniquingKeysWith: { first,_ in first })
                        } else { rows = try await account.reservations(online: selection == "已上线预约") }
                    } catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                    loading = false
                } else {
                    image = nil; status = ""; let login = QRLogin(); defer { login.cancel() }
                    do {
                        image = UIImage(data: try await login.qr())
                        for _ in 0..<90 {
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                            if let cookie = try await login.poll() { status = "正在读取账号资料…"; try await account.login(cookie: cookie); return }
                        }
                        error = "二维码已过期，请刷新"
                    } catch is CancellationError { }
                    catch { self.error = error.localizedDescription }
                }
            }
    }
}
