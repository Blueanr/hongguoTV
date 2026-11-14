// SPDX-License-Identifier: GPL-3.0-only
import SwiftUI

struct PublicReview: Identifiable {
    let id: String
    let author: String
    let content: String
    let likes: Int
}
struct CommentsScreen: View {
    let series: String
    let episode: String
    @State private var reviews: [PublicReview] = []
    @State private var comments: [PublicReview] = []
    @State private var error: String?
    @State private var loading = true
    @State private var retry = 0
    var body: some View {
        List {
            if loading { ProgressView("正在加载评论…") }
            if let error = error { Text(error).foregroundColor(.red); Button("重试") { retry += 1 } }
            Section("剧评") { rows(reviews) }
            Section("本集评论") { rows(comments) }
            Section { Text("展示官网公开评论预览，最多每类 50 条。").font(.footnote).foregroundColor(.secondary) }
        }.navigationTitle("评论与剧评")
            .task(id: retry) {
                loading = true; error = nil
                do {
                    async let detailRequest = Repository.shared.router("/detail?series_id=\(series)")
                    async let playerRequest = Repository.shared.router("/player/\(series)/\(episode)")
                    let (detail,player) = try await (detailRequest,playerRequest)
                    let detailPage = detail.object("detail_page")
                    guard detailPage.object("seriesDetail").text("series_id") == series,
                          let playerPage = player.values.compactMap({ $0 as? JSON }).first(where: { $0.object("seriesDetail").text("series_id") == series && $0.text("vid") == episode }) else { throw HGError.message("评论剧集不匹配") }
                    reviews = Self.parse(detailPage.object("seriesSocialInfo").object("reviews"))
                    comments = Self.parse(playerPage.object("episodeSocialInfo").object("reviews"))
                } catch is CancellationError { }
                catch { self.error = error.localizedDescription }
                loading = false
            }
    }
    @ViewBuilder private func rows(_ values: [PublicReview]) -> some View {
        if values.isEmpty && !loading && error == nil { Text("暂无公开评论").foregroundColor(.secondary) }
        ForEach(values) { row in
            VStack(alignment: .leading,spacing: 8) {
                HStack { Text(row.author.isEmpty ? "红果用户" : row.author).font(.headline); Spacer(); Label("\(row.likes)",systemImage: "hand.thumbsup").font(.caption).foregroundColor(.secondary) }
                Text(row.content).textSelection(.enabled)
            }.padding(.vertical,5)
        }
    }
    private static func parse(_ object: JSON) -> [PublicReview] {
        var seen = Set<String>()
        return object.rows("reviews").prefix(100).compactMap { row in
            let text = String(row.text("content").prefix(20_000)), author = String(row.text("user_name").prefix(200))
            guard !text.isEmpty else { return nil }
            let id = Crypto.hash("sha256",Data((author + "\u{0}" + row.text("create_time") + "\u{0}" + text).utf8)).hex
            guard seen.insert(id).inserted else { return nil }
            return PublicReview(id: id,author: author,content: text,likes: max(0,row.number("digg_count")))
        }.prefix(50).map { $0 }
    }
}
