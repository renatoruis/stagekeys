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
    enum Kind: Equatable {
        case padLevel
        case padCutoff
        case padMaster
        case padPlay
        case drum
    }

    var kind: Kind
    var index: Int
    var token: UUID
}

@Observable
final class AppModel {
    let router = OutputRouter()
    let midi = MIDIManager(clientName: "StageKeys Play")
    let metronome = MetronomeEngine()
    let bufferCache: AudioBufferCache
    let pads: PadEngine
    let drums: DrumEngine
    let pulse = PulseState()
    let monitor = MIDIMonitor()
    let meters = MeterStore.shared

    var catalog: ResourceCatalog
    var set: PerformanceSet
    var rig: Rig
    var sets: [PerformanceSet]
    var liveMode = false
    var learnOn = false
    var activity: StageActivity?
    var armed: ArmedControl?
    var metroRunning = false
    var status = "" { didSet { statusVersion &+= 1 } }
    var statusVersion = 0
    var selectedDrum = 0
    var devices: [AudioDevice] = []
    var midiSources: [MIDIEndpointInfo] = []
    var midiDestinations: [MIDIEndpointInfo] = []

    let store: SetStore
    var pendingSave: DispatchWorkItem?
    let route = MIDIRoute()
    let pendingCC = PendingCC()
    let lastMessage = LastMessage()
    var recentLearn: (match: MIDIMatch, time: Date)?
    var learnStarted = Date.distantPast

    var setIndex: Int { sets.firstIndex { $0.id == set.id } ?? 0 }

    init() {
        let store = SetStore()
        self.store = store
        let cache = AudioBufferCache()
        bufferCache = cache
        pads = PadEngine(cache: cache)
        drums = DrumEngine(cache: cache)
        var catalog = ResourceCatalog(userRoot: store.libraryFolder)
        catalog.reload()
        var rig = store.loadRig()
        let legacy = catalog.legacyNames()
        var sets = store.loadSets().map { loaded in
            let migrated = legacy.migrate(loaded)
            if migrated != loaded { store.save(migrated) }
            return migrated
        }
        if sets.isEmpty {
            let first = PerformanceSet.make(name: "Song 1")
            sets = [first]
            store.save(first)
            store.saveOrder([first.id])
        }
        let current = sets.first { $0.id == rig.currentSetID } ?? sets[0]
        rig.currentSetID = current.id
        self.catalog = catalog
        self.rig = rig
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
        applyMusical(current)
        syncDevices()
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
        resumePads()
    }

    func setPick(motor: Motor, pick: ChannelPick) {
        var route = rig.route(for: motor)
        route.pick = pick
        updateRig { $0.setRoute(route, for: motor) }
        store.saveRig(rig)
        router.apply(route: route, to: motor)
        resumePads()
    }

    func setBuffer(_ frames: Int) {
        updateRig { $0.bufferFrames = frames }
        store.saveRig(rig)
        router.applyBuffer(frames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
        resumePads()
    }

    func setMetering(_ on: Bool) {
        meters.setEnabled(on)
    }

    private func wire() {
        router.onChange = { [weak self] in
            DispatchQueue.main.async { self?.syncDevices() }
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
            self?.flushSave()
        }
    }

    private func installAudio() {
        metronome.install(on: router.output(for: .metronome))
        pads.install(on: router.output(for: .pads), sampleRate: sampleRate(for: .pads))
        drums.install(on: router.output(for: .drums), sampleRate: sampleRate(for: .drums))
        for (node, url) in spaceSettings {
            Supermassive.restore(node, from: url)
        }
        router.applyBuffer(rig.bufferFrames)
        for motor in Motor.allCases {
            router.apply(route: rig.route(for: motor), to: motor)
        }
    }

    private func sampleRate(for motor: Motor) -> Double {
        router.nominalSampleRate(uid: rig.route(for: motor).deviceUID)
    }

    func applyMusical(_ performance: PerformanceSet) {
        metronome.apply(settings: performance.metronome)
        loadClick()
        pads.setMaster(Float(performance.padMaster))
        for index in 0..<PadEngine.layerCount {
            pads.setCutoff(index: index, cutoff: performance.padLayers[index].cutoff ?? 1)
            pads.setSpace(index: index, amount: performance.padLayers[index].space ?? 0)
            syncPad(index)
        }
        for index in 0..<DrumEngine.padCount {
            let pad = performance.drumPads[index]
            drums.setGain(index: index, gain: Float(pad.gain))
            drums.setReverb(index: index, amount: pad.reverb ?? 0)
            drums.load(index: index, url: pad.assetID.flatMap { catalog.url(for: $0) })
        }
        refreshPreload()
    }

    private func resumePads() {
        let drumsChanged = drums.setGraphRate(sampleRate(for: .drums))
        pads.setGraphRate(sampleRate(for: .pads))
        meters.reinstall()
        for index in 0..<PadEngine.layerCount {
            syncPad(index)
        }
        if drumsChanged {
            for index in 0..<DrumEngine.padCount {
                let pad = set.drumPads[index]
                drums.load(index: index, url: pad.assetID.flatMap { catalog.url(for: $0) })
            }
        }
        refreshPreload()
    }

    private func syncDevices() {
        devices = router.devices
        if let error = router.lastError, !error.isEmpty {
            status = error
        }
    }

    func catalogReload() {
        var next = catalog
        next.reload()
        catalog = next
    }

    func importFile(kind: ImportKind, assign: @escaping (String) -> Void) {
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

    func pulse(_ kind: StageActivity.Kind, _ index: Int) {
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

    func updateSet(_ body: (inout PerformanceSet) -> Void) {
        var next = set
        body(&next)
        guard next != set else { return }
        set = next
        scheduleSave()
    }

    /// Knob drags change the song many times a second; write once they settle.
    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func flushSave() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        guard let index = sets.firstIndex(where: { $0.id == set.id }) else { return }
        sets[index] = set
        store.save(set)
    }

    func updateRig(_ body: (inout Rig) -> Void) {
        var next = rig
        body(&next)
        rig = next
        syncRoute()
    }

    private func registerMeters() {
        for (index, node) in pads.meterNodes.enumerated() {
            meters.register(node, index: MeterStore.Channel.pad + index)
        }
        drums.meterNodes.forEach { meters.register($0, index: MeterStore.Channel.drums) }
        metronome.meterNodes.forEach { meters.register($0, index: MeterStore.Channel.metronome) }
    }
}
