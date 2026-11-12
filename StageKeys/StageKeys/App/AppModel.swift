import AppKit
import AVFoundation
import Foundation
import Observation
import UniformTypeIdentifiers

@Observable
final class PulseState {
    var beat = 1
    var accent = false
    var counting = false
}

/// Last MIDI message received, for the learn indicator. Updated at most ~20 times per second.
@Observable
final class MIDIMonitor {
    var label = ""
    var source = ""
    var stamp = 0
}

struct StageActivity: Equatable {
    enum Kind: Hashable {
        case keysLevel
        case knob(BindingTarget)
        case keysMaster
        case padLevel
        case padCutoff
        case padMaster
        case padPlay
        case drum
    }
}

/// One lit control. Views read `on`, so a pulse redraws only the control it belongs to.
@Observable
final class ActivityLight {
    var on = false
    @ObservationIgnored var generation = 0
}

enum StageTab: String, CaseIterable {
    case show
    case keys
}

@Observable
final class AppModel {
    let router = OutputRouter()
    let midi = MIDIManager(clientName: "StageKeys")
    let keys = SF2Engine()
    let library = SF2Library()
    let metronome = MetronomeEngine()
    let bufferCache: AudioBufferCache
    let pads: PadEngine
    let drums: DrumEngine
    let pulse = PulseState()
    let monitor = MIDIMonitor()
    let meters = MeterStore.shared
    let sounds: SoundLibrary

    var sf2Catalog: SF2Catalog
    var showCatalog: ShowCatalog
    var state: KeyState
    var set: PerformanceSet
    var rig: Rig
    var sets: [PerformanceSet]
    var tab: StageTab = .show
    var liveMode = false
    var learnOn = false
    var armed: ArmedControl?
    var metroRunning = false
    var status = "" { didSet { statusVersion &+= 1 } }
    var statusVersion = 0
    var selectedDrum = 0
    var devices: [AudioDevice] = []
    var midiSources: [MIDIEndpointInfo] = []
    var midiDestinations: [MIDIEndpointInfo] = []
    /// Bumped when an SF2 program starts or finishes loading.
    var libraryVersion = 0

    let keyStore: KeyStore
    let setStore: SetStore
    let rigStore: RigStore
    var pendingKeysSave: DispatchWorkItem?
    var pendingSetSave: DispatchWorkItem?
    let padLights: PadLights
    let route = MIDIRoute()
    let pendingCC = PendingCC()
    let lastMessage = LastMessage()
    var recentLearn: (match: MIDIMatch, time: Date)?
    var learnStarted = Date.distantPast
    var keyRequests: [SF2Library.Key?] = Array(repeating: nil, count: SF2Engine.partCount)
    @ObservationIgnored private var lights: [LightKey: ActivityLight] = [:]

    private struct LightKey: Hashable {
        var kind: StageActivity.Kind
        var index: Int
    }

    var setIndex: Int { sets.firstIndex { $0.id == set.id } ?? 0 }

    init() {
        padLights = PadLights(midi: midi)
        let keyStore = KeyStore()
        let setStore = SetStore()
        let rigStore = RigStore()
        self.keyStore = keyStore
        self.setStore = setStore
        self.rigStore = rigStore
        let sounds = SoundLibrary(libraryFolder: keyStore.libraryFolder)
        self.sounds = sounds
        sf2Catalog = SF2Catalog(userRoot: keyStore.libraryFolder, soundsRoot: sounds.folder)
        let cache = AudioBufferCache()
        bufferCache = cache
        pads = PadEngine(cache: cache)
        drums = DrumEngine(cache: cache)
        var showCatalog = ShowCatalog(userRoot: setStore.libraryFolder)
        showCatalog.reload()
        let legacy = showCatalog.legacyNames()
        let scaleGain = !UserDefaults.standard.bool(forKey: "drumGain40")
        var sets = setStore.loadSets().map { loaded in
            var migrated = legacy.migrate(loaded)
            if scaleGain {
                for index in migrated.drumPads.indices {
                    migrated.drumPads[index].gain = 0.4
                }
            }
            if migrated != loaded { setStore.save(migrated) }
            return migrated
        }
        if scaleGain {
            UserDefaults.standard.set(true, forKey: "drumGain40")
        }
        if sets.isEmpty {
            let first = PerformanceSet.make(name: "Song 1")
            sets = [first]
            setStore.save(first)
            setStore.saveOrder([first.id])
        }
        var rig = rigStore.load()
        let current = sets.first { $0.id == rig.currentSetID } ?? sets[0]
        rig.currentSetID = current.id
        self.showCatalog = showCatalog
        self.rig = rig
        self.state = keyStore.loadState()
        self.sets = sets
        self.set = current
        self.liveMode = rig.liveMode
        wire()
        installAudio()
        registerMeters()
        syncRoute()
        midi.enabledSourceIDs = Set(rig.enabledMIDISources)
        midi.start()
        syncMIDIEndpoints()
        applyKeysState()
        applyMusical(current)
        syncDevices()
    }

    func selectTab(_ tab: StageTab) {
        self.tab = tab
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
        rigStore.save(rig)
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
        rigStore.save(rig)
        router.apply(route: route, to: motor)
        resumeAudio()
    }

    func setPick(motor: Motor, pick: ChannelPick) {
        var route = rig.route(for: motor)
        route.pick = pick
        updateRig { $0.setRoute(route, for: motor) }
        rigStore.save(rig)
        router.apply(route: route, to: motor)
        resumeAudio()
    }

    func setBuffer(_ frames: Int) {
        updateRig { $0.bufferFrames = frames }
        rigStore.save(rig)
        router.applyBuffer(frames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
        resumeAudio()
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
            self?.reloadSF2Catalog()
            self?.applyKeysState()
        }
        pads.onPitchChange = { [weak self] index, pitch in
            self?.updateSet { next in
                next.padLayers[index].pitch = pitch
                next.padPitch = pitch
            }
        }
        metronome.onRunning = { [weak self] running in
            DispatchQueue.main.async { self?.metroRunning = running }
        }
        metronome.onPulse = { [weak self] beat, accent, counting in
            DispatchQueue.main.async {
                guard let pulse = self?.pulse else { return }
                if pulse.beat != beat { pulse.beat = beat }
                if pulse.accent != accent { pulse.accent = accent }
                if pulse.counting != counting { pulse.counting = counting }
            }
        }
        metronome.onBPM = { [weak self] bpm in
            DispatchQueue.main.async {
                guard let self else { return }
                let snapped = Self.snapBPM(bpm)
                guard abs(self.set.metronome.bpm - snapped) >= 0.2 else { return }
                self.setBPM(snapped)
            }
        }
        metronome.sendClock = { [weak self] in self?.sendMetronome(byte: 0xF8) }
        metronome.sendStart = { [weak self] in self?.sendMetronome(byte: 0xFA) }
        metronome.sendStop = { [weak self] in self?.sendMetronome(byte: 0xFC) }
        midi.onEvent = { [weak self] event in
            self?.handleMIDI(event)
        }
        midi.onEndpointsChanged = { [weak self] in
            DispatchQueue.main.async { self?.syncMIDIEndpoints() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            if let work = self.pendingKeysSave {
                work.cancel()
                self.pendingKeysSave = nil
                self.keyStore.saveState(self.state)
            }
            self.flushSave()
            if self.rig.padLights {
                self.padLights.disconnect()
            }
        }
    }

    private func installAudio() {
        keys.install(on: router.output(for: .keys), sampleRate: sampleRate(for: .keys))
        metronome.install(on: router.output(for: .metronome))
        pads.install(on: router.output(for: .pads), sampleRate: sampleRate(for: .pads))
        drums.install(on: router.output(for: .drums), sampleRate: sampleRate(for: .drums))
        router.applyBuffer(rig.bufferFrames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
    }

    func sampleRate(for motor: Motor) -> Double {
        router.nominalSampleRate(uid: rig.route(for: motor).deviceUID)
    }

    func applyMusical(_ performance: PerformanceSet) {
        metronome.apply(settings: performance.metronome)
        loadClick()
        pads.setMaster(Float(performance.padMaster))
        for index in 0..<PadEngine.layerCount {
            pads.setCutoff(index: index, cutoff: performance.padLayers[index].cutoff ?? 1)
            syncPad(index)
        }
        for index in 0..<DrumEngine.padCount {
            let pad = performance.drumPads[index]
            drums.setGain(index: index, gain: Float(pad.gain))
            drums.setReverb(index: index, amount: pad.reverb ?? 0)
            drums.load(index: index, url: pad.assetID.flatMap { showCatalog.url(for: $0) })
        }
        refreshPreload()
        syncPadLights()
    }

    private func resumeAudio() {
        keys.setGraphRate(sampleRate(for: .keys))
        let drumsChanged = drums.setGraphRate(sampleRate(for: .drums))
        pads.setGraphRate(sampleRate(for: .pads))
        meters.reinstall()
        for index in 0..<PadEngine.layerCount {
            syncPad(index)
        }
        if drumsChanged {
            for index in 0..<DrumEngine.padCount {
                let pad = set.drumPads[index]
                drums.load(index: index, url: pad.assetID.flatMap { showCatalog.url(for: $0) })
            }
        }
        refreshKeysPreload()
        refreshPreload()
    }

    private func syncDevices() {
        devices = router.devices
        if let error = router.lastError, !error.isEmpty {
            status = error
        }
    }

    func reloadSF2Catalog() {
        var next = sf2Catalog
        next.reload()
        sf2Catalog = next
    }

    func reloadShowCatalog() {
        var next = showCatalog
        next.reload()
        showCatalog = next
    }

    func importFile(kind: ImportKind, assign: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = kind.allowedTypes.compactMap { UTType(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id: String
            switch kind {
            case .soundFont:
                id = try sf2Catalog.importFile(from: url, kind: kind)
                reloadSF2Catalog()
            case .pad, .drum:
                id = try showCatalog.importFile(from: url, kind: kind)
                reloadShowCatalog()
            }
            assign(id)
        } catch {
            status = "Could not import the file."
        }
    }

    /// Main thread only.
    func light(_ kind: StageActivity.Kind, _ index: Int) -> ActivityLight {
        let key = LightKey(kind: kind, index: index)
        if let existing = lights[key] { return existing }
        let created = ActivityLight()
        lights[key] = created
        return created
    }

    func isLit(_ kind: StageActivity.Kind, _ index: Int) -> Bool {
        light(kind, index).on
    }

    func pulse(_ kind: StageActivity.Kind, _ index: Int) {
        let send = { [weak self] in
            guard let self else { return }
            let light = self.light(kind, index)
            light.generation &+= 1
            let generation = light.generation
            if !light.on { light.on = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak light] in
                guard let light, light.generation == generation else { return }
                light.on = false
            }
        }
        if Thread.isMainThread {
            send()
        } else {
            DispatchQueue.main.async(execute: send)
        }
    }

    func updateSet(_ body: (inout PerformanceSet) -> Void) {
        var next = set
        body(&next)
        guard next != set else { return }
        set = next
        scheduleSave()
    }

    /// Knob drags change the song many times a second; write once they settle.
    func scheduleSave() {
        pendingSetSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSetSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        guard let work = pendingSetSave else { return }
        work.cancel()
        pendingSetSave = nil
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return }
        sets[index] = set
        setStore.save(set)
    }

    func updateRig(_ body: (inout Rig) -> Void) {
        var next = rig
        body(&next)
        rig = next
        syncRoute()
    }

    private func registerMeters() {
        for (index, node) in keys.meterNodes.enumerated() {
            meters.register(node, index: MeterStore.Channel.keys + index)
        }
        meters.register(keys.masterMeterNode, index: MeterStore.Channel.keysMaster)
        for (index, node) in pads.meterNodes.enumerated() {
            meters.register(node, index: MeterStore.Channel.pad + index)
        }
        drums.meterNodes.forEach { meters.register($0, index: MeterStore.Channel.drums) }
        metronome.meterNodes.forEach { meters.register($0, index: MeterStore.Channel.metronome) }
    }
}
