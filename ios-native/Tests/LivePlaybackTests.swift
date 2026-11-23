// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AVFoundation
@testable import HongguoPad

// Explicit opt-in: real anonymous registration and network requests, no account.
final class LivePlaybackTests: XCTestCase {
    func testProductionDramaPlaybackModels() async throws {
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
            print("Drama SDI live episode index \(index): \(rows.count) renditions, MP4 Range OK")
            if index == 0 { try await verifyPlayer(row) }
        }
    }
    @MainActor private func verifyPlayer(_ row: Rendition) async throws {
        let resource = MediaResource(row)
        let item = AVPlayerItem(asset: resource.asset())
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil); resource.cancel() }
        player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            if item.status == .failed {
                let error = item.error as NSError?
                let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
                XCTFail("AVPlayer failed: \(error?.domain ?? "unknown") / \(error?.code ?? 0); underlying \(underlying?.domain ?? "none") / \(underlying?.code ?? 0)")
                return
            }
            if item.status == .readyToPlay && player.currentTime().seconds >= 0.5 {
                print("AVPlayer ready and playback clock advanced through MediaResource")
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("AVPlayer did not advance within 45 seconds; status \(item.status.rawValue)")
    }
}
