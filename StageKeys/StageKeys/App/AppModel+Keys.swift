import Foundation

extension AppModel {
    func setKeySound(index: Int, fileID: String?, bank: Int, program: Int) {
        updateState {
            $0.keySlots[index].fileID = fileID
            $0.keySlots[index].bank = bank
            $0.keySlots[index].program = program
        }
        if !keyIsOrgan(index), state.keySlots[index].rotary != 0 {
            updateState { $0.keySlots[index].rotary = 0 }
        }
        keys.configure(part: index, slot: state.keySlots[index])
        syncKeyProgram(index)
        refreshKeysPreload()
    }

    func setKeyEnabled(index: Int, enabled: Bool) {
        updateState { $0.keySlots[index].enabled = enabled }
        keys.setEnabled(part: index, enabled: enabled)
    }

    func setKeyVolume(index: Int, volume: Double) {
        let value = min(1, max(0, volume))
        updateState { $0.keySlots[index].volume = value }
        keys.setVolume(part: index, volume: value)
    }

    func previewKeyVolume(index: Int, volume: Double) {
        keys.setVolume(part: index, volume: volume)
    }

    func setKeysMaster(_ volume: Double) {
        let value = min(1, max(0, volume))
        updateState { $0.master = value }
        keys.setMaster(value)
    }

    func previewKeysMaster(_ volume: Double) {
        keys.setMaster(volume)
    }

    /// Why the Keys cannot sound right now, or nil. A single layer at zero is a normal mix choice.
    var keysSilentReason: String? {
        KeyState.silentReason(state)
    }

    func setKeysTranspose(_ transpose: Int) {
        updateState { $0.transpose = min(24, max(-24, transpose)) }
        keys.setTranspose(state.transpose)
    }

    func setKeyEffects(index: Int, _ body: (inout KeySlot) -> Void) {
        updateState { body(&$0.keySlots[index]) }
        keys.configure(part: index, slot: state.keySlots[index])
    }

    func toggleKey(_ target: BindingTarget, index: Int) {
        guard state.keySlots.indices.contains(index) else { return }
        switch target {
        case .keysModToggle: setKeyEffects(index: index) { $0.modCutoff.toggle() }
        case .keysBendToggle: setKeyEffects(index: index) { $0.bend.toggle() }
        case .keysRotaryToggle:
            guard keyIsOrgan(index) else { return }
            setKeyEffects(index: index) { $0.rotary = $0.rotary == 0 ? 1 : 0 }
        default: break
        }
    }

    func stepKeyOctave(index: Int, _ delta: Int) {
        guard state.keySlots.indices.contains(index) else { return }
        let range = KeySlot.octaveRange
        setKeyEffects(index: index) { $0.octave = min(range.upperBound, max(range.lowerBound, $0.octave + delta)) }
    }

    func keysPanic() {
        keys.panic()
        status = "Keys: all notes off."
    }

    /// On-screen keyboard, to play the Keys without a controller. Velocity 0 releases the note.
    func playKey(_ note: Int, velocity: Int) {
        keys.handle(MIDIEvent(kind: velocity > 0 ? .noteOn : .noteOff, data1: note, data2: velocity))
    }

    func importSoundFont(index: Int) {
        importFile(kind: .soundFont) { id in
            let preset = self.sf2Catalog.soundFont(id)?.presets.first
            self.setKeySound(index: index, fileID: id, bank: preset?.bank ?? 0, program: preset?.program ?? 0)
        }
    }

    func removeSoundFont(_ id: String) {
        let name = sf2Catalog.soundFont(id)?.name ?? "Sound"
        do {
            try sf2Catalog.removeImported(id)
        } catch {
            status = "Could not remove \(name)."
            return
        }
        for index in state.keySlots.indices where state.keySlots[index].fileID == id {
            setKeySound(index: index, fileID: nil, bank: 0, program: 0)
        }
        reloadSF2Catalog()
        status = "\(name) moved to the Trash."
    }

    func keyTitle(_ index: Int) -> String {
        let slot = state.keySlots[index]
        guard let font = sf2Catalog.soundFont(slot.fileID) else {
            guard let id = slot.fileID, id.hasPrefix("sf2/") else { return "Empty" }
            let stem = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            return "\(SF2Catalog.parseName(stem).name) · not downloaded"
        }
        return font.title(bank: slot.bank, program: slot.program)
    }

    /// Rotary only makes sense on organ sounds.
    func keyIsOrgan(_ index: Int) -> Bool {
        let slot = state.keySlots[index]
        guard let font = sf2Catalog.soundFont(slot.fileID) else { return false }
        return "\(font.category) \(font.subcategory ?? "") \(font.name) \(keyTitle(index))".localizedCaseInsensitiveContains("organ")
    }

    func keyLoadState(_ index: Int) -> SF2Library.LoadState {
        _ = libraryVersion
        guard let key = libraryKey(state.keySlots[index]) else { return .idle }
        return library.state(key)
    }

    func applyKeysState() {
        keys.setTranspose(state.transpose)
        keys.setMaster(state.master)
        for index in 0..<SF2Engine.partCount {
            keys.configure(part: index, slot: state.keySlots[index])
            syncKeyProgram(index)
        }
        refreshKeysPreload()
    }

    func libraryKey(_ slot: KeySlot) -> SF2Library.Key? {
        guard let font = sf2Catalog.soundFont(slot.fileID) else { return nil }
        return SF2Library.Key(url: font.url, bank: slot.bank, program: slot.program)
    }

    /// Notes already sounding finish on the old program; new notes wait until the new one is resident.
    func syncKeyProgram(_ index: Int) {
        let key = libraryKey(state.keySlots[index])
        keyRequests[index] = key
        guard let key else {
            keys.setProgram(nil, part: index)
            return
        }
        if let program = library.program(key) {
            keys.setProgram(program, part: index)
            return
        }
        keys.setProgram(nil, part: index)
        library.load(key) { [weak self] program in
            guard let self, self.keyRequests[index] == key else { return }
            self.keys.setProgram(program, part: index)
            if program == nil { self.status = "Could not load \(self.keyTitle(index))." }
        }
    }

    /// Keeps the SF2 programs of the four layers resident.
    func refreshKeysPreload() {
        var programKeys: [SF2Library.Key] = []
        for slot in state.keySlots {
            if let key = libraryKey(slot), !programKeys.contains(key) { programKeys.append(key) }
        }
        library.pin(programKeys)
    }

    func updateState(_ body: (inout KeyState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        let routing = next.keySlots.map(\.modCutoff) != state.keySlots.map(\.modCutoff)
            || next.keySlots.map(\.inputID) != state.keySlots.map(\.inputID)
            || next.keySlots.map(\.channel) != state.keySlots.map(\.channel)
        state = next
        if routing { syncRoute() }
        scheduleKeysSave()
    }

    /// Knob drags change the state many times a second; write once they settle.
    func scheduleKeysSave() {
        pendingKeysSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingKeysSave = nil
            self.keyStore.saveState(self.state)
        }
        pendingKeysSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    static func setKnob(_ target: BindingTarget, _ value: Double, in slot: inout KeySlot) {
        switch target {
        case .keysCutoff: slot.cutoff = value
        case .keysResonance: slot.resonance = value
        case .keysLow: slot.low = value
        case .keysHigh: slot.high = value
        case .keysCompressor: slot.compressor = value
        case .keysReverb: slot.reverb = value
        case .keysPan: slot.pan = value
        case .keysTune: slot.tune = value
        default: break
        }
    }
}
