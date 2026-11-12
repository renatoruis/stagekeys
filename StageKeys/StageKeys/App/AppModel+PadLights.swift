import Foundation

extension AppModel {
    func syncPadLights() {
        guard rig.padLights, padLights.destinationID != nil else { return }
        var lights: [Int: UInt8] = [:]
        for binding in rig.bindings where binding.target == .drumNote && binding.match.kind == .note {
            lights[binding.match.number] = drumLight(binding.index)
        }
        padLights.show(lights)
    }

    func syncPadLightsDevice() {
        let next = midi.destinations.first { name in
            name.name.contains("Launchkey") && name.name.contains("DAW In")
        }?.id
        let changed = padLights.destinationID != next
        padLights.destinationID = next
        guard rig.padLights else { return }
        if next == nil {
            padLights.clearCache()
            return
        }
        if changed {
            padLights.connect()
            syncPadLights()
        }
    }

    func setPadLights(_ on: Bool) {
        updateRig { $0.padLights = on }
        rigStore.save(rig)
        if on {
            padLights.connect()
            syncPadLights()
        } else {
            padLights.disconnect()
        }
    }

    func flashDrumPad(_ index: Int) {
        guard rig.padLights, padLights.destinationID != nil else { return }
        guard let binding = rig.binding(for: .drumNote, index: index), binding.match.kind == .note else { return }
        padLights.flash(note: binding.match.number, restore: drumLight(index))
    }

    /// Loaded drum pads whose MIDI mapping will not light a Launchkey pad.
    var darkDrumPads: [Int] {
        guard rig.padLights, padLights.destinationID != nil else { return [] }
        let loaded = (0..<set.drumLayout).filter { set.drumPads.indices.contains($0) && set.drumPads[$0].assetID != nil }
        return rig.drumPadsOffLaunchkey(loaded)
    }

    /// Maps drum pads 1–8 to the eight left Launchkey pads, replacing whatever they were bound to.
    func mapLaunchkeyDrumPads() {
        var replaced: [MIDIBinding] = []
        updateRig { replaced = $0.mapLaunchkeyDrums() }
        rigStore.save(rig)
        syncPadLights()
        var message = "Drum pads 1–8 mapped to the Launchkey pads."
        if !replaced.isEmpty {
            message += " Removed \(replaced.count) other mapping(s)."
        }
        status = message
    }

    func drumLight(_ index: Int) -> UInt8 {
        guard index < set.drumLayout, set.drumPads.indices.contains(index), set.drumPads[index].assetID != nil else { return 0 }
        return PadLights.palette(DrumColor(rawValue: set.drumPads[index].color) ?? .stone)
    }
}
