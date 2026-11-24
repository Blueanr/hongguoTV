// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI
import AVFoundation

@MainActor final class PlayerModel: ObservableObject {
    let detail: Detail
    let library: Library
    @Published var index: Int
    @Published var loading = false
    @Published var error: String?
    @Published var qualities: [Int] = []
    @Published var quality = 720
    @Published var rate: Float = 1
    @Published var sleepMinutes = 0
    @Published private(set) var player: HGMPVPlayer?
    @Published private(set) var paused = true
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var diagnostic = "libmpv · 正在准备"
    @Published private(set) var playbackState: [String:Any] = [:]
    private var sleepTask: Task<Void,Never>?
    private var loadTask: Task<Void,Never>?
    private let audioOwner = UUID()
    private var active = false
    private let resolve: (String) async throws -> [Rendition]
    private let makeBytes: (Rendition) -> MediaBytes
    private let defaults: UserDefaults
    private var generation = UUID()
    private var currentEpisode: Int?
    private var initialPosition: Double
    private var lastSave = Date.distantPast
    private var lastUpload = Date.distantPast
    private var uploading = false
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var resumeAfterInterruption = false
    init(detail: Detail,index: Int,position: Double,library: Library,defaults: UserDefaults = .standard,
         resolve: @escaping (String) async throws -> [Rendition] = { try await Repository.shared.streams($0) },
         makeBytes: @escaping (Rendition) -> MediaBytes = { MediaBytes($0) }) {
        self.detail = detail; self.index = index; self.initialPosition = position; self.library = library
        self.defaults = defaults; self.resolve = resolve; self.makeBytes = makeBytes
        let saved = defaults.float(forKey: PlaybackSpeed.key)
        rate = PlaybackSpeed.valid(saved) ? saved : 1
    }
    func start() {
        guard !active else { return }
        do { try PlaybackAudioSession.activate(audioOwner) }
        catch { self.error = PlaybackFailure(stage: "音频会话初始化",cause: error).localizedDescription; return }
        active = true
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,object: nil,queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self = self,self.active else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.resumeAfterInterruption = !self.paused; self.setPaused(true)
                } else if self.resumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
                    self.resumeAfterInterruption = false; self.setPaused(false)
                }
            }
        }
        routeObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification,object: nil,queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.setPaused(true) }
            }
        }
        load(index,position: initialPosition)
    }
    func load(_ newIndex: Int,position start: Double = 0,autoplay: Bool = true) {
        guard active,detail.episodes.indices.contains(newIndex) else { return }
        save(); currentEpisode = nil
        loadTask?.cancel(); MPVLifetime.retire(player); player = nil
        generation = UUID(); let id = generation
        index = newIndex; error = nil; loading = true; paused = !autoplay
        position = max(0,start); duration = 0; playbackState = [:]
        loadTask = Task {
            do {
                let streams = try await resolve(detail.episodes[newIndex])
                try Task.checkCancellation()
                guard generation == id,active else { return }
                qualities = Array(Set(streams.map(\.quality).filter { $0 > 0 })).sorted(by: >)
                guard let selected = streams.first(where: { $0.quality <= quality && $0.quality > 0 }) ?? streams.last else { throw HGError.message("没有兼容的播放资源") }
                let bytes = makeBytes(selected)
                let (_,length) = try await bytes.prepare()
                try Task.checkCancellation()
                guard generation == id,active else { return }
                await MPVLifetime.waitForRetirement()
                try Task.checkCancellation()
                guard generation == id,active else { return }
                try PlaybackAudioSession.activate(audioOwner)
                let source = MPVMediaSource(bytes: bytes,length: length)
                let engine = HGMPVPlayer(source: source)
                currentEpisode = newIndex
                engine.onUpdate = { [weak self] state in
                    // HGMPVPlayer delivers state exclusively on the main queue.
                    Task { @MainActor in
                        guard let self = self,self.active,self.generation == id else { return }
                        self.receive(state,quality: selected.quality,codec: selected.codec)
                    }
                }
                player = engine
                engine.open(at: max(0,start),speed: Double(rate))
                if !autoplay { engine.setPaused(true) }
            } catch is CancellationError { }
            catch { if generation == id { self.error = PlaybackFailure.describe(error) + "\niOS \(UIDevice.current.systemVersion) · libmpv · build 11"; loading = false } }
        }
    }
    private func receive(_ state: [String:Any],quality: Int,codec: String) {
        playbackState = state
        if let message = state["error"] as? String {
            error = "\(message)\n\(quality)P · \(codec) · libmpv · build 11"; loading = false; return
        }
        let loaded = state["loaded"] as? Bool ?? false
        loading = !loaded || (state["buffering"] as? Bool ?? false)
        if loaded {
            position = state["position"] as? Double ?? position
            duration = state["duration"] as? Double ?? duration
            paused = state["paused"] as? Bool ?? paused
        }
        let hw = state["hwdec"] as? String ?? ""
        let drops = (state["dropped"] as? Double ?? 0) + (state["decoderDropped"] as? Double ?? 0)
        let sync = state["avsync"] as? Double ?? 0
        diagnostic = "libmpv · \(quality)P \(codec) · 硬解 \(hw.isEmpty ? "准备中" : hw) · 丢帧 \(Int(drops)) · A/V \(String(format: "%.3f",sync))s"
        if Date().timeIntervalSince(lastSave) >= 5 { save(); lastSave = Date() }
        if state["ended"] as? Bool == true {
            save(completed: true)
            if defaults.object(forKey: "autoNext") as? Bool ?? true,detail.episodes.indices.contains(index + 1) { load(index + 1) }
            else { setPaused(true) }
        }
    }
    func save(completed: Bool = false) {
        guard let currentEpisode = currentEpisode,duration > 0,position.isFinite,duration.isFinite else { return }
        let progress = WatchProgress(series: detail.series,episodeID: detail.episodes[currentEpisode],index: currentEpisode,position: completed ? duration : position,duration: duration)
        library.record(progress)
        if Account.shared.loggedIn && !uploading && (completed || Date().timeIntervalSince(lastUpload) >= 30) {
            lastUpload = Date(); uploading = true
            Task { await Account.shared.upload(progress,count: detail.episodes.count); uploading = false }
        }
    }
    func setQuality(_ value: Int) { quality = value; load(index,position: position,autoplay: !paused) }
    func setRate(_ value: Float) {
        guard PlaybackSpeed.valid(value) else { return }
        rate = (value * 100).rounded() / 100
        defaults.set(rate,forKey: PlaybackSpeed.key)
        player?.setSpeed(Double(rate))
    }
    func setPaused(_ value: Bool) {
        if !value {
            do { try PlaybackAudioSession.activate(audioOwner) }
            catch { self.error = "音频会话：\(error.localizedDescription)"; return }
        }
        paused = value; player?.setPaused(value)
    }
    func seek(_ value: Double) {
        guard value.isFinite,duration > 0 else { return }
        position = max(0,min(duration,value)); player?.seek(to: position)
    }
    func setSleep(_ minutes: Int) {
        sleepTask?.cancel(); sleepMinutes = minutes
        guard minutes > 0 else { return }
        sleepTask = Task {
            do { try await Task.sleep(nanoseconds: UInt64(minutes) * 60 * 1_000_000_000); setPaused(true); save(); sleepMinutes = 0 }
            catch { }
        }
    }
    func stop() {
        save(); active = false; generation = UUID(); loading = false
        loadTask?.cancel(); sleepTask?.cancel()
        MPVLifetime.retire(player,releaseAudio: audioOwner); player = nil; paused = true
        for observer in [interruptionObserver,routeObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        interruptionObserver = nil; routeObserver = nil; currentEpisode = nil
    }
}

struct NativePlayer: UIViewRepresentable {
    let player: HGMPVPlayer
    func makeUIView(context: Context) -> HGMPVPlayer { player }
    func updateUIView(_ view: HGMPVPlayer,context: Context) { }
}

struct PlaybackScreen: View {
    @Environment(\.scenePhase) private var phase
    @StateObject var model: PlayerModel
    let onBack: () -> Void
    @State private var customSpeed = false
    @State private var fullscreen = false
    @State private var scrubbing = false
    @State private var scrubPosition: Double = 0
    private var video: some View {
        ZStack {
            Color.black
            if let player = model.player { NativePlayer(player: player).id(ObjectIdentifier(player)) }
            if model.loading { ProgressView("正在准备视频…").padding().background(.ultraThinMaterial).cornerRadius(12) }
        }
    }
    private var controls: some View {
        VStack(spacing: 6) {
            HStack {
                Button { model.setPaused(!model.paused) } label: { Image(systemName: model.paused ? "play.fill" : "pause.fill").frame(width: 36,height: 36) }.accessibilityLabel(model.paused ? "播放" : "暂停")
                Button { model.seek(model.position - 10) } label: { Image(systemName: "gobackward.10") }
                Slider(value: Binding(get: { scrubbing ? scrubPosition : min(model.position,max(1,model.duration)) },set: { scrubPosition = $0 }),in: 0...max(1,model.duration),onEditingChanged: { editing in
                    if editing { scrubPosition = model.position; scrubbing = true }
                    else { scrubbing = false; model.seek(scrubPosition) }
                }).disabled(model.duration <= 0).accessibilityLabel("播放进度")
                Button { model.seek(model.position + 10) } label: { Image(systemName: "goforward.10") }
                Text("\(clock(model.position))/\(clock(model.duration))").font(.caption.monospacedDigit())
                Button { fullscreen.toggle() } label: { Image(systemName: fullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") }.accessibilityLabel(fullscreen ? "退出全屏" : "全屏")
            }
            Text(model.diagnostic).font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity,alignment: .leading)
        }.padding(.horizontal)
    }
    private func clock(_ seconds: Double) -> String {
        let value = max(0,Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d",value / 60,value % 60)
    }
    var body: some View {
        NavigationView {
            GeometryReader { geo in
                VStack(spacing: 0) {
                    video.frame(height: fullscreen ? max(160,geo.size.height - 85) : max(180,geo.size.height * 0.56))
                    controls
                    if let error = model.error {
                        HStack { Text(error).font(.callout); Button("重试") { model.load(model.index,position: model.position) } }.padding().foregroundColor(.red)
                    }
                    if !fullscreen {
                        HStack {
                            Button("上一集") { model.load(model.index - 1) }.disabled(model.index == 0)
                            Spacer(); Text("第 \(model.index + 1) / \(model.detail.episodes.count) 集"); Spacer()
                            Button("下一集") { model.load(model.index + 1) }.disabled(model.index + 1 == model.detail.episodes.count)
                        }.padding()
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64))],spacing: 10) {
                                ForEach(model.detail.episodes.indices,id: \.self) { i in
                                    Button("\(i + 1)") { model.load(i) }.frame(maxWidth: .infinity,minHeight: 44)
                                        .background(i == model.index ? Color.accentColor.opacity(0.25) : Color.secondary.opacity(0.12)).cornerRadius(8)
                                }
                            }.padding(.horizontal)
                        }
                    }
                }
            }
            .navigationTitle(model.detail.series.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(action: onBack) { Label("返回",systemImage: "chevron.left") } }
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
            .onChange(of: phase) { if $0 != .active { model.save(); model.setPaused(true) } }
    }
}
