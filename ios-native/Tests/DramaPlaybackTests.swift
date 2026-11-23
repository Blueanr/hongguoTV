// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

final class DramaPlaybackTests: XCTestCase {
    func testSessionCompressionRejectsTruncatedAndOversizedFrames() throws {
        let plain = Data(repeating: 0x41,count: 4096)
        let compressed = try Crypto.gzip(plain,window: 15)
        XCTAssertEqual(try Crypto.inflate(compressed),plain)
        XCTAssertThrowsError(try Crypto.inflate(Data(compressed.dropLast())))
        XCTAssertThrowsError(try Crypto.inflate(compressed,limit: 1024))
        XCTAssertThrowsError(try Crypto.inflate(compressed + Data([0])))
    }
    func testRegistrationIdentityAndExactEpisodeBody() throws {
        var params = DramaPlayback.registrationParams(now: 1795480000000,cdid: "synthetic-installation",openudid: "synthetic")
        XCTAssertFalse(DramaPlayback.valid(.init(params: params,cookies: [:])))
        params["device_id"] = "1234567890123456789"; params["iid"] = "9876543210123456789"
        XCTAssertTrue(DramaPlayback.valid(.init(params: params,cookies: [:])))
        XCTAssertFalse(DramaPlayback.valid(.init(params: params,cookies: ["store-region-src":"uid"])))
        let bytes = try Crypto.inflate(DramaPlayback.body("123456789"),window: 31)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? JSON)
        XCTAssertEqual(json.object("mixed_video_id_map")["1004"] as? [String],["123456789"])
        XCTAssertEqual(json.object("biz_param").number("device_level"),4)
        XCTAssertEqual(json.text("dr_scene"),"player")
    }
    func testNativeSessionCryptoBridge() throws {
        XCTAssertEqual(Crypto.hash("sha1",Data("abc".utf8)).hex,"a9993e364706816aba3e25717850c26c9cd0d89d")
        let key = Data(repeating: 7,count: 16),iv = Data(repeating: 0,count: 16),data = Data("SDK configuration".utf8)
        let encrypted = try Crypto.aes(data,key: key,iv: iv,encrypt: true,padding: true,ecb: true)
        XCTAssertEqual(try Crypto.aes(encrypted,key: key,iv: iv,padding: true,ecb: true),data)
    }
}
