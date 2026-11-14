// SPDX-License-Identifier: GPL-3.0-only
import Foundation

typealias JSON = [String: Any]
extension Dictionary where Key == String, Value == Any {
    func text(_ key: String) -> String {
        guard let value = self[key], !(value is NSNull) else { return "" }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func object(_ key: String) -> JSON { self[key] as? JSON ?? [:] }
    func rows(_ key: String) -> [JSON] { self[key] as? [JSON] ?? [] }
    func number(_ key: String) -> Int { Int(text(key)) ?? 0 }
    func flag(_ key: String) -> Bool { ["1", "true"].contains(text(key)) }
}
struct Series: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var cover: String = ""
    var summary: String = ""
    var badge: String = ""
    var tags: String = ""
    init(id: String, title: String, cover: String = "", summary: String = "", badge: String = "", tags: String = "") {
        self.id = id; self.title = title; self.cover = cover; self.summary = summary; self.badge = badge; self.tags = tags
    }
    init(_ item: JSON) {
        let row = item["video_data"] as? JSON ?? item
        id = row.text("series_id")
        title = [row.text("series_name"), row.text("series_title"), item.text("name")].first { !$0.isEmpty } ?? ""
        cover = row.text("series_cover").replacingOccurrences(of: "&amp;", with: "&")
        summary = row.text("series_intro")
        let count = max(row.number("episode_cnt"), row.object("series_episode_info").number("episode_cnt"))
        badge = row.text("episode_right_text").isEmpty ? (count > 0 ? "全 \(count) 集" : "") : row.text("episode_right_text")
        let values = row["tags"] as? [Any] ?? row["category_list"] as? [Any] ?? []
        tags = values.prefix(5).map { ($0 as? JSON)?.text("name") ?? String(describing: $0) }.joined(separator: " · ")
    }
    var valid: Bool { id.range(of: "^[0-9]{1,30}$", options: .regularExpression) != nil && !title.isEmpty }
}
struct Detail { let series: Series; let episodes: [String] }
struct CatalogPage { let items: [Series]; let more: Bool }
struct Rendition {
    let url: URL
    let key: Data?
    let quality: Int
    let codec: String
}
struct WatchProgress: Codable {
    var series: Series
    var episodeID: String
    var index: Int
    var position: Double
    var duration: Double
    var updatedAt: Date = Date()
    var completed: Bool { duration > 0 && position >= duration - 5 }
}
enum CatalogKind: String, CaseIterable, Identifiable {
    case recommended = "推荐", real = "真人剧", comic = "漫剧", ai = "AI 剧", ranking = "热播榜"
    var id: String { rawValue }
    var route: String {
        switch self {
        case .real: return "real-drama"
        case .comic: return "comic-drama"
        case .ai: return "ai-drama"
        default: return ""
        }
    }
}

enum RouterParser {
    // Balanced scan, never evaluate remote scripts. Mirrors ContentRepository.extractRouter.
    static func extract(_ html: String) throws -> JSON {
        guard let marker = html.range(of: "_ROUTER_DATA"), let start = html[marker.upperBound...].firstIndex(of: "{") else { throw HGError.message("页面没有路由数据") }
        var depth = 0, quoted = false, escaped = false
        for at in html[start...].indices {
            let c = html[at]
            if quoted {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                continue
            }
            if c == "\"" { quoted = true }
            else if c == "{" || c == "[" { depth += 1 }
            else if c == "}" || c == "]" {
                depth -= 1
                if depth == 0 {
                    guard let root = try JSONSerialization.jsonObject(with: Data(html[start...at].utf8)) as? JSON else { break }
                    return root.object("loaderData")
                }
            }
        }
        throw HGError.message("路由数据不完整")
    }
}
