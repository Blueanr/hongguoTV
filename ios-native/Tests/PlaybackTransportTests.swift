// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

private final class PlaybackProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.path == "/wait" { return }
        if url.path == "/error" {
            client?.urlProtocol(self,didFailWithError: URLError(.badURL)); return
        }
        let response = HTTPURLResponse(url: url,statusCode: 200,httpVersion: "HTTP/1.1",headerFields: [:])!
        client?.urlProtocol(self,didReceive: response,cacheStoragePolicy: .notAllowed)
        if url.path == "/large" {
            client?.urlProtocol(self,didLoad: Data(repeating: 1,count: 32))
        } else {
            var body = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0,count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer,maxLength: buffer.count)
                    if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
                }
            }
            // Echo the exact opaque POST bytes; the transport must not gzip,
            // encode, strip or otherwise rewrite the already signed body.
            client?.urlProtocol(self,didLoad: body)
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

final class PlaybackTransportTests: XCTestCase {
    private func config() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PlaybackProtocol.self]; return config
    }
    func testOpaquePOSTBodyRoundTrip() async throws {
        var request = URLRequest(url: URL(string: "https://example.test/register?resolution=1200%2A2670")!)
        request.httpMethod = "POST"
        request.httpBody = Data([0x74,0x63,5,0x10,0,0,255,128])
        request.setValue("gzip",forHTTPHeaderField: "Content-Encoding")
        let (bytes,response) = try await PlaybackTransport.data(request,limit: 64,configuration: config())
        XCTAssertEqual(bytes,request.httpBody); XCTAssertEqual(response.statusCode,200)
    }
    func testUnknownLengthResponseBoundAndUnderlyingError() async {
        for path in ["large","error"] {
            do {
                _ = try await PlaybackTransport.data(URLRequest(url: URL(string: "https://example.test/" + path)!),limit: 8,configuration: config())
                XCTFail("Expected transport failure")
            } catch {
                if path == "error" { XCTAssertEqual((error as NSError).code,NSURLErrorBadURL) }
                else { XCTAssertTrue(error.localizedDescription.contains("超出限制")) }
            }
        }
    }
    func testCancellationFinishesWaitingRequest() async throws {
        let config = config()
        let task = Task { try await PlaybackTransport.data(URLRequest(url: URL(string: "https://example.test/wait")!),limit: 8,configuration: config) }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
