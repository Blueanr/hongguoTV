// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

final class MPVSourceTests: XCTestCase {
    @MainActor func testRetirementCompletesBeforeNewAudioOwnerStarts() async throws {
        let row = Rendition(url: URL(string: "https://example.org/video.mp4")!,key: nil,quality: 720,codec: "h264")
        let player = HGMPVPlayer(source: MPVMediaSource(bytes: MediaBytes(row),length: 1024))
        let old = UUID(),new = UUID()
        try PlaybackAudioSession.activate(old)
        MPVLifetime.retire(player,releaseAudio: old)
        await MPVLifetime.waitForRetirement()
        XCTAssertFalse(PlaybackAudioSession.isOwner(old))
        try PlaybackAudioSession.activate(new)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
            player.shutdown { continuation.resume() }
        }
        XCTAssertTrue(PlaybackAudioSession.isOwner(new),"Repeated old-player shutdown cannot close the new session")
        PlaybackAudioSession.release(new)
    }
    func testCancelledSourceWakesBlockedDemuxReader() async throws {
        let started = expectation(description: "Range request started")
        let row = Rendition(url: URL(string: "https://example.org/video.mp4")!,key: nil,quality: 720,codec: "h264")
        let bytes = MediaBytes(row,fetch: { _,_ in
            started.fulfill()
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw CancellationError()
        })
        let source = MPVMediaSource(bytes: bytes,length: 1024)
        let finished = expectation(description: "Cancelled demux read unblocked")
        DispatchQueue.global().async {
            XCTAssertNil(source.read(atOffset: 0,count: 256))
            finished.fulfill()
        }
        await fulfillment(of: [started],timeout: 3)
        source.cancel()
        await fulfillment(of: [finished],timeout: 1)
        XCTAssertNil(source.read(atOffset: 0,count: 10))
    }
    func testSourceBoundsAndEOF() {
        let row = Rendition(url: URL(string: "https://example.org/video.mp4")!,key: nil,quality: 720,codec: "h264")
        let source = MPVMediaSource(bytes: MediaBytes(row),length: 1024)
        XCTAssertEqual(source.read(atOffset: 1024,count: 10),Data())
        XCTAssertNil(source.read(atOffset: -1,count: 10))
        XCTAssertNil(source.read(atOffset: 1025,count: 10))
        source.cancel()
    }
}
