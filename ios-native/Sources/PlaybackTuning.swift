// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation

enum PlaybackTuning {
    static func apply(_ item: AVPlayerItem,rate: Float) {
        // Buffer media seconds proportional to consumption, up to 32 seconds at
        // 4x. AVFoundation treats this as a preference, not an unbounded cache.
        item.preferredForwardBufferDuration = 8 * Double(max(1,min(4,rate)))
        // Low-cost speech time stretching is appropriate for short-drama speech
        // and avoids spectral processing on older iPads at high rates.
        item.audioTimePitchAlgorithm = .timeDomain
    }
}
