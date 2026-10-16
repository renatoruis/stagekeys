import AVFoundation
import AudioKit
import AudioToolbox
import Foundation
import SoundpipeAudioKit

enum EffectChain {
    /// Moog ladder, 24 dB/oct, with a touch of fixed resonance.
    static func makeFilter() -> MoogLadder {
        let ladder = MoogLadder(Mixer(), cutoffFrequency: 18_000, resonance: 0.1)
        ladder.stop()
        return ladder
    }

    /// Fully open bypasses the filter.
    static func applyCutoff(_ ladder: MoogLadder, _ cutoff: Double) {
        let open = cutoff >= 0.98
        open ? ladder.stop() : ladder.start()
        if !open {
            ladder.cutoffFrequency = AUValue(200.0 * pow(18_000.0 / 200.0, min(1, max(0, cutoff))))
        }
    }
}
