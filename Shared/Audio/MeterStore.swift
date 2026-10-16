import Accelerate
import AVFoundation
import Foundation

final class MeterStore {
    static let shared = MeterStore()

    /// Each app names its channels in an extension.
    enum Channel {
        static let capacity = 8
    }

    struct Reading {
        var level: Float = 0
        var hold: Float = 0
        var clipping = false
    }

    private struct Slot {
        var level: Float = 0
        var hold: Float = 0
        var holdStamp: CFTimeInterval = 0
        var clipUntil: CFTimeInterval = 0
    }

    private let lock = NSLock()
    private var slots = Array(repeating: Slot(), count: Channel.capacity)
    private var taps: [(node: AVAudioNode, index: Int)] = []
    private(set) var enabled = false

    func register(_ node: AVAudioNode, index: Int) {
        taps.append((node, index))
        if enabled { install(node, index: index) }
    }

    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        for tap in taps {
            if on {
                install(tap.node, index: tap.index)
            } else {
                tap.node.removeTap(onBus: 0)
            }
        }
        if !on {
            lock.lock()
            slots = Array(repeating: Slot(), count: Channel.capacity)
            lock.unlock()
        }
    }

    func reinstall() {
        guard enabled else { return }
        for tap in taps {
            tap.node.removeTap(onBus: 0)
            install(tap.node, index: tap.index)
        }
    }

    func reading(_ index: Int) -> Reading {
        lock.lock()
        let slot = slots[index]
        lock.unlock()
        return Reading(level: slot.level, hold: slot.hold, clipping: CACurrentMediaTime() < slot.clipUntil)
    }

    private func install(_ node: AVAudioNode, index: Int) {
        guard node.engine != nil else { return }
        node.installTap(onBus: 0, bufferSize: 2048, format: nil) { [weak self] buffer, _ in
            self?.write(index, peak: Self.peak(buffer))
        }
    }

    private func write(_ index: Int, peak: Float) {
        let now = CACurrentMediaTime()
        lock.lock()
        var slot = slots[index]
        slot.level = max(peak, slot.level * 0.72)
        if peak >= 0.98 { slot.clipUntil = now + 1.5 }
        if peak >= slot.hold {
            slot.hold = peak
            slot.holdStamp = now
        } else if now - slot.holdStamp > 1 {
            slot.hold = max(slot.level, slot.hold * 0.85)
        }
        slots[index] = slot
        lock.unlock()
    }

    private static func peak(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData else { return 0 }
        let frames = vDSP_Length(buffer.frameLength)
        var result: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            var value: Float = 0
            vDSP_maxmgv(data[channel], 1, &value, frames)
            result = max(result, value)
        }
        return result
    }
}
