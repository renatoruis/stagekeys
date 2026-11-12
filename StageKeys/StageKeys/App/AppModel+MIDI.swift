import Foundation

extension AppModel {
    func toggleKeyboardSource(_ id: Int32) {
        updateRig { rig in
            if rig.keyboardSourceIDs.contains(id) {
                rig.keyboardSourceIDs.removeAll { $0 == id }
            } else {
                rig.keyboardSourceIDs.append(id)
            }
        }
        rigStore.save(rig)
    }

    func toggleMIDISource(_ id: Int32) {
        updateRig { rig in
            if rig.enabledMIDISources.contains(id) {
                rig.enabledMIDISources.removeAll { $0 == id }
            } else {
                rig.enabledMIDISources.append(id)
            }
        }
        midi.enabledSourceIDs = Set(rig.enabledMIDISources)
        rigStore.save(rig)
    }

    func setClockDestination(_ id: Int32?) {
        updateRig { $0.clockDestinationID = id }
        rigStore.save(rig)
    }

    // MARK: Learn

    func toggleLearn() {
        learnOn.toggle()
        if learnOn {
            learnStarted = Date()
            recentLearn = nil
        } else {
            armed = nil
        }
        syncLearn()
    }

    /// Click then move, or move then click: a control touched in the last 5 s (after learn was turned on) binds at once.
    func arm(_ target: BindingTarget, index: Int) {
        if !learnOn {
            learnOn = true
            learnStarted = Date()
            recentLearn = nil
        }
        if let recent = recentLearn, recent.time > learnStarted, Date().timeIntervalSince(recent.time) < 5 {
            recentLearn = nil
            bind(ArmedControl(target: target, index: index), match: recent.match)
            return
        }
        armed = ArmedControl(target: target, index: index)
        syncLearn()
        status = "Move a control on the MIDI device…"
    }

    func clearBinding(target: BindingTarget, index: Int) {
        updateRig { $0.clearBinding(target: target, index: index) }
        rigStore.save(rig)
        if target == .drumNote { syncPadLights() }
    }

    func bindingLabel(target: BindingTarget, index: Int) -> String {
        guard let binding = rig.binding(for: target, index: index) else { return "MIDI" }
        switch binding.match.kind {
        case .cc: return "CC \(binding.match.number)"
        case .note: return MIDINote.name(binding.match.number)
        case .program: return "PC \(binding.match.number + 1)"
        }
    }

    func isArmed(_ target: BindingTarget, index: Int) -> Bool {
        armed?.target == target && armed?.index == index
    }

    // MARK: MIDI thread

    func handleMIDI(_ event: MIDIEvent) {
        switch event.kind {
        case .clock, .start, .stop, .resume:
            metronome.handleClock(event)
            return
        default:
            break
        }
        route.lock.lock()
        let learning = route.learn
        let armedControl = route.armed
        let bindings = route.bindings
        let keyboards = route.keyboards
        let modCutoff = route.modCutoff
        let filters = route.filters
        route.lock.unlock()

        let match = learnMatch(event)
        let capturing = learning && armedControl != nil
        if let match {
            noteMessage(match, event: event, consumed: capturing)
        }
        if capturing, let armedControl, let match {
            DispatchQueue.main.async { [weak self] in
                self?.bind(armedControl, match: match)
            }
            return
        }

        var bound = false
        for binding in bindings where matches(binding, event) {
            bound = true
            perform(binding, event: event)
        }

        let fromKeyboard = keyboards.isEmpty || keyboards.contains(event.sourceID)
        var mask: UInt8 = 0
        for (index, filter) in filters.enumerated() {
            let source = filter.inputID.map { $0 == event.sourceID } ?? fromKeyboard
            let channel = filter.channel.map { $0 == event.channel } ?? true
            if source && channel { mask |= 1 << UInt8(index) }
        }

        if !bound, event.kind == .control, event.data1 == 1 {
            for (index, on) in modCutoff.enumerated() where on && mask & (1 << UInt8(index)) != 0 {
                queueCC(.knob(.keysCutoff, index), Double(event.data2) / 127)
            }
        }

        if mask != 0, !bound || event.kind == .noteOff {
            keys.handle(event, parts: mask)
        }
        if event.kind == .noteOn, !bound, !keyboards.contains(event.sourceID) {
            pads.follow(note: event.data1)
        }
    }

    private func learnMatch(_ event: MIDIEvent) -> MIDIMatch? {
        switch event.kind {
        case .control: MIDIMatch(kind: .cc, number: event.data1, channel: event.channel)
        case .noteOn: MIDIMatch(kind: .note, number: event.data1, channel: event.channel)
        case .program: MIDIMatch(kind: .program, number: event.data1, channel: event.channel)
        default: nil
        }
    }

    private func noteMessage(_ match: MIDIMatch, event: MIDIEvent, consumed: Bool) {
        guard lastMessage.put(match, source: event.sourceID, consumed: consumed) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.flushMessage()
        }
    }

    private func matches(_ binding: MIDIBinding, _ event: MIDIEvent) -> Bool {
        switch event.kind {
        case .control:
            binding.match.matches(kind: .cc, number: event.data1, channel: event.channel)
        case .noteOn, .noteOff:
            binding.match.matches(kind: .note, number: event.data1, channel: event.channel)
        case .program:
            binding.match.matches(kind: .program, number: event.data1, channel: event.channel)
        default:
            false
        }
    }

    private func perform(_ binding: MIDIBinding, event: MIDIEvent) {
        let fires = event.kind == .noteOn || event.kind == .program || (event.kind == .control && event.data2 >= 64)
        let index = binding.index
        switch binding.target {
        case .keysVolume:
            guard event.kind == .control || event.kind == .noteOn else { return }
            let value = Double(event.data2) / 127
            keys.setVolume(part: index, volume: value)
            queueCC(.keys(index), value)
            pulse(.keysLevel, index)
        case .keysToggle:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.state.keySlots.indices.contains(index) else { return }
                self.setKeyEnabled(index: index, enabled: !self.state.keySlots[index].enabled)
            }
        case .keysPanic:
            guard fires else { return }
            keys.panic()
        case .keysCutoff, .keysResonance, .keysLow, .keysHigh, .keysCompressor, .keysReverb, .keysPan, .keysTune:
            guard event.kind == .control else { return }
            queueCC(.knob(binding.target, index), Double(event.data2) / 127)
            pulse(.knob(binding.target), index)
        case .keysModToggle, .keysRotaryToggle, .keysBendToggle:
            guard fires else { return }
            let target = binding.target
            DispatchQueue.main.async { [weak self] in self?.toggleKey(target, index: index) }
        case .keysOctaveDown, .keysOctaveUp:
            guard fires else { return }
            let delta = binding.target == .keysOctaveUp ? 1 : -1
            DispatchQueue.main.async { [weak self] in self?.stepKeyOctave(index: index, delta) }
        case .transposeDown, .transposeUp:
            guard fires else { return }
            let delta = binding.target == .transposeUp ? 1 : -1
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setKeysTranspose(self.state.transpose + delta)
            }
        case .masterVolume:
            guard event.kind == .control else { return }
            let value = Double(event.data2) / 127
            keys.setMaster(value)
            queueCC(.keysMaster, value)
            pulse(.keysMaster, 0)
        case .padVolume:
            guard event.kind == .control || event.kind == .noteOn else { return }
            let value = Double(event.data2) / 127
            pads.setVolume(index: index, volume: Float(value))
            queueCC(.pad(index), value)
            pulse(.padLevel, index)
        case .padCutoff:
            guard event.kind == .control else { return }
            let value = Double(event.data2) / 127
            DispatchQueue.main.async { [weak self] in self?.previewPadCutoff(index: index, cutoff: value) }
            queueCC(.padCutoff(index), value)
            pulse(.padCutoff, index)
        case .padMaster:
            guard event.kind == .control else { return }
            let value = Double(event.data2) / 127
            pads.setMaster(Float(value))
            queueCC(.padMaster, value)
            pulse(.padMaster, 0)
        case .countIn:
            guard fires else { return }
            metronome.countIn()
        case .padToggle:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setPadEnabled(index: index, enabled: !self.set.padLayers[index].enabled)
            }
        case .nextSong:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in self?.step(1) }
        case .previousSong:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in self?.step(-1) }
        case .padsTransport:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.setPadsRunning(!self.set.padsRunning)
            }
        case .drumNote:
            guard fires else { return }
            let velocity: Float = event.kind == .noteOn ? Float(event.data2) / 127 : 1
            drums.trigger(index: index, velocity: velocity, host: event.hostTime)
            pulse(.drum, index)
            flashDrumPad(index)
        case .metroToggle:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in self?.toggleMetronome() }
        case .showTab:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in self?.selectTab(.show) }
        case .keysTab:
            guard fires else { return }
            DispatchQueue.main.async { [weak self] in self?.selectTab(.keys) }
        }
    }

    // MARK: Main thread

    private func bind(_ armed: ArmedControl, match: MIDIMatch) {
        let binding = MIDIBinding(target: armed.target, index: armed.index, match: match)
        var replaced: [MIDIBinding] = []
        updateRig { replaced = $0.setBinding(binding) }
        rigStore.save(rig)
        self.armed = nil
        syncLearn()
        let title = armed.target.title(index: armed.index)
        if let old = replaced.first {
            status = "\(match.label) → \(title). Removed from \(old.target.title(index: old.index))."
        } else {
            status = "\(match.label) → \(title)."
        }
        if armed.target == .drumNote || replaced.contains(where: { $0.target == .drumNote }) {
            syncPadLights()
        }
    }

    private func flushMessage() {
        guard let last = lastMessage.drain() else { return }
        monitor.label = last.match.label
        monitor.source = midiSources.first { $0.id == last.source }?.name ?? ""
        monitor.stamp &+= 1
        if learnOn, armed == nil, !last.consumed {
            recentLearn = (last.match, Date())
        }
    }

    func syncLearn() {
        route.lock.lock()
        route.learn = learnOn
        route.armed = armed
        route.lock.unlock()
    }

    func syncRoute() {
        route.lock.lock()
        route.bindings = rig.bindings
        route.clockID = rig.clockDestinationID
        route.keyboards = Set(rig.keyboardSourceIDs)
        route.modCutoff = state.keySlots.map(\.modCutoff)
        route.filters = state.keySlots.map { LayerFilter(inputID: $0.inputID, channel: $0.channel) }
        route.lock.unlock()
    }

    func syncMIDIEndpoints() {
        let snapshot = midi.endpointSnapshot()
        midiSources = snapshot.sources
        midiDestinations = snapshot.destinations
        let seen = Set(rig.seenMIDISources)
        let fresh = snapshot.sources.map(\.id).filter { !seen.contains($0) }
        if !fresh.isEmpty {
            updateRig { next in
                next.enabledMIDISources.append(contentsOf: fresh)
                next.seenMIDISources.append(contentsOf: fresh)
                next.midiSourcesKnown = true
            }
            midi.enabledSourceIDs = Set(rig.enabledMIDISources)
            rigStore.save(rig)
        }
        syncPadLightsDevice()
    }

    private func queueCC(_ key: PendingCC.Key, _ value: Double) {
        guard pendingCC.put(key, value) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30) { [weak self] in
            self?.flushCC()
        }
    }

    private func flushCC() {
        let values = pendingCC.drain()
        guard !values.isEmpty else { return }
        var filtered = Set<Int>()
        updateState { next in
            for (key, value) in values {
                switch key {
                case .keys(let index): next.keySlots[index].volume = value
                case .knob(let target, let index):
                    Self.setKnob(target, value, in: &next.keySlots[index])
                    filtered.insert(index)
                case .keysMaster: next.master = value
                case .pad, .padCutoff, .padMaster: break
                }
            }
        }
        for index in filtered { keys.configure(part: index, slot: state.keySlots[index]) }
        updateSet { next in
            for (key, value) in values {
                switch key {
                case .pad(let index): next.padLayers[index].volume = value
                case .padCutoff(let index): next.padLayers[index].cutoff = value
                case .padMaster: next.padMaster = value
                default: break
                }
            }
        }
    }
}

final class PendingCC {
    enum Key: Hashable {
        case keys(Int)
        case knob(BindingTarget, Int)
        case keysMaster
        case pad(Int)
        case padCutoff(Int)
        case padMaster
    }

    private let lock = NSLock()
    private var values: [Key: Double] = [:]
    private var scheduled = false

    func put(_ key: Key, _ value: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func drain() -> [Key: Double] {
        lock.lock()
        defer { lock.unlock() }
        let out = values
        values = [:]
        scheduled = false
        return out
    }
}

final class LastMessage {
    private let lock = NSLock()
    private var last: (match: MIDIMatch, source: Int32, consumed: Bool)?
    private var scheduled = false

    /// `consumed`: the message was captured by an armed control, so it must not bind a second one.
    func put(_ match: MIDIMatch, source: Int32, consumed: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        last = (match, source, consumed)
        guard !scheduled else { return false }
        scheduled = true
        return true
    }

    func drain() -> (match: MIDIMatch, source: Int32, consumed: Bool)? {
        lock.lock()
        defer { lock.unlock() }
        scheduled = false
        let out = last
        last = nil
        return out
    }
}

final class MIDIRoute {
    let lock = NSLock()
    var learn = false
    var armed: ArmedControl?
    var bindings: [MIDIBinding] = []
    var keyboards: Set<Int32> = []
    var clockID: Int32?
    var modCutoff: [Bool] = []
    var filters: [LayerFilter] = []
}

struct LayerFilter {
    var inputID: Int32?
    var channel: Int?
}
