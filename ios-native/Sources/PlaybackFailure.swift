// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// Display only local stage names and numeric errors; signed URLs/cookies/tokens
// from NSError.userInfo must never be included in the on-screen diagnosis.
struct PlaybackFailure: LocalizedError {
    let stage: String
    let cause: Error
    var errorDescription: String? { "\(stage)：\(Self.describe(cause))" }
    static func describe(_ error: Error) -> String {
        if let failure = error as? PlaybackFailure { return failure.errorDescription ?? failure.stage }
        if let error = error as? HGError { return error.localizedDescription }
        let first = error as NSError
        var current: NSError? = first
        var codes: [String] = []
        for _ in 0..<4 {
            guard let value = current else { break }
            let domain: String
            switch value.domain {
            case NSURLErrorDomain: domain = "URL"
            case "AVFoundationErrorDomain": domain = "AVFoundation"
            case "CoreMediaErrorDomain": domain = "CoreMedia"
            case NSPOSIXErrorDomain: domain = "POSIX"
            default: domain = "系统"
            }
            codes.append("\(domain) \(value.code)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let message: String
        if first.domain == NSURLErrorDomain && first.code == NSURLErrorBadURL { message = "系统拒绝了请求地址（bad URL）" }
        else if first.domain == NSURLErrorDomain && first.code == NSURLErrorTimedOut { message = "网络请求超时" }
        else { message = "加载失败" }
        return message + " [" + codes.joined(separator: " → ") + "]"
    }
}
