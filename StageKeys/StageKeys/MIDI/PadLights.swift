import Foundation

/// Colors the Launchkey MK4 drum pads over the DAW port.
final class PadLights {
    static let white: UInt8 = 3
    /// The 16 pads in DAW drum mode.
    static let pads: ClosedRange<UInt8> = 36...51

    private let midi: MIDIManager
    private let queue = DispatchQueue(label: "stagekeys.padlights")
    private let lock = NSLock()
    private var destination: Int32?
    private var shown: [Int: UInt8] = [:]
    private var tokens: [Int: UUID] = [:]

    var destinationID: Int32? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return destination
        }
        set {
            lock.lock()
            destination = newValue
            lock.unlock()
        }
    }

    init(midi: MIDIManager) {
        self.midi = midi
    }

    static func palette(_ color: DrumColor) -> UInt8 {
        switch color {
        case .stone: 1
        case .blue: 45
        case .green: 21
        case .amber: 9
        case .pink: 53
        case .violet: 49
        case .red: 5
        case .white: 3
        }
    }

    /// Selects the drum layout, then lets the host own its colors.
    func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            self.shown = [:]
            self.tokens = [:]
            self.send([0x9F, 0x0C, 0x7F])
            self.send([0xB6, 0x1D, 0x01])
            self.send([0xB6, 0x54, 0x01])
            self.send([0xB6, 0x53, 0x00])
            for note in Self.pads {
                self.send([0x99, note, 0])
            }
        }
    }

    /// Clears the pads and gives drum mode back. Safe to call while the app is quitting.
    func disconnect() {
        queue.sync {
            for note in shown.keys {
                send([0x99, UInt8(clamping: note), 0])
            }
            shown = [:]
            tokens = [:]
            send([0xB6, 0x54, 0x00])
        }
    }

    func clearCache() {
        queue.async { [weak self] in
            self?.shown = [:]
            self?.tokens = [:]
        }
    }

    /// Note number to palette index. A missing note, or 0, turns that pad off.
    func show(_ lights: [Int: UInt8]) {
        queue.async { [weak self] in
            guard let self else { return }
            var next = lights
            for note in self.shown.keys where next[note] == nil {
                next[note] = 0
            }
            for (note, color) in next where self.shown[note] != color {
                self.tokens[note] = nil
                self.send([0x99, UInt8(clamping: note), color])
            }
            self.shown = next.filter { $0.value != 0 }
        }
    }

    func flash(note: Int, restore: UInt8) {
        queue.async { [weak self] in
            guard let self else { return }
            let token = UUID()
            self.tokens[note] = token
            self.send([0x99, UInt8(clamping: note), Self.white])
            self.queue.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.tokens[note] == token else { return }
                self.tokens[note] = nil
                self.send([0x99, UInt8(clamping: note), restore])
                if restore == 0 {
                    self.shown[note] = nil
                } else {
                    self.shown[note] = restore
                }
            }
        }
    }

    private func send(_ bytes: [UInt8]) {
        midi.send(bytes, to: destinationID)
    }
}
