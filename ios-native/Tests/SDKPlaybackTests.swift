// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import Openhongguo
@testable import HongguoPad

final class SDKPlaybackTests: XCTestCase {
    func testProtectedSDKModelMapsExactKeyAndQuality() throws {
        let key = ContentKey(key: "00112233445566778899aabbccddeeff")
        let model = Playback(episodeId: "123",protected: true,streams: [
            Openhongguo.Stream(definition: "1080p",codec: "hevc",url: "https://example.org/video.mp4",protected: true,encryption: "cenc-aes-ctr"),
            Openhongguo.Stream(definition: "720p",codec: "h264",url: "invalid",backupUrl: "https://example.org/backup.mp4",protected: true,encryption: "cenc-aes-ctr")
        ])
        let rows = try SDKPlayback.renditions(model,key: key,episode: "123")
        XCTAssertEqual(rows.map(\.quality),[1080,720])
        XCTAssertEqual(rows.first?.key,Data(hex: key.key))
        XCTAssertEqual(rows.last?.url.host,"example.org")
        XCTAssertThrowsError(try SDKPlayback.renditions(model,key: nil,episode: "123"))
        XCTAssertThrowsError(try SDKPlayback.renditions(model,key: ContentKey(key: "00"),episode: "123"))
        XCTAssertThrowsError(try SDKPlayback.renditions(model,key: key,episode: "999"))
    }
    func testUnsupportedStreamsDoNotDiscardCompatibleMP4() throws {
        let model = Playback(episodeId: "123",streams: [
            Openhongguo.Stream(codec: "bytevc2",url: "https://example.org/bvc.mp4"),
            Openhongguo.Stream(url: "https://example.org/dash.mp4",dash: true),
            Openhongguo.Stream(url: "https://example.org/list.m3u8",hls: true),
            Openhongguo.Stream(codec: "h264",width: 720,height: 1280,url: "https://example.org/video.mp4")
        ])
        let rows = try SDKPlayback.renditions(model,key: nil,episode: "123")
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows[0].quality,720); XCTAssertNil(rows[0].key)
    }
    func testSDKRecoveryExhaustionAndRateLimitMessages() {
        XCTAssertTrue(SDKPlayback.message(OpenhongguoError(code: .anonymousLimited,message: "private")).contains("有限重试"))
        let message = SDKPlayback.message(OpenhongguoError(code: .rateLimited,message: "private",retryAfterMs: 30000))
        XCTAssertTrue(message.contains("30 秒")); XCTAssertFalse(message.contains("private"))
    }
}
