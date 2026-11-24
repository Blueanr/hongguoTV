// SPDX-License-Identifier: GPL-3.0-only
import Foundation

// AudioUnit's uninit inside mpv deactivates the process-wide AVAudioSession.
// Serialize teardown across pages, not just across episodes in a single model.
@MainActor enum MPVLifetime {
    private static var pending: Task<Void,Never>?
    private static var generation = UUID()

    static func retire(_ player: HGMPVPlayer?,releaseAudio owner: UUID? = nil) {
        let previous = pending
        let token = UUID(); generation = token
        pending = Task {
            await previous?.value
            if let player = player {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void,Never>) in
                    player.shutdown { continuation.resume() }
                }
            }
            if let owner = owner { PlaybackAudioSession.release(owner) }
            if generation == token { pending = nil }
        }
    }

    static func waitForRetirement() async {
        // A second page may retire while we are suspended. Wait for the newest
        // generation too, then return on the same main actor as player startup.
        while let task = pending { await task.value }
    }
}
