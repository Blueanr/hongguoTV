// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

final class CoreTests: XCTestCase {
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
