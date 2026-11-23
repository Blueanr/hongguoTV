// SPDX-License-Identifier: GPL-3.0-only
import XCTest
@testable import HongguoPad

final class PlaybackFailureTests: XCTestCase {
    func testErrorChainPreservesCodesWithoutSignedURLs() {
        let urlError = NSError(domain: NSURLErrorDomain,code: NSURLErrorBadURL,userInfo: [NSURLErrorFailingURLStringErrorKey:"https://example.org/?token=secret",NSLocalizedDescriptionKey:"secret remote text"])
        let playerError = NSError(domain: "AVFoundationErrorDomain",code: -11800,userInfo: [NSUnderlyingErrorKey:urlError])
        let message = PlaybackFailure(stage: "播放器",cause: playerError).localizedDescription
        XCTAssertTrue(message.contains("AVFoundation -11800"))
        XCTAssertTrue(message.contains("URL -1000"))
        XCTAssertFalse(message.contains("secret"))
        XCTAssertFalse(message.contains("https://"))
        XCTAssertTrue(PlaybackFailure(stage: "SDK 资料初始化",cause: urlError).localizedDescription.contains("SDK 资料初始化"))
    }
}
