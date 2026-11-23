// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

@main struct HongguoPadApp: App {
    @StateObject private var library = Library()
    var body: some Scene {
        WindowGroup {
            RootScreen().environmentObject(library).tint(Color(red: 0.95,green: 0.23,blue: 0.28))
        }
    }
}

struct RootScreen: View {
    @EnvironmentObject var library: Library
    var body: some View {
        TabView {
            BrowseScreen().tabItem { Label("发现",systemImage: "play.rectangle.fill") }
            BrowseScreen(searching: true).tabItem { Label("搜索",systemImage: "magnifyingglass") }
            LocalLibraryScreen(history: false).tabItem { Label("收藏",systemImage: "heart.fill") }
            LocalLibraryScreen(history: true).tabItem { Label("最近观看",systemImage: "clock.fill") }
            SettingsScreen().tabItem { Label("设置",systemImage: "gearshape.fill") }
        }.alert("本机存储",isPresented: Binding(get: { library.error != nil },set: { if !$0 { library.error = nil } })) {
            Button("知道了",role: .cancel) { library.error = nil }
        } message: { Text(library.error ?? "") }
    }
}

struct Poster: View {
    let series: Series
    var body: some View {
        VStack(alignment: .leading,spacing: 7) {
            GeometryReader { geo in
                AsyncImage(url: URL(string: series.cover)) { image in image.resizable().scaledToFill() }
                placeholder: { ZStack { Color.secondary.opacity(0.12); Image(systemName: "film").font(.largeTitle).foregroundColor(.secondary) } }
                    .frame(width: geo.size.width,height: geo.size.height).clipped()
            }.aspectRatio(0.7,contentMode: .fit).cornerRadius(12)
            Text(series.title).font(.headline).lineLimit(2).foregroundColor(.primary)
            Text(series.badge).font(.caption).foregroundColor(.secondary).lineLimit(1)
        }.accessibilityElement(children: .combine)
    }
}
struct SeriesGrid: View {
    let items: [Series]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140,maximum: 220),spacing: 16)],alignment: .leading,spacing: 22) {
            ForEach(items) { series in NavigationLink(destination: DetailScreen(series: series)) { Poster(series: series) }.buttonStyle(.plain) }
        }.padding()
    }
}

struct BrowseScreen: View {
    var searching = false
    @State private var kind = CatalogKind.recommended
    @State private var query = ""
    @State private var submitted = ""
    @State private var items: [Series] = []
    @State private var page = 0
    @State private var more = false
    @State private var loading = false
    @State private var error: String?
    @State private var generation = UUID()
    @State private var loadTask: Task<Void,Never>?
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if searching {
                    HStack {
                        TextField("输入剧名或关键词",text: $query).textFieldStyle(.roundedBorder).submitLabel(.search).onSubmit { submit() }
                        Button("搜索") { submit() }.buttonStyle(.borderedProminent)
                    }.padding()
                } else {
                    Picker("分类",selection: $kind) { ForEach(CatalogKind.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).padding().onChange(of: kind) { _ in reload() }
                }
                ScrollView {
                    SeriesGrid(items: items)
                    if loading { ProgressView("正在加载…").padding() }
                    if let error = error { VStack { Text(error).foregroundColor(.secondary); Button("重试") { load(reset: page == 0) } }.padding() }
                    else if more && !loading { Button("加载更多") { load(reset: false) }.padding() }
                    else if items.isEmpty && !loading { Text(searching && submitted.isEmpty ? "输入关键词，发现下一部好剧" : "暂无相关短剧").foregroundColor(.secondary).padding(40) }
                }.refreshable { reload() }
            }.navigationTitle(searching ? "搜索" : "红果 TV")
                .onAppear { if !searching && items.isEmpty && !loading { reload() } }
                .onDisappear { loadTask?.cancel(); loading = false }
        }.navigationViewStyle(.stack)
    }
    private func submit() { submitted = String(query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)); reload() }
    private func reload() { loadTask?.cancel(); generation = UUID(); items = []; page = 0; more = false; loading = false; load(reset: true) }
    private func load(reset: Bool) {
        if loading || (searching && submitted.isEmpty) { return }
        let id = generation, requested = reset ? 1 : page + 1, category = kind, text = submitted
        loading = true; error = nil
        loadTask = Task { @MainActor in
            do {
                let result = try await Repository.shared.catalog(category,page: requested,query: searching ? text : "")
                try Task.checkCancellation(); guard id == generation else { return }
                var seen = Set(items.map(\.id)); items += result.items.filter { seen.insert($0.id).inserted }
                page = requested; more = result.more; loading = false
            } catch is CancellationError { }
            catch { if id == generation { self.error = error.localizedDescription; loading = false } }
        }
    }
}

struct DetailScreen: View {
    let series: Series
    var cloudResume: WatchProgress? = nil
    @EnvironmentObject private var library: Library
    @ObservedObject private var account = Account.shared
    @State private var cloudFavorite = false
    @State private var accountBusy = false
    @State private var accountError: String?
    @State private var detail: Detail?
    @State private var error: String?
    @State private var retry = 0
    @State private var playback: PlaybackSelection?
    struct PlaybackSelection: Identifiable { let id = UUID(); let detail: Detail; let index: Int; let position: Double }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading,spacing: 20) {
                HStack(alignment: .top,spacing: 20) {
                    Poster(series: detail?.series ?? series).frame(width: 140)
                    VStack(alignment: .leading,spacing: 15) {
                        Text(series.title).font(.title2.bold())
                        Text((detail?.series ?? series).tags).foregroundColor(.secondary)
                        Button { library.toggle(detail?.series ?? series) } label: { Label(library.favorite(series) ? "已收藏" : "收藏",systemImage: library.favorite(series) ? "heart.fill" : "heart") }.buttonStyle(.bordered)
                        if account.loggedIn {
                            Button(cloudFavorite ? "取消账号收藏" : "加入账号收藏") {
                                accountBusy = true; accountError = nil
                                Task {
                                    do { try await account.setFavorite(series,add: !cloudFavorite); cloudFavorite.toggle() }
                                    catch { accountError = error.localizedDescription }
                                    accountBusy = false
                                }
                            }.disabled(accountBusy).buttonStyle(.bordered)
                        }
                        if let detail = detail {
                            Button(resumeLabel(detail)) { resume(detail) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Text((detail?.series ?? series).summary).foregroundColor(.secondary)
                if let accountError = accountError { Text(accountError).foregroundColor(.orange) }
                if let error = error { Text(error).foregroundColor(.red); Button("重试") { retry += 1 } }
                else if let detail = detail {
                    if let episode = detail.episodes.first {
                        NavigationLink("查看首集评论与剧评",destination: CommentsScreen(series: series.id,episode: episode))
                    }
                    Text("选集 · 共 \(detail.episodes.count) 集").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 65))],spacing: 12) {
                        ForEach(detail.episodes.indices,id: \.self) { index in
                            Button("\(index + 1)") { playback = PlaybackSelection(detail: detail,index: index,position: 0) }
                                .frame(maxWidth: .infinity,minHeight: 44).background(Color.secondary.opacity(0.12)).cornerRadius(8)
                        }
                    }
                } else { ProgressView("正在加载剧集…") }
            }.padding()
        }.navigationTitle("剧集详情").navigationBarTitleDisplayMode(.inline)
            .task(id: retry) {
                error = nil
                do { detail = try await Repository.shared.detail(series.id) }
                catch is CancellationError { }
                catch { self.error = error.localizedDescription }
            }
            .task(id: account.loggedIn) {
                if account.loggedIn {
                    do { cloudFavorite = try await account.favorites().contains { $0.id == series.id } }
                    catch { accountError = error.localizedDescription }
                }
            }
            .fullScreenCover(item: $playback) { selection in
                PlaybackContainer(model: PlayerModel(detail: selection.detail,index: selection.index,position: selection.position,library: library),onBack: { playback = nil })
            }
    }
    private func resumeLabel(_ detail: Detail) -> String {
        guard let progress = cloudResume ?? library.state.progress[series.id], let i = detail.episodes.firstIndex(of: progress.episodeID) else { return "开始播放" }
        return "继续观看 · 第 \(min(i + (progress.completed ? 2 : 1),detail.episodes.count)) 集"
    }
    private func resume(_ detail: Detail) {
        if let progress = cloudResume ?? library.state.progress[series.id], let i = detail.episodes.firstIndex(of: progress.episodeID) {
            playback = PlaybackSelection(detail: detail,index: progress.completed && i + 1 < detail.episodes.count ? i + 1 : i,position: progress.completed ? 0 : progress.position)
        } else { playback = PlaybackSelection(detail: detail,index: 0,position: 0) }
    }
}

struct LocalLibraryScreen: View {
    let history: Bool
    @EnvironmentObject var library: Library
    var items: [Series] {
        history ? library.recent.map { progress in
            var series = progress.series; series.badge = "第 \(progress.index + 1) 集 · \(progress.completed ? "已看完" : "\(Int(progress.position / 60)) 分钟")"; return series
        } : library.state.favorites
    }
    var body: some View {
        NavigationView {
            ScrollView {
                if items.isEmpty { Text(history ? "播放后会在这里留下记录" : "收藏喜欢的短剧，下次接着看").foregroundColor(.secondary).padding(40) }
                SeriesGrid(items: items)
            }.navigationTitle(history ? "最近观看" : "本机收藏")
        }.navigationViewStyle(.stack)
    }
}

struct SettingsScreen: View {
    @EnvironmentObject var library: Library
    @AppStorage("autoNext") private var autoNext = true
    @State private var confirmClear = false
    var body: some View {
        NavigationView {
            Form {
                Section("账户") {
                    NavigationLink("红果扫码登录与云端片单",destination: AccountScreen())
                    Text("账号收藏、云端历史与本机记录分开保存。").font(.footnote).foregroundColor(.secondary)
                }
                Section("播放") {
                    Toggle("自动播放下一集",isOn: $autoNext)
                    Text("播放器支持横竖屏、系统全屏、AirPlay、画中画、倍速、清晰度和定时停止。").font(.footnote).foregroundColor(.secondary)
                }
                Section("本机数据") {
                    Text("\(library.state.favorites.count) 部收藏 · \(library.state.progress.count) 条观看记录")
                    Button("清空观看记录",role: .destructive) { confirmClear = true }
                }
                Section("关于") {
                    Text("红果 TV · iPad 原生版 0.16.13")
                    Text("iOS 15.0 及以上 · SwiftUI / AVPlayer")
                    Text("播放引擎：Drama SDI 会话 · build 6")
                    Text("内容请求和视频处理均在本机执行，无需伴机服务。")
                    Link("源代码与许可证",destination: URL(string: "https://github.com/Blueanr/hongguoTV")!)
                    Text("个人非官方客户端，与红果官方无关联。接口变化可能影响使用。").font(.footnote).foregroundColor(.secondary)
                }
            }.navigationTitle("设置")
                .confirmationDialog("清空所有本机观看记录？",isPresented: $confirmClear,titleVisibility: .visible) {
                    Button("清空记录",role: .destructive) { library.clearHistory() }
                }
        }.navigationViewStyle(.stack)
    }
}
