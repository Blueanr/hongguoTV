// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

final class MobilePlaybackTests: XCTestCase {
    private let device = ["iid":"12345","device_id":"67890","cdid":"test-cdid"]
    private let episode = "123456789"
    private func response(_ request: URLRequest,retry: Bool = false) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!,statusCode: 200,httpVersion: "HTTP/1.1",headerFields: retry ? ["Retry-After":"60"] : [:])!
    }
    private func payload(tab: Bool = false,codec: String = "h264",id: String = "123456789") throws -> Data {
        let model: JSON = ["video_list":[["main_url":"https://example.org/video.mp4","codec_type":codec,"vwidth":1080,"vheight":1920]]]
        let entry: JSON = [id:["video_model":model]]
        return try JSONSerialization.data(withJSONObject: ["code":0,"data":tab ? entry : ["1004":entry]])
    }
    func testV5PrimaryAndGetWireContract() async throws {
        let signer = Signer()
        let post = try await MobilePlayback.request(id: episode,device: device,signer: signer)
        XCTAssertEqual(post.url?.host,MobilePlayback.primaryHost)
        XCTAssertEqual(post.url?.path,"/novel/player/multi_video_model/player/v1")
        XCTAssertEqual(post.httpMethod,"POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Encoding"),"gzip")
        XCTAssertEqual(Array(try XCTUnwrap(post.httpBody).prefix(2)),[0x1f,0x8b])
        XCTAssertEqual(post.value(forHTTPHeaderField: "x-ss-stub"),Crypto.hash("md5",post.httpBody!).hex.uppercased())
        let get = try await MobilePlayback.request(id: episode,device: device,signer: signer,tab: true,host: MobilePlayback.alternateHost)
        XCTAssertEqual(get.httpMethod,"GET"); XCTAssertNil(get.httpBody)
        for request in [post,get] {
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-argus"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-gorgon"))
            for name in ["x-medusa","x-helios","x-khronos"] { XCTAssertFalse((request.value(forHTTPHeaderField: name) ?? "").isEmpty) }
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!,resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name,$0.value ?? "") })
            XCTAssertEqual(query["version_name"],"7.4.3.32")
            XCTAssertEqual(query["device_id"],device["device_id"])
            XCTAssertEqual(query["cdid"],device["cdid"])
        }
        for name in ["Content-Encoding","Content-Type","x-ss-stub"] { XCTAssertNil(get.value(forHTTPHeaderField: name)) }
    }
    func testPrimaryEmptyUsesV5GetForSameEpisode() async throws {
        var requests: [URLRequest] = []
        let rows = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
            requests.append(request)
            return (requests.count == 1 ? Data() : try self.payload(tab: true),self.response(request))
        }
        XCTAssertEqual(requests.map(\.httpMethod),["POST","GET"])
        XCTAssertEqual(rows.first?.quality,1080)
        let query = URLComponents(url: requests[1].url!,resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(query.first { $0.name == "video_id" }?.value,episode)
    }
    func testByteVC2TabUsesAlternateHostPost() async throws {
        var requests: [URLRequest] = []
        let rows = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
            requests.append(request)
            let bytes = requests.count == 1 ? Data() : try self.payload(tab: requests.count == 2,codec: requests.count == 2 ? "bytevc2" : "hevc")
            return (bytes,self.response(request))
        }
        XCTAssertEqual(requests.map(\.httpMethod),["POST","GET","POST"])
        XCTAssertEqual(requests.map { $0.url?.host },[MobilePlayback.primaryHost,MobilePlayback.alternateHost,MobilePlayback.alternateHost])
        XCTAssertEqual(rows.count,1)
        XCTAssertTrue(rows[0].codec.contains("hevc"))
    }
    func testBackoffMalformedAndWrongEpisodeDoNotFallback() async throws {
        for scenario in 0..<3 {
            var count = 0
            do {
                _ = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
                    count += 1
                    let bytes = scenario == 0 ? Data() : (scenario == 1 ? Data("invalid".utf8) : try self.payload(id: "999"))
                    return (bytes,self.response(request,retry: scenario == 0))
                }
                XCTFail("Expected failure for scenario \(scenario)")
            } catch { XCTAssertEqual(count,1) }
        }
    }
    func testCancellationStopsRecovery() async throws {
        var count = 0
        do {
            _ = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
                count += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError { XCTAssertEqual(count,1) }
    }
    func testEmptyRecoveryStopsAfterTwoRequests() async throws {
        var count = 0
        do {
            _ = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
                count += 1
                return (Data(),self.response(request))
            }
            XCTFail("Expected empty response error")
        } catch {
            XCTAssertEqual(count,2)
            XCTAssertTrue(error.localizedDescription.contains("空响应"))
        }
    }
    func testDictionaryRenditionQualityAndExactModelSelection() throws {
        let rows = Repository.renditions(["video_list":["720p":["main_url":"https://example.org/video.mp4","codec_type":"h264"]]])
        XCTAssertEqual(rows.first?.quality,720)
        let request = URLRequest(url: URL(string: "https://example.org/model")!)
        let raw = try JSONSerialization.data(withJSONObject: ["code":0,"data":["video_model_data":[episode:["video_model":"{\"video_list\":[]}"]]]])
        XCTAssertNotNil(try MobilePlayback.decode(raw,response: response(request),id: episode,tab: true)["video_list"])
        XCTAssertThrowsError(try MobilePlayback.decode(raw,response: response(request),id: "999",tab: true))
    }
}
