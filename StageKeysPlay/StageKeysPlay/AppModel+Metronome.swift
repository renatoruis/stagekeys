import Foundation

extension AppModel {
    static func snapBPM(_ bpm: Double) -> Double {
        let clamped = min(300, max(40, bpm))
        return (clamped * 2).rounded() / 2
    }

    func setBPM(_ bpm: Double) {
        updateSet { $0.metronome.bpm = Self.snapBPM(bpm) }
        metronome.apply(settings: set.metronome)
    }

    func acceptBPM(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(trimmed), value >= 40, value <= 300 else { return false }
        let doubled = value * 2
        guard abs(doubled - doubled.rounded()) < 0.001 else { return false }
        setBPM(value)
        return true
    }

    func tapTempo() { metronome.tap() }

    /// Counts in from the next bar while the click runs; starts the click with a count-in otherwise.
    func countIn() { metronome.countIn() }

    func toggleMetronome() { metronome.toggle() }

    func setBeatsPerBar(_ value: Int) {
        updateSet { $0.metronome.beatsPerBar = value == 6 ? 6 : 4 }
        metronome.apply(settings: set.metronome)
    }

    func setSubdivision(_ value: Int) {
        updateSet { $0.metronome.subdivision = value }
        metronome.apply(settings: set.metronome)
    }

    func setCountIn(_ value: Int) {
        updateSet { $0.metronome.countInBars = min(2, max(0, value)) }
        metronome.apply(settings: set.metronome)
    }

    func setClickStyle(_ id: String) {
        updateSet { $0.metronome.styleID = id }
        loadClick()
    }

    func setClockMode(_ mode: ClockMode) {
        updateSet { $0.metronome.clockMode = mode }
        metronome.apply(settings: set.metronome)
    }

    func setAccentEnabled(_ enabled: Bool) {
        updateSet { $0.metronome.accentEnabled = enabled }
        metronome.apply(settings: set.metronome)
    }

    func setCountVoice(_ enabled: Bool, spaced: Bool) {
        updateSet {
            $0.metronome.countVoice = enabled
            $0.metronome.countSpaced = spaced
        }
        metronome.apply(settings: set.metronome)
    }

    func setMetronomeVolume(_ volume: Double) {
        let value = min(1, max(0, volume))
        updateSet { $0.metronome.volume = value }
        metronome.setVolume(Float(value))
    }

    func previewMetronomeVolume(_ volume: Double) {
        metronome.setVolume(Float(min(1, max(0, volume))))
    }

    func loadClick() {
        loadCountVoices()
        let styles = catalog.clickStyles
        let style = styles.first { $0.id == set.metronome.styleID } ?? styles.first
        guard let style, let normal = catalog.url(for: style.normalID), let accent = catalog.url(for: style.accentID) else { return }
        if set.metronome.styleID != style.id {
            updateSet { $0.metronome.styleID = style.id }
        }
        metronome.loadStyle(normal: normal, accent: accent)
    }

    private func loadCountVoices() {
        let urls = (1...4).compactMap { catalog.url(for: "voiceguide/Count/Count \($0).wav") }
        guard urls.count == 4 else { return }
        metronome.loadCountVoices(urls)
    }

    func sendMetronome(byte: UInt8) {
        route.lock.lock()
        let destination = route.clockID
        route.lock.unlock()
        midi.send([byte], to: destination)
    }
}
