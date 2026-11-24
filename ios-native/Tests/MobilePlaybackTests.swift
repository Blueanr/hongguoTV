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
        XCTAssertEqual(post.url?.path,"/novel/player/multi_video_model/preload/v1")
        XCTAssertEqual(post.httpMethod,"POST")
        XCTAssertEqual(post.value(forHTTPHeaderField: "Content-Encoding"),"gzip")
        XCTAssertEqual(Array(try XCTUnwrap(post.httpBody).prefix(2)),[0x1f,0x8b])
        XCTAssertEqual(post.value(forHTTPHeaderField: "x-ss-stub"),Crypto.hash("md5",post.httpBody!).hex.uppercased())
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Crypto.inflate(post.httpBody!,window: 31)) as? JSON)
        XCTAssertEqual(payload.text("dr_scene"),"preload")
        XCTAssertEqual(payload.object("biz_param").number("device_level"),2)
        XCTAssertEqual(payload.object("mixed_video_id_map")["1004"] as? [String],[episode])
        XCTAssertEqual(post.value(forHTTPHeaderField: "User-Agent"),"okhttp/4.12.0")
        let get = try await MobilePlayback.request(id: episode,device: device,signer: signer,tab: true,host: MobilePlayback.alternateHost)
        XCTAssertEqual(get.httpMethod,"GET"); XCTAssertNil(get.httpBody)
        for request in [post,get] {
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-argus"))
            XCTAssertNil(request.value(forHTTPHeaderField: "x-gorgon"))
            for name in ["x-medusa","x-helios","x-khronos"] { XCTAssertFalse((request.value(forHTTPHeaderField: name) ?? "").isEmpty) }
            let query = Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!,resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name,$0.value ?? "") })
            XCTAssertEqual(query["version_name"],"7.4.5.32")
            XCTAssertEqual(query["manifest_version_code"],"74532")
            XCTAssertEqual(query["device_type"],"25053RT47C")
            XCTAssertEqual(query["channel"],"update_64")
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
    func testPreloadByteVC2NegotiatesH264ThenHEVCWithoutSessionHeaders() async throws {
        var requests: [URLRequest] = []
        let model: JSON = ["video_list":[["codec_type":"bytevc2","main_url":"https://example.org/unsupported.mp4"]],
                           "fallback_api":["https://vod.example.org/model?signature=synthetic&codec_type=2"]]
        let rows = try await MobilePlayback.streams(id: episode,device: device,signer: Signer()) { request in
            requests.append(request)
            let payload: JSON
            if requests.count == 1 { payload = ["code":0,"data":["1004":[self.episode:["video_model":model]]]] }
            else {
                payload = ["video_info":["data":["video_list":[["codec_type":requests.count == 2 ? "bytevc2" : "hevc","main_url":"https://example.org/compatible.mp4","quality_desc":"720p"]]]]]
                XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
                XCTAssertNil(request.value(forHTTPHeaderField: "x-medusa"))
                XCTAssertNil(request.httpBody)
                XCTAssertFalse(request.httpShouldHandleCookies)
                let items = URLComponents(url: request.url!,resolvingAgainstBaseURL: false)!.queryItems!
                XCTAssertEqual(items.filter { $0.name == "codec_type" }.map(\.value),[requests.count == 2 ? "1" : "3"])
                XCTAssertEqual(items.first { $0.name == "signature" }?.value,"synthetic")
            }
            return (try JSONSerialization.data(withJSONObject: payload),self.response(request))
        }
        XCTAssertEqual(requests.map(\.httpMethod),["POST","GET","GET"])
        XCTAssertEqual(rows.first?.quality,720)
        XCTAssertTrue(rows.first?.codec.contains("hevc") == true)
    }
    func testFallbackShapesAndInvalidEndpoints() {
        let endpoint = "https://vod.example.org/model?a=1&b=2"
        let shapes: [Any] = [endpoint,[endpoint],["fallback_api":endpoint],"{\"fallback_api\":\"\(endpoint)\"}"]
        for raw in shapes {
            XCTAssertEqual(MobilePlayback.fallback(["fallback_api":raw])?.absoluteString,endpoint)
        }
        for endpoint in ["http://example.org/model","https://user:pass@example.org/model","file:///video.mp4",""] {
            XCTAssertNil(MobilePlayback.fallback(["fallback_api":endpoint]))
        }
    }
}
