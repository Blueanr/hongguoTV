// SPDX-License-Identifier: GPL-3.0-only
import Foundation
import SwiftUI

@MainActor final class Library: ObservableObject {
    struct State: Codable { var favorites: [Series] = []; var progress: [String: WatchProgress] = [:] }
    @Published private(set) var state = State()
    @Published var error: String?
    private let file: URL
    private let writes = DispatchQueue(label: "com.hongguotv.library")
    private var unreadable = false
    init() {
        file = FileManager.default.urls(for: .applicationSupportDirectory,in: .userDomainMask)[0].appendingPathComponent("library.json")
        if FileManager.default.fileExists(atPath: file.path) {
            do { state = try JSONDecoder().decode(State.self,from: Data(contentsOf: file)) }
            catch { unreadable = true; self.error = "本机记录读取失败，原文件已保留" }
        }
    }
    func favorite(_ series: Series) -> Bool { state.favorites.contains { $0.id == series.id } }
    func toggle(_ series: Series) {
        if favorite(series) { state.favorites.removeAll { $0.id == series.id } }
        else { state.favorites.insert(series,at: 0) }
        save()
    }
    func record(_ progress: WatchProgress) {
        guard progress.position.isFinite, progress.duration.isFinite, progress.position >= 0 else { return }
        state.progress[progress.series.id] = progress
        if state.progress.count > 200 {
            let newest = state.progress.values.sorted { $0.updatedAt > $1.updatedAt }.prefix(200)
            state.progress = Dictionary(uniqueKeysWithValues: newest.map { ($0.series.id,$0) })
        }
        save()
    }
    var recent: [WatchProgress] { state.progress.values.sorted { $0.updatedAt > $1.updatedAt } }
    func clearHistory() { state.progress = [:]; save() }
    private func save() {
        // Do not overwrite an unreadable user library automatically.
        guard !unreadable else { return }
        do {
            let data = try JSONEncoder().encode(state), file = file
            writes.async {
                do {
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),withIntermediateDirectories: true)
                    try data.write(to: file,options: .atomic)
                } catch { Task { @MainActor in self.error = "本机记录保存失败，请检查存储空间" } }
            }
        } catch { self.error = "本机记录编码失败" }
    }
}
