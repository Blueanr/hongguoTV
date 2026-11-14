// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVKit

@MainActor final class PlayerModel: ObservableObject {
    let player = AVPlayer()
    let detail: Detail
    let library: Library
    @Published var index: Int
    @Published var loading = false
    @Published var error: String?
    @Published var qualities: [Int] = []
    @Published var quality = 720
    @Published var rate: Float = 1
    @Published var sleepMinutes = 0
    private var sleepTask: Task<Void,Never>?
    private var loadTask: Task<Void,Never>?
    private var resource: MediaResource?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObserver: NSKeyValueObservation?
    private var rateObserver: NSKeyValueObservation?
    private let defaults: UserDefaults
    private var generation = UUID()
    private var currentEpisode: Int?
    private var initialPosition: Double
    private var lastUpload = Date.distantPast
    private var uploading = false
    init(detail: Detail,index: Int,position: Double,library: Library,defaults: UserDefaults = .standard) {
        self.detail = detail; self.index = index; self.initialPosition = position; self.library = library
        self.defaults = defaults
        let savedRate = defaults.float(forKey: PlaybackSpeed.key)
        rate = PlaybackSpeed.valid(savedRate) ? savedRate : 1
        if #available(iOS 16.0, *) { player.defaultRate = rate }
        // iOS 15's AVKit play button resumes at 1x. Reapply the preference only
        // while playing, never turn a paused player back on.
        rateObserver = player.observe(\.rate,options: [.new]) { [weak self] _,_ in
            Task { @MainActor in
                guard let self = self, self.player.rate > 0, self.player.rate != self.rate else { return }
                self.player.rate = self.rate
            }
        }
    }
    func start() {
        guard timeObserver == nil else { return }
        try? AVAudioSession.sharedInstance().setCategory(.playback,mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5,preferredTimescale: 600),queue: .main) { [weak self] _ in
            Task { @MainActor in self?.save() }
        }
        load(index,position: initialPosition)
    }
    func load(_ newIndex: Int,position: Double = 0) {
        guard detail.episodes.indices.contains(newIndex) else { return }
        save(); currentEpisode = nil; player.pause()
        loadTask?.cancel(); resource?.cancel(); resource = nil
        statusObserver = nil
        if let endObserver = endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.replaceCurrentItem(with: nil)
        generation = UUID(); let id = generation
        index = newIndex; error = nil; loading = true
        loadTask = Task {
            do {
                let streams = try await Repository.shared.streams(detail.episodes[newIndex])
                try Task.checkCancellation()
                guard generation == id else { return }
                qualities = Array(Set(streams.map(\.quality).filter { $0 > 0 })).sorted(by: >)
                guard let selected = streams.first(where: { $0.quality <= quality && $0.quality > 0 }) ?? streams.last else { throw HGError.message("没有兼容的播放资源") }
                let source = MediaResource(selected); resource = source
                let item = AVPlayerItem(asset: source.asset())
                currentEpisode = newIndex
                statusObserver = item.observe(\.status,options: [.new]) { [weak self] item,_ in
                    Task { @MainActor in
                        guard let self = self, self.generation == id else { return }
                        if item.status == .failed { self.loading = false; self.error = item.error?.localizedDescription ?? "播放失败，请重试或降低清晰度" }
                        if item.status == .readyToPlay { self.loading = false }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,object: item,queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self = self, self.generation == id else { return }
                        self.save(completed: true)
                        if UserDefaults.standard.object(forKey: "autoNext") as? Bool ?? true { self.load(newIndex + 1) }
                    }
                }
                player.replaceCurrentItem(with: item)
                if position > 0 { await player.seek(to: CMTime(seconds: position,preferredTimescale: 600)) }
                try Task.checkCancellation()
                player.playImmediately(atRate: rate)
            } catch is CancellationError { }
            catch { if generation == id { self.error = error.localizedDescription; loading = false } }
        }
    }
    func save(completed: Bool = false) {
        guard let currentEpisode = currentEpisode, let item = player.currentItem, item.status == .readyToPlay else { return }
        let position = player.currentTime().seconds, duration = item.duration.seconds
        guard position.isFinite, duration.isFinite else { return }
        let progress = WatchProgress(series: detail.series,episodeID: detail.episodes[currentEpisode],index: currentEpisode,position: completed ? duration : position,duration: duration)
        library.record(progress)
        if Account.shared.loggedIn && !uploading && (completed || Date().timeIntervalSince(lastUpload) >= 30) {
            lastUpload = Date(); uploading = true
            Task { await Account.shared.upload(progress,count: detail.episodes.count); uploading = false }
        }
    }
    func setQuality(_ value: Int) { quality = value; load(index,position: max(0,player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0)) }
    func setRate(_ value: Float) {
        guard PlaybackSpeed.valid(value) else { return }
        rate = (value * 100).rounded() / 100
        defaults.set(rate,forKey: PlaybackSpeed.key)
        if #available(iOS 16.0, *) { player.defaultRate = rate }
        if player.rate > 0 { player.rate = rate }
    }
    func setSleep(_ minutes: Int) {
        sleepTask?.cancel(); sleepMinutes = minutes
        guard minutes > 0 else { return }
        sleepTask = Task {
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000); player.pause(); save(); sleepMinutes = 0 }
            catch { }
        }
    }
    func stop() {
        save(); loadTask?.cancel(); sleepTask?.cancel(); player.pause(); resource?.cancel()
        statusObserver = nil
        if let timeObserver = timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver = endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.replaceCurrentItem(with: nil); currentEpisode = nil
        try? AVAudioSession.sharedInstance().setActive(false,options: .notifyOthersOnDeactivation)
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player
        controller.allowsPictureInPicturePlayback = true
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController,context: Context) { controller.player = player }
}

struct PlaybackScreen: View {
    @Environment(\.scenePhase) private var phase
    @StateObject var model: PlayerModel
    let onBack: () -> Void
    @State private var customSpeed = false
    var body: some View {
        NavigationView {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    NativePlayer(player: model.player).frame(height: max(200,geo.size.height * 0.65))
                        .overlay {
                            if model.loading { ProgressView("正在准备视频…").padding().background(.ultraThinMaterial).cornerRadius(12) }
                        }
                    if let error = model.error {
                        HStack { Text(error).font(.callout); Button("重试") { model.load(model.index) } }.padding().foregroundColor(.red)
                    }
                    HStack {
                        Button("上一集") { model.load(model.index - 1) }.disabled(model.index == 0)
                        Spacer()
                        Text("第 \(model.index + 1) / \(model.detail.episodes.count) 集")
                        Spacer()
                        Button("下一集") { model.load(model.index + 1) }.disabled(model.index + 1 == model.detail.episodes.count)
                    }.padding()
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))],spacing: 10) {
                            ForEach(model.detail.episodes.indices,id: \.self) { i in
                                Button("\(i + 1)") { model.load(i) }
                                    .frame(maxWidth: .infinity,minHeight: 44)
                                    .background(i == model.index ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)).cornerRadius(8)
                            }
                        }.padding(.horizontal)
                    }
                }
            }
            .navigationTitle(model.detail.series.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onBack) { Label("返回",systemImage: "chevron.left") }
                        .accessibilityHint("也可从屏幕左边缘向右滑返回剧集详情")
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Menu("倍速 · \(PlaybackSpeed.label(model.rate))") {
                            ForEach(PlaybackSpeed.presets,id: \.self) { rate in Button(PlaybackSpeed.label(rate)) { model.setRate(rate) } }
                            Button("自定义…") { customSpeed = true }
                        }
                        Menu("清晰度 · \(model.quality)P") { ForEach(model.qualities,id: \.self) { q in Button("\(q)P") { model.setQuality(q) } } }
                        Menu("定时停止\(model.sleepMinutes > 0 ? " · \(model.sleepMinutes)分钟" : "")") {
                            ForEach([0,15,30,60,90],id: \.self) { n in Button(n == 0 ? "关闭" : "\(n) 分钟") { model.setSleep(n) } }
                        }
                    } label: { Label("播放设置",systemImage: "slider.horizontal.3") }
                }
            }
        }.navigationViewStyle(.stack)
            .sheet(isPresented: $customSpeed) { CustomSpeedScreen(rate: model.rate,apply: model.setRate) }
            .onAppear { model.start() }.onDisappear { model.stop() }
            .onChange(of: phase) { if $0 != .active { model.save() } }
    }
}
