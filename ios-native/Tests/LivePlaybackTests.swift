// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AVFoundation
@testable import HongguoPad

// Explicit opt-in: real anonymous registration and network requests, no account.
final class LivePlaybackTests: XCTestCase {
    func testProductionUpstreamPlaybackModels() async throws {
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
            print("Upstream 0.16.14 live episode index \(index): \(rows.count) renditions, MP4 Range OK")
            if index == 0 {
                // Match PlayerModel's default 720P choice, rather than testing
                // only the highest-quality stream returned by the endpoint.
                let selected = try XCTUnwrap(rows.first(where: { $0.quality <= 720 && $0.quality > 0 }) ?? rows.last)
                try await verifyPlayer(selected)
            }
        }
    }
    @MainActor private func verifyPlayer(_ row: Rendition) async throws {
        let resource = MediaResource(row)
        let item = AVPlayerItem(asset: resource.asset())
        PlaybackTuning.apply(item,rate: 1)
        let player = AVPlayer(playerItem: item)
        defer { player.pause(); player.replaceCurrentItem(with: nil); resource.cancel() }
        player.play()
        let deadline = ProcessInfo.processInfo.systemUptime + 45
        while ProcessInfo.processInfo.systemUptime < deadline {
            if item.status == .failed {
                let error = item.error as NSError?
                let underlying = error?.userInfo[NSUnderlyingErrorKey] as? NSError
                XCTFail("AVPlayer failed: \(error?.domain ?? "unknown") / \(error?.code ?? 0); underlying \(underlying?.domain ?? "none") / \(underlying?.code ?? 0); \(resource.diagnostic)")
                return
            }
            if item.status == .readyToPlay && player.currentTime().seconds >= 0.5 {
                let target = min(10,item.duration.seconds / 2)
                XCTAssertTrue(target.isFinite && target > 0)
                let sought = await player.seek(to: CMTime(seconds: target,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero)
                XCTAssertTrue(sought)
                let seekDeadline = ProcessInfo.processInfo.systemUptime + 20
                while ProcessInfo.processInfo.systemUptime < seekDeadline && player.currentTime().seconds < target + 0.5 && item.status != .failed {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                XCTAssertNotEqual(item.status,.failed,resource.diagnostic)
                XCTAssertGreaterThanOrEqual(player.currentTime().seconds,target + 0.5)
                print("AVPlayer default \(row.quality)P ready, clock advanced, seek and resume passed; \(resource.diagnostic)")
                for rate in [Float(3),Float(4)] {
                    player.pause()
                    _ = await player.seek(to: CMTime(seconds: 1,preferredTimescale: 600),toleranceBefore: .zero,toleranceAfter: .zero)
                    PlaybackTuning.apply(item,rate: rate)
                    player.rate = rate
                    let warmup = ProcessInfo.processInfo.systemUptime + 15
                    while player.timeControlStatus != .playing && item.status != .failed && ProcessInfo.processInfo.systemUptime < warmup {
                        try await Task.sleep(nanoseconds: 100_000_000)
                    }
                    XCTAssertEqual(player.timeControlStatus,.playing)
                    let wallStart = ProcessInfo.processInfo.systemUptime,mediaStart = player.currentTime().seconds
                    var waiting = 0
                    for _ in 0..<30 {
                        try await Task.sleep(nanoseconds: 100_000_000)
                        if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { waiting += 1 }
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - wallStart
                    let advanced = player.currentTime().seconds - mediaStart
                    XCTAssertNotEqual(item.status,.failed,resource.diagnostic)
                    XCTAssertGreaterThan(advanced,elapsed * Double(rate) * 0.75,"High-rate clock throughput")
                    print("AVPlayer \(rate)x: advanced \(advanced)s in \(elapsed)s; waiting samples \(waiting)/30; fast-forward capability \(item.canPlayFastForward)")
                }
                return
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("AVPlayer did not advance within 45 seconds; status \(item.status.rawValue)")
    }
}
