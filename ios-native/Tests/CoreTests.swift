// SPDX-License-Identifier: GPL-3.0-only
import XCTest
import AVFoundation
@testable import HongguoPad

final class CoreTests: XCTestCase {
    @MainActor func testOldPlayerStopCannotInterruptNewAudioSession() throws {
        let first = UUID(),second = UUID()
        try PlaybackAudioSession.activate(first)
        try PlaybackAudioSession.activate(second)
        PlaybackAudioSession.release(first)
        // The old player's delayed stop must not release the new owner's lease.
        XCTAssertTrue(PlaybackAudioSession.isOwner(second))
        PlaybackAudioSession.release(second)
        XCTAssertFalse(PlaybackAudioSession.isOwner(second))
    }
    func testCustomSpeedInputValidation() {
        XCTAssertEqual(PlaybackSpeed.parse(" 1.25 "),1.25)
        XCTAssertEqual(PlaybackSpeed.parse("1,75"),1.75)
        XCTAssertEqual(PlaybackSpeed.parse("0.25"),0.25)
        XCTAssertEqual(PlaybackSpeed.parse("4"),4)
        XCTAssertEqual(PlaybackSpeed.parse("1.376"),1.38)
        for text in ["", "abc", "NaN", "inf", "0", "-1", "0.24", "4.01"] {
            XCTAssertNil(PlaybackSpeed.parse(text),text)
        }
        XCTAssertNotEqual(PlaybackSpeed.label(1.25),PlaybackSpeed.label(1.2))
    }
    @MainActor func testSpeedPersistsWithoutResumingPausedPlayer() throws {
        let suite = "PlaybackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let detail = Detail(series: Series(id: "1",title: "Test"),episodes: [])
        let library = Library()
        let model = PlayerModel(detail: detail,index: 0,position: 0,library: library,defaults: defaults)
        XCTAssertEqual(model.rate,1)
        model.setRate(1.75)
        XCTAssertEqual(model.player.rate,0,"Changing speed must preserve pause")
        model.setRate(.nan); model.setRate(0); model.setRate(5)
        XCTAssertEqual(model.rate,1.75)
        let reopened = PlayerModel(detail: detail,index: 0,position: 0,library: library,defaults: defaults)
        XCTAssertEqual(reopened.rate,1.75)
        defaults.set(99,forKey: PlaybackSpeed.key)
        let repaired = PlayerModel(detail: detail,index: 0,position: 0,library: library,defaults: defaults)
        XCTAssertEqual(repaired.rate,1)
    }
    func testRouterIgnoresBracesInsideStrings() throws {
        let html = #"<script>window._ROUTER_DATA = {"loaderData":{"detail_page":{"title":"a } [ \" b"}}}; bad();</script>"#
        XCTAssertEqual(try RouterParser.extract(html).object("detail_page").text("title"), "a } [ \" b")
        XCTAssertThrowsError(try RouterParser.extract("_ROUTER_DATA = {\"loaderData\":"))
    }
    func testSM3KnownVectors() throws {
        let signer = Signer()
        XCTAssertEqual(try signer.sm3("abc"),"66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0")
        XCTAssertEqual(try signer.sm3(""),"1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b")
    }
    func testAESCTRKnownVectorAndPartialSample() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!
        let iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let plain = Data(hex: "6bc1bee22e409f96e93d7e117393172a")!
        let encrypted = Data(hex: "874d6191b620e3261bef6864990db6ce")!
        XCTAssertEqual(try Crypto.aes(encrypted,key: key,iv: iv,ctr: true),plain)
        XCTAssertThrowsError(try Crypto.aes(encrypted,key: Data(),iv: iv,ctr: true))
    }
    func testRejectMalformedMP4() {
        XCTAssertThrowsError(try MP4Index(data: Data([0,0,0,8]),encrypted: true))
        XCTAssertThrowsError(try MP4Index.uint(Data(repeating: 255,count: 8),0,8))
        XCTAssertThrowsError(try MP4Index.box(Data(hex:"0000000466747970")!,0,8))
    }
    func testRandomAccessDecryptionAndHeaderReplacement() throws {
        let key = Data(hex: "2b7e151628aed2a6abf7158809cf4f3c")!,iv = Data(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")!
        let plain = Data((0..<64).map(UInt8.init))
        let encrypted = try Crypto.aes(plain,key: key,iv: iv,ctr: true)
        let index = MP4Index(header: Data("HEAD".utf8),samples: [
            .init(start: 8,end: 33,iv: iv,encryptedOffset: 0),
            .init(start: 37,end: 76,iv: iv,encryptedOffset: 25)
        ])
        let wire = Data(repeating: 0,count: 8) + encrypted.prefix(25) + Data([9,8,7,6]) + encrypted.dropFirst(25)
        let expected = Data("HEAD".utf8) + Data(repeating: 0,count: 4) + plain.prefix(25) + Data([9,8,7,6]) + plain.dropFirst(25)
        XCTAssertEqual(try index.decrypt(wire,start: 0,key: key),expected)
        for start in [0,2,8,11,29,32,34,37,40,60] {
            let end = min(start + 13,wire.count)
            XCTAssertEqual(try index.decrypt(Data(wire[start..<end]),start: start,key: key),Data(expected[start..<end]),"offset \(start)")
        }
    }
    func testRenditionKeepsGoodRowsAndRejectsUnknownEncryption() {
        let model: JSON = ["video_list":[
            ["main_url":"https://example.org/video.mp4", "quality_desc":"720p", "codec_type":"h264"],
            ["main_url":"https://example.org/bad.mp4", "codec_type":"bytevc2"],
            ["main_url":"https://example.org/encrypted.mp4", "encrypt_info":["encrypt":true]],
            ["main_url":"not-a-url", "quality_desc":"1080p"]
        ]]
        let rows = Repository.renditions(model)
        XCTAssertEqual(rows.count,1); XCTAssertEqual(rows.first?.quality,720)
        XCTAssertEqual(rows.first?.url.absoluteString,"https://example.org/video.mp4")
    }
    func testSignerRequestBodyAndIdentity() async throws {
        let body = Data("{\"test\":true}".utf8)
        let request = try await Signer().request(base: "https://example.org/model",values: DeviceSession.base.merging(["device_id":"12345","iid":"67890"]) { _,new in new },body: body,playback: true)
        XCTAssertEqual(request.httpBody,body)
        XCTAssertEqual(request.httpMethod,"POST")
        XCTAssertTrue(request.url!.absoluteString.contains("device_id=12345"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-ss-stub"),Crypto.hash("md5",body).hex.uppercased())
        XCTAssertFalse(request.value(forHTTPHeaderField: "x-medusa")!.isEmpty)
    }
}
