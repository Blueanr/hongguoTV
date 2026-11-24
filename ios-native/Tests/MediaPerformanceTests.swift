// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

private final class MediaProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url!.path == "/wait" { return }
        let status = request.url!.path == "/full" ? 200 : 206
        let response = HTTPURLResponse(url: request.url!,statusCode: status,httpVersion: "HTTP/1.1",headerFields: [:])!
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        for _ in 0..<3 { client?.urlProtocol(self,didLoad: Data(repeating: 7,count: 16)) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

private actor RangeFixture {
    let file: Data
    var requests: [Range<Int>] = []
    init() {
        var bytes = Data(repeating: 0x5a,count: 3 * MediaBytes.blockSize + 123)
        bytes.replaceSubrange(0..<24,with: Data(hex: "0000000866747970000000106d6f6f760000000000000000")!)
        file = bytes
    }
    func fetch(_ request: URLRequest,_ limit: Int) throws -> (Data,HTTPURLResponse) {
        let values = request.value(forHTTPHeaderField: "Range")!.dropFirst(6).split(separator: "-").map { Int($0)! }
        let range = values[0]..<(values[1] + 1)
        requests.append(range)
        XCTAssertLessThanOrEqual(range.count,limit)
        let response = HTTPURLResponse(url: request.url!,statusCode: 206,httpVersion: "HTTP/1.1",headerFields: ["Content-Range":"bytes \(range.lowerBound)-\(range.upperBound - 1)/\(file.count)"])!
        return (Data(file[range]),response)
    }
    func count() -> Int { requests.count }
    func expected(_ range: Range<Int>) -> Data { Data(file[range]) }
}

final class MediaPerformanceTests: XCTestCase {
    func testChunkTransportLimitsCancellationAndSubsequentConnectionUse() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MediaProtocol.self]
        let transport = MediaTransport(configuration: config)
        defer { transport.invalidate() }
        let request = URLRequest(url: URL(string: "https://example.org/range")!)
        do { _ = try await transport.data(request,limit: 32); XCTFail("Expected oversized chunk failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("大小限制")) }
        do {
            _ = try await transport.data(URLRequest(url: URL(string: "https://example.org/full")!),limit: 64)
            XCTFail("Must reject full-file response before accumulating data")
        } catch { XCTAssertTrue(error.localizedDescription.contains("分段响应")) }
        let pending = Task { try await transport.data(URLRequest(url: URL(string: "https://example.org/wait")!),limit: 64) }
        try await Task.sleep(nanoseconds: 50_000_000); pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let (bytes,response) = try await transport.data(request,limit: 64)
        XCTAssertEqual(bytes,Data(repeating: 7,count: 48))
        XCTAssertEqual(response.statusCode,206)
    }
    func testRepeatedOverlappingAndCrossBlockReadsReuseBoundedCache() async throws {
        let fixture = RangeFixture()
        let row = Rendition(url: URL(string: "https://example.org/video.mp4")!,key: nil,quality: 720,codec: "h264")
        let bytes = MediaBytes(row,fetch: { try await fixture.fetch($0,$1) })
        let block = MediaBytes.blockSize
        for range in [100..<300,200..<500,(block - 30)..<(block + 40)] {
            let actual = try await bytes.read(range.lowerBound,range.upperBound - 1)
            let expected = await fixture.expected(range)
            XCTAssertEqual(actual,expected)
        }
        let count = await fixture.count()
        XCTAssertEqual(count,3,"One header request and two blocks, not one network request per read")
        _ = try await bytes.read(2 * block,2 * block + 10)
        _ = try await bytes.read(0,50)
        let afterEviction = await fixture.count()
        XCTAssertEqual(afterEviction,5,"Third block evicts oldest from two-block cache")
        let tail = try await bytes.read(3 * block,3 * block + 122)
        XCTAssertEqual(tail.count,123)
    }
}
