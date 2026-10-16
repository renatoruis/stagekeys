import AVFoundation
import Foundation

extension AppModel {
    func setPadFamily(index: Int, family: String?) {
        let pitch = set.padPitch
        updateSet {
            $0.padLayers[index].familyID = family
            $0.padLayers[index].pitch = pitch
        }
        syncPad(index)
        refreshPreload()
    }

    func setPadPitch(_ pitch: String) {
        updateSet { next in
            next.padPitch = pitch
            for index in next.padLayers.indices {
                next.padLayers[index].pitch = pitch
            }
        }
        pads.setPitch(pitch)
    }

    func setPadVolume(index: Int, volume: Double) {
        let value = min(1, max(0, volume))
        updateSet { $0.padLayers[index].volume = value }
        pads.setVolume(index: index, volume: Float(value))
    }

    /// nil turns the filter off.
    func setPadMaster(_ value: Double) {
        let level = min(1, max(0, value))
        updateSet { $0.padMaster = level }
        pads.setMaster(Float(level))
    }

    func previewPadMaster(_ value: Double) {
        pads.setMaster(Float(min(1, max(0, value))))
    }

    func setPadCutoff(index: Int, value: Double?) {
        let amount = value.map { min(1, max(0, $0)) }
        updateSet { $0.padLayers[index].cutoff = amount }
        pads.setCutoff(index: index, cutoff: amount ?? 1)
    }

    /// nil turns the send off.
    func setPadSpace(index: Int, value: Double?) {
        let amount = value.map { min(1, max(0, $0)) }
        updateSet { $0.padLayers[index].space = amount }
        pads.setSpace(index: index, amount: amount ?? 0)
    }

    func setPadEnabled(index: Int, enabled: Bool) {
        updateSet {
            $0.padLayers[index].enabled = enabled
            $0.padLayers[index].playing = enabled
        }
        syncPad(index)
        if enabled && set.padsRunning { pulse(.padPlay, index) }
    }

    func setPadsRunning(_ running: Bool) {
        updateSet { $0.padsRunning = running }
        for index in 0..<PadEngine.layerCount {
            syncPad(index)
        }
        if running { pulse(.padPlay, 0) }
    }

    func setPadFollow(index: Int, follow: Bool) {
        updateSet { $0.padLayers[index].followMIDI = follow }
        pads.setFollow(index: index, follow: follow)
    }

    func importPad(index: Int) {
        importFile(kind: .pad) { id in
            self.catalogReload()
            let name = self.catalog.padFamilies.first { $0.pitches.values.contains(id) }?.id
            self.setPadFamily(index: index, family: name)
        }
    }

    func previewPadVolume(index: Int, volume: Double) {
        pads.setVolume(index: index, volume: Float(min(1, max(0, volume))))
    }

    func previewPadCutoff(index: Int, cutoff: Double) {
        pads.setCutoff(index: index, cutoff: cutoff)
    }

    func previewPadSpace(index: Int, value: Double) {
        pads.setSpace(index: index, amount: value)
    }

    func padFamilyTitle(_ index: Int) -> String {
        guard let id = set.padLayers[index].familyID else { return "Empty" }
        return catalog.padFamilies.first { $0.id == id }?.name ?? id
    }

    func padSourceTitle(_ index: Int) -> String {
        guard let id = set.padLayers[index].familyID else { return "Pad" }
        return catalog.padFamilies.first { $0.id == id }?.isImported == true ? ResourceCatalog.importedCategory : "Library"
    }

    /// Supermassive settings are global: one file per engine, shared by every song.
    var spaceSettings: [(AVAudioUnit, URL)] {
        [(pads.spaceNode, "Pads")].compactMap { node, name in
            node.map { ($0, store.root.appendingPathComponent("Supermassive-\(name).plist")) }
        }
    }

    func saveSpaceSettings() {
        for (node, url) in spaceSettings {
            Supermassive.save(node, to: url)
        }
    }

    func syncPad(_ index: Int) {
        let layer = set.padLayers[index]
        pads.configure(
            index: index,
            family: layer.familyID,
            pitch: set.padPitch,
            volume: Float(layer.volume),
            playing: set.padsRunning && layer.enabled,
            followMIDI: layer.followMIDI,
            urls: padURLs(layer.familyID)
        )
    }

    func padURLs(_ family: String?) -> [String: URL] {
        guard let family, let group = catalog.padFamilies.first(where: { $0.id == family }) else { return [:] }
        var urls: [String: URL] = [:]
        for (pitch, id) in group.pitches {
            if let url = catalog.url(for: id) { urls[pitch] = url }
        }
        return urls
    }
}
