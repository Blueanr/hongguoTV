// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

// Explicit opt-in: real anonymous registration and network requests, no account.
final class LivePlaybackTests: XCTestCase {
    func testProductionSDKPlaybackModels() async throws {
        guard ProcessInfo.processInfo.environment["HONGGUO_LIVE_PLAYBACK"] == "1" else {
            throw XCTSkip("Set HONGGUO_LIVE_PLAYBACK=1 for real-network playback checks")
        }
        let repository = Repository()
        let catalog = try await repository.catalog(.recommended)
        let series = try XCTUnwrap(catalog.items.first)
        let detail = try await repository.detail(series.id)
        let indices = Set([0,min(53,detail.episodes.count - 1),detail.episodes.count - 1]).sorted()
        for index in indices {
            let rows = try await repository.streams(detail.episodes[index])
            XCTAssertFalse(rows.isEmpty)
            let row = try XCTUnwrap(rows.first)
            var request = URLRequest(url: row.url)
            request.setValue("bytes=0-1023",forHTTPHeaderField: "Range")
            let (bytes,response) = try await HTTP.shared.data(request,limit: 2048)
            XCTAssertEqual(response.statusCode,206)
            XCTAssertGreaterThanOrEqual(bytes.count,8)
            XCTAssertEqual(String(decoding: bytes.dropFirst(4).prefix(4),as: UTF8.self),"ftyp")
            print("openhongguo live episode index \(index): \(rows.count) renditions, MP4 Range OK")
        }
    }
}
