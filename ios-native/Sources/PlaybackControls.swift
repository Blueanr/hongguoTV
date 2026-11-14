// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

enum PlaybackSpeed {
    static let key = "playbackRate"
    static let range: ClosedRange<Float> = 0.25...4
    static let presets: [Float] = [0.75,1,1.25,1.5,2,3,4]
    static func valid(_ value: Float) -> Bool { value.isFinite && range.contains(value) }
    static func parse(_ text: String) -> Float? {
        guard let value = Float(text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",",with: ".")), valid(value) else { return nil }
        return (value * 100).rounded() / 100
    }
    static func label(_ value: Float) -> String {
        let formatter = NumberFormatter()
        formatter.maximumFractionDigits = 2
        return (formatter.string(from: NSNumber(value: value)) ?? "1") + "×"
    }
}

struct CustomSpeedScreen: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    let apply: (Float) -> Void
    init(rate: Float,apply: @escaping (Float) -> Void) {
        _text = State(initialValue: String(format: "%.2f",rate)); self.apply = apply
    }
    var body: some View {
        NavigationView {
            Form {
                Section("播放速度") {
                    TextField("0.25～4.00",text: $text).keyboardType(.decimalPad)
                        .accessibilityLabel("自定义倍速")
                    Slider(value: Binding(get: { PlaybackSpeed.parse(text) ?? 1 },set: { text = String(format: "%.2f",$0) }),in: PlaybackSpeed.range,step: 0.05)
                        .accessibilityLabel("倍速滑杆")
                    Text(PlaybackSpeed.parse(text).map(PlaybackSpeed.label) ?? "请输入 0.25～4 之间的数字")
                        .foregroundColor(PlaybackSpeed.parse(text) == nil ? .red : .secondary)
                }
                Section {
                    Text("支持两位小数。应用后记住此速度，暂停后继续、切集和切换清晰度均会沿用。高倍速的流畅度取决于视频与设备。")
                        .font(.footnote).foregroundColor(.secondary)
                }
            }.navigationTitle("自定义倍速").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("应用") { if let rate = PlaybackSpeed.parse(text) { apply(rate); dismiss() } }
                            .disabled(PlaybackSpeed.parse(text) == nil)
                    }
                }
        }.navigationViewStyle(.stack)
    }
}

// A fullScreenCover has no navigation pop gesture. Attach a screen-edge gesture
// to this presentation's own hosting view, including its AVKit child views.
struct PlaybackContainer: UIViewControllerRepresentable {
    let model: PlayerModel
    let onBack: () -> Void
    func makeUIViewController(context: Context) -> PlaybackHostingController {
        PlaybackHostingController(model: model,onBack: onBack)
    }
    func updateUIViewController(_ controller: PlaybackHostingController,context: Context) { controller.onBack = onBack }
}

final class PlaybackHostingController: UIHostingController<PlaybackScreen>, UIGestureRecognizerDelegate {
    var onBack: () -> Void
    init(model: PlayerModel,onBack: @escaping () -> Void) {
        self.onBack = onBack
        super.init(rootView: PlaybackScreen(model: model,onBack: onBack))
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad()
        let swipe = UIScreenEdgePanGestureRecognizer(target: self,action: #selector(swipeBack(_:)))
        swipe.edges = .left; swipe.delegate = self
        view.addGestureRecognizer(swipe)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        // Let AVKit's separate fullscreen presentation and the speed editor
        // handle their own gestures instead of dismissing the underlying page.
        guard presentedViewController == nil, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.x > abs(velocity.y)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    @objc private func swipeBack(_ gesture: UIScreenEdgePanGestureRecognizer) {
        guard gesture.state == .ended else { return }
        let translation = gesture.translation(in: view), velocity = gesture.velocity(in: view)
        if translation.x > abs(translation.y) && (translation.x >= 80 || (translation.x >= 24 && velocity.x >= 500)) { onBack() }
    }
}
