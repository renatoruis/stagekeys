import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

/// Last MIDI message received, for the learn indicator. Updated at most ~20 times per second.
@Observable
final class MIDIMonitor {
    var label = ""
    var source = ""
    var stamp = 0
}

struct StageActivity: Equatable {
    enum Kind: Equatable {
        case keysLevel
        case knob(BindingTarget)
        case master
    }

    var kind: Kind
    var index: Int
    var token: UUID
}

@Observable
final class AppModel {
    let router = OutputRouter()
    let midi = MIDIManager(clientName: "StageKeys")
    let keys = SF2Engine()
    let library = SF2Library()
    let monitor = MIDIMonitor()
    let meters = MeterStore.shared
    let sounds: SoundLibrary

    var catalog: ResourceCatalog
    var state: KeyState
    var rig: Rig
    var liveMode = false
    var learnOn = false
    var activity: StageActivity?
    var armed: ArmedControl?
    var status = "" { didSet { statusVersion &+= 1 } }
    var statusVersion = 0
    var devices: [AudioDevice] = []
    var midiSources: [MIDIEndpointInfo] = []
    /// Bumped when an SF2 program starts or finishes loading.
    var libraryVersion = 0

    private let store: KeyStore
    private var pendingSave: DispatchWorkItem?
    private let route = MIDIRoute()
    private let pendingCC = PendingCC()
    private let lastMessage = LastMessage()
    private var recentLearn: (match: MIDIMatch, time: Date)?
    private var learnStarted = Date.distantPast
    private var keyRequests: [SF2Library.Key?] = Array(repeating: nil, count: SF2Engine.partCount)

    init() {
        let store = KeyStore()
        self.store = store
        let sounds = SoundLibrary(libraryFolder: store.libraryFolder)
        let catalog = ResourceCatalog(userRoot: store.libraryFolder, soundsRoot: sounds.folder)
        let rig = store.loadRig()
        self.sounds = sounds
        self.catalog = catalog
        self.rig = rig
        self.state = store.loadState()
        self.liveMode = rig.liveMode
        wire()
        installAudio()
        registerMeters()
        syncRoute()
        midi.enabledSourceIDs = Set(rig.enabledMIDISources)
        midi.start()
        syncMIDIEndpoints()
        applyState()
        syncDevices()
    }

    func setLiveMode(_ on: Bool) {
        guard on != liveMode else { return }
        if on {
            learnOn = false
            armed = nil
            syncLearn()
        }
        liveMode = on
        updateRig { $0.liveMode = on }
        store.saveRig(rig)
    }

    // MARK: Keys

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
        refreshPreload()
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

    func setMaster(_ volume: Double) {
        let value = min(1, max(0, volume))
        updateState { $0.master = value }
        keys.setMaster(value)
    }

    func previewMaster(_ volume: Double) {
        keys.setMaster(volume)
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
            self.catalogReload()
            let preset = self.catalog.soundFont(id)?.presets.first
            self.setKeySound(index: index, fileID: id, bank: preset?.bank ?? 0, program: preset?.program ?? 0)
        }
    }

    func removeSoundFont(_ id: String) {
        let name = catalog.soundFont(id)?.name ?? "Sound"
        do {
            try catalog.removeImported(id)
        } catch {
            status = "Could not remove \(name)."
            return
        }
        for index in state.keySlots.indices where state.keySlots[index].fileID == id {
            setKeySound(index: index, fileID: nil, bank: 0, program: 0)
        }
        catalogReload()
        status = "\(name) moved to the Trash."
    }

    func keyTitle(_ index: Int) -> String {
        let slot = state.keySlots[index]
        guard let font = catalog.soundFont(slot.fileID) else {
            guard let id = slot.fileID, id.hasPrefix("sf2/") else { return "Empty" }
            let stem = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            return "\(ResourceCatalog.parseName(stem).name) · not downloaded"
        }
        return font.title(bank: slot.bank, program: slot.program)
    }

    /// Rotary only makes sense on organ sounds.
    func keyIsOrgan(_ index: Int) -> Bool {
        let slot = state.keySlots[index]
        guard let font = catalog.soundFont(slot.fileID) else { return false }
        return "\(font.category) \(font.subcategory ?? "") \(font.name) \(keyTitle(index))".localizedCaseInsensitiveContains("organ")
    }

    func keyLoadState(_ index: Int) -> SF2Library.LoadState {
        _ = libraryVersion
        guard let key = libraryKey(state.keySlots[index]) else { return .idle }
        return library.state(key)
    }

    func toggleKeyboardSource(_ id: Int32) {
        updateRig { rig in
            if rig.keyboardSourceIDs.contains(id) {
                rig.keyboardSourceIDs.removeAll { $0 == id }
            } else {
                rig.keyboardSourceIDs.append(id)
            }
        }
        store.saveRig(rig)
    }

    // MARK: Routing

    func setDevice(motor: Motor, uid: String) {
        var route = rig.route(for: motor)
        route.deviceUID = uid
        let options = router.channelOptions(for: router.device(uid: uid))
        if !options.contains(where: { $0.pick == route.pick }) {
            route.pick = options.first?.pick ?? .stereo
        }
        updateRig { $0.setRoute(route, for: motor) }
        store.saveRig(rig)
        router.apply(route: route, to: motor)
        resumeAudio()
    }

    func setPick(motor: Motor, pick: ChannelPick) {
        var route = rig.route(for: motor)
        route.pick = pick
        updateRig { $0.setRoute(route, for: motor) }
        store.saveRig(rig)
        router.apply(route: route, to: motor)
        resumeAudio()
    }

    func setBuffer(_ frames: Int) {
        updateRig { $0.bufferFrames = frames }
        store.saveRig(rig)
        router.applyBuffer(frames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
        resumeAudio()
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
        store.saveRig(rig)
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
        store.saveRig(rig)
    }

    func bindingLabel(target: BindingTarget, index: Int) -> String {
        guard let binding = rig.binding(for: target, index: index) else { return "MIDI" }
        switch binding.match.kind {
        case .cc: return "CC \(binding.match.number)"
        case .note: return ResourceCatalog.noteName(binding.match.number)
        case .program: return "PC \(binding.match.number + 1)"
        }
    }

    func isArmed(_ target: BindingTarget, index: Int) -> Bool {
        armed?.target == target && armed?.index == index
    }

    func setMetering(_ on: Bool) {
        meters.setEnabled(on)
    }

    private func wire() {
        router.onChange = { [weak self] in
            DispatchQueue.main.async { self?.syncDevices() }
        }
        library.onChange = { [weak self] in
            self?.libraryVersion &+= 1
        }
        sounds.onChange = { [weak self] in
            self?.catalogReload()
            self?.applyState()
        }
        midi.onEvent = { [weak self] event in
            self?.handleMIDI(event)
        }
        midi.onEndpointsChanged = { [weak self] in
            DispatchQueue.main.async { self?.syncMIDIEndpoints() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self, let work = self.pendingSave else { return }
            work.cancel()
            self.store.saveState(self.state)
        }
    }

    /// Supermassive settings, saved when its editor closes.
    private var spaceURL: URL { store.root.appendingPathComponent("Supermassive-Keys.plist") }

    func saveSpaceSettings() {
        if let node = keys.spaceNode { Supermassive.save(node, to: spaceURL) }
    }

    private func installAudio() {
        keys.install(on: router.output(for: .keys), sampleRate: sampleRate(for: .keys))
        if let node = keys.spaceNode { Supermassive.restore(node, from: spaceURL) }
        router.applyBuffer(rig.bufferFrames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
    }

    private func sampleRate(for motor: Motor) -> Double {
        router.nominalSampleRate(uid: rig.route(for: motor).deviceUID)
    }

    private func applyState() {
        keys.setTranspose(state.transpose)
        keys.setMaster(state.master)
        for index in 0..<SF2Engine.partCount {
            keys.configure(part: index, slot: state.keySlots[index])
            syncKeyProgram(index)
        }
        refreshPreload()
    }

    private func resumeAudio() {
        keys.setGraphRate(sampleRate(for: .keys))
        meters.reinstall()
    }

    private func libraryKey(_ slot: KeySlot) -> SF2Library.Key? {
        guard let font = catalog.soundFont(slot.fileID) else { return nil }
        return SF2Library.Key(url: font.url, bank: slot.bank, program: slot.program)
    }

    /// Notes already sounding finish on the old program; new notes wait until the new one is resident.
    private func syncKeyProgram(_ index: Int) {
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
    private func refreshPreload() {
        var programKeys: [SF2Library.Key] = []
        for slot in state.keySlots {
            if let key = libraryKey(slot), !programKeys.contains(key) { programKeys.append(key) }
        }
        library.pin(programKeys)
    }

    // MARK: MIDI thread

    private func handleMIDI(_ event: MIDIEvent) {
        switch event.kind {
        case .clock, .start, .stop, .resume:
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

        let fromKeyboard = keyboards.isEmpty || keyboards.contains(event.sourceID)

        var bound = false
        for binding in bindings where matches(binding, event) {
            bound = true
            perform(binding, event: event)
        }

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
        case .keysCutoff, .keysResonance, .keysLow, .keysHigh, .keysCompressor, .keysReverb, .keysSpace, .keysPan, .keysTune:
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
            queueCC(.master, value)
            pulse(.master, 0)
        }
    }

    // MARK: Main thread

    private func bind(_ armed: ArmedControl, match: MIDIMatch) {
        let binding = MIDIBinding(target: armed.target, index: armed.index, match: match)
        var replaced: [MIDIBinding] = []
        updateRig { replaced = $0.setBinding(binding) }
        store.saveRig(rig)
        self.armed = nil
        syncLearn()
        let title = armed.target.title(index: armed.index)
        if let old = replaced.first {
            status = "\(match.label) → \(title). Removed from \(old.target.title(index: old.index))."
        } else {
            status = "\(match.label) → \(title)."
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

    private func syncLearn() {
        route.lock.lock()
        route.learn = learnOn
        route.armed = armed
        route.lock.unlock()
    }

    private func syncRoute() {
        route.lock.lock()
        route.bindings = rig.bindings
        route.keyboards = Set(rig.keyboardSourceIDs)
        route.modCutoff = state.keySlots.map(\.modCutoff)
        route.filters = state.keySlots.map { LayerFilter(inputID: $0.inputID, channel: $0.channel) }
        route.lock.unlock()
    }

    private func syncMIDIEndpoints() {
        let snapshot = midi.endpointSnapshot()
        midiSources = snapshot.sources
        let seen = Set(rig.seenMIDISources)
        let fresh = snapshot.sources.map(\.id).filter { !seen.contains($0) }
        if !fresh.isEmpty {
            updateRig { next in
                next.enabledMIDISources.append(contentsOf: fresh)
                next.seenMIDISources.append(contentsOf: fresh)
                next.midiSourcesKnown = true
            }
            midi.enabledSourceIDs = Set(rig.enabledMIDISources)
            store.saveRig(rig)
        }
    }

    private func syncDevices() {
        devices = router.devices
        if let error = router.lastError, !error.isEmpty {
            status = error
        }
    }

    private func catalogReload() {
        var next = catalog
        next.reload()
        catalog = next
    }

    private func importFile(kind: ImportKind, assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind.allowedTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try catalog.importFile(from: url, kind: kind)
            catalogReload()
            assign(id)
        } catch {
            status = "Could not import the file."
        }
    }

    func isLit(_ kind: StageActivity.Kind, _ index: Int) -> Bool {
        activity?.kind == kind && activity?.index == index
    }

    private func pulse(_ kind: StageActivity.Kind, _ index: Int) {
        let send = { [weak self] in
            guard let self else { return }
            let token = UUID()
            self.activity = StageActivity(kind: kind, index: index, token: token)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                guard self?.activity?.token == token else { return }
                self?.activity = nil
            }
        }
        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async(execute: send)
        }
    }

    private func updateState(_ body: (inout KeyState) -> Void) {
        var next = state
        body(&next)
        guard next != state else { return }
        let routing = next.keySlots.map(\.modCutoff) != state.keySlots.map(\.modCutoff)
            || next.keySlots.map(\.inputID) != state.keySlots.map(\.inputID)
            || next.keySlots.map(\.channel) != state.keySlots.map(\.channel)
        state = next
        if routing { syncRoute() }
        scheduleSave()
    }

    /// Knob drags change the state many times a second; write once they settle.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingSave = nil
            self.store.saveState(self.state)
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func updateRig(_ body: (inout Rig) -> Void) {
        var next = rig
        body(&next)
        rig = next
        syncRoute()
    }

    private func registerMeters() {
        for (index, node) in keys.meterNodes.enumerated() {
            meters.register(node, index: MeterStore.Channel.keys + index)
        }
        meters.register(keys.masterMeterNode, index: MeterStore.Channel.master)
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
                case .master: next.master = value
                }
            }
        }
        for index in filtered { keys.configure(part: index, slot: state.keySlots[index]) }
    }

    private static func setKnob(_ target: BindingTarget, _ value: Double, in slot: inout KeySlot) {
        switch target {
        case .keysCutoff: slot.cutoff = value
        case .keysResonance: slot.resonance = value
        case .keysLow: slot.low = value
        case .keysHigh: slot.high = value
        case .keysCompressor: slot.compressor = value
        case .keysReverb: slot.reverb = value
        case .keysSpace: slot.space = value
        case .keysPan: slot.pan = value
        case .keysTune: slot.tune = value
        default: break
        }
    }
}

private final class PendingCC {
    enum Key: Hashable {
        case keys(Int)
        case knob(BindingTarget, Int)
        case master
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

private final class LastMessage {
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

private final class MIDIRoute {
    let lock = NSLock()
    var learn = false
    var armed: ArmedControl?
    var bindings: [MIDIBinding] = []
    var keyboards: Set<Int32> = []
    var modCutoff: [Bool] = []
    var filters: [LayerFilter] = []
}

private struct LayerFilter {
    var inputID: Int32?
    var channel: Int?
}
