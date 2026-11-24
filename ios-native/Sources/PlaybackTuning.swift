// SPDX-License-Identifier: GPL-3.0-only
import AVFoundation

enum PlaybackTuning {
    static func apply(_ item: AVPlayerItem,rate: Float) {
        // Buffer media seconds proportional to consumption, up to 32 seconds at
        // 4x. AVFoundation treats this as a preference, not an unbounded cache.
        item.preferredForwardBufferDuration = 8 * Double(max(1,min(4,rate)))
    }
    static func configure(_ item: AVPlayerItem,rate: Float) {
        // Configure once before attaching the item. Do not reset the audio
        // processing pipeline each time the user selects a speed.
        item.audioTimePitchAlgorithm = .spectral
        apply(item,rate: rate)
    }
}

@MainActor enum PlaybackAudioSession {
    private static var owner: UUID?
    static func isOwner(_ id: UUID) -> Bool { owner == id }
    static func activate(_ id: UUID) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,mode: .moviePlayback)
        try session.setActive(true)
        owner = id
    }
    static func release(_ id: UUID) {
        guard owner == id else { return }
        owner = nil
        try? AVAudioSession.sharedInstance().setActive(false,options: .notifyOthersOnDeactivation)
    }
}
