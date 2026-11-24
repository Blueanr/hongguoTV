// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AVFoundation
import QuartzCore
import CoreVideo
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
                try await verifyReentry(selected)
            }
        }
    }
    @MainActor private func verifyPlayer(_ row: Rendition) async throws {
        let resource = MediaResource(row)
        let item = AVPlayerItem(asset: resource.asset())
        PlaybackTuning.configure(item,rate: 1)
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
    @MainActor private func verifyReentry(_ row: Rendition) async throws {
        let suite = "PlaybackReentry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let detail = Detail(series: Series(id: "1",title: "Reentry"),episodes: ["123456789"])
        for pass in 0..<2 {
            let model = PlayerModel(detail: detail,index: 0,position: 0,library: Library(),defaults: defaults,resolve: { _ in [row] })
            defer { model.stop() }
            if pass == 1 { XCTAssertEqual(model.rate,3,"Restore speed on fresh player") }
            // Exercise the actual libmpv render API in a visible UIView. Simulator
            // uses software rendering; device uses OpenGL ES + automatic hwdec.
            let window = UIWindow(frame: CGRect(x: 0,y: 0,width: 640,height: 360))
            let controller = UIViewController(); window.rootViewController = controller
            window.makeKeyAndVisible()
            defer { window.isHidden = true }
            model.start()
            let deadline = ProcessInfo.processInfo.systemUptime + 45
            var attached = false
            while (model.loading || !attached || model.position < 0.25) && model.error == nil && ProcessInfo.processInfo.systemUptime < deadline {
                if let player = model.player,!attached {
                    player.frame = controller.view.bounds
                    controller.view.addSubview(player); player.setNeedsLayout(); player.layoutIfNeeded()
                    attached = true
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertNil(model.error)
            XCTAssertFalse(model.loading)
            guard model.error == nil,!model.loading else {
                throw HGError.message(model.error ?? "libmpv startup timed out")
            }
            XCTAssertNotNil(model.player)
            XCTAssertGreaterThan(model.duration,0)
            model.setRate(3)
            let warmup = ProcessInfo.processInfo.systemUptime + 15
            while (model.loading || (model.playbackState["speed"] as? Double != 3)) && ProcessInfo.processInfo.systemUptime < warmup {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            let firstFrames = (model.playbackState["frames"] as? NSNumber)?.intValue ?? 0
            let mediaStart = model.position
            for _ in 0..<90 {
                try await Task.sleep(nanoseconds: 33_000_000)
            }
            let frames = ((model.playbackState["frames"] as? NSNumber)?.intValue ?? 0) - firstFrames
            XCTAssertGreaterThan(frames,15,"Decoded video frames, not just an advancing clock")
            XCTAssertGreaterThan(model.position - mediaStart,6)
            XCTAssertEqual(model.playbackState["pitchCorrection"] as? Bool,true)
            XCTAssertFalse((model.playbackState["audio"] as? String ?? "").isEmpty)
            XCTAssertFalse((model.playbackState["audioOutput"] as? String ?? "").isEmpty)
#if targetEnvironment(simulator)
            XCTAssertEqual(model.playbackState["audioOutput"] as? String,"pcm")
            let pcmPath = try XCTUnwrap(model.playbackState["pcmPath"] as? String)
            let pcm = try Data(contentsOf: URL(fileURLWithPath: pcmPath))
            XCTAssertGreaterThan(pcm.count,4096,"Actual audio samples must reach the PCM output")
            XCTAssertTrue(pcm.contains { $0 != 0 },"Decoded audio must not be entirely silent")
            print("Simulator PCM capture: \(pcm.count) bytes with nonzero samples; no system audio backend in pinned simulator binary")
#else
            XCTAssertEqual(model.playbackState["audioOutput"] as? String,"audiounit")
#endif
            XCTAssertNil(model.error)
            print("libmpv 3x reentry pass \(pass + 1): \(frames) rendered frames, state \(model.playbackState); device speaker output requires validation")
            model.setPaused(true); model.setRate(4)
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertTrue(model.paused)
            XCTAssertEqual(model.playbackState["speed"] as? Double,4)
            let pausedPosition = model.position
            try await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(model.position,pausedPosition,accuracy: 0.1)
            model.seek(1)
            try await Task.sleep(nanoseconds: 500_000_000)
            model.setPaused(false)
            try await Task.sleep(nanoseconds: 2_000_000_000)
            XCTAssertGreaterThan(model.position,5,"Seek and resume at 4x")
            XCTAssertNil(model.error)
            model.setRate(3)
            model.player?.removeFromSuperview()
            model.stop()
        }
    }
}
