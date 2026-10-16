import Foundation

extension AppModel {
    func renameSetList(_ name: String) {
        updateRig { $0.setName = name }
        store.saveRig(rig)
    }

    var nextSetName: String {
        guard sets.count > 1 else { return "—" }
        return sets[(setIndex + 1) % sets.count].name
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

    func step(_ delta: Int) {
        guard !sets.isEmpty else { return }
        flushSave()
        let next = (setIndex + delta + sets.count) % sets.count
        open(sets[next])
    }

    func open(_ next: PerformanceSet) {
        if next.id == set.id { return }
        flushSave()
        let normalized = next.normalized()
        set = normalized
        updateRig { $0.currentSetID = normalized.id }
        store.saveRig(rig)
        applyMusical(normalized)
        metronome.beginSong()
    }

    func newSet() {
        guard !liveMode else { return }
        flushSave()
        let created = PerformanceSet.make(name: "Song \(sets.count + 1)")
        sets.append(created)
        store.save(created)
        store.saveOrder(sets.map(\.id))
        open(created)
    }

    func duplicateCurrent() {
        guard !liveMode else { return }
        flushSave()
        var copy = set
        copy.id = UUID()
        copy.name = "\(set.name) Copy"
        sets.insert(copy, at: min(setIndex + 1, sets.count))
        store.save(copy)
        store.saveOrder(sets.map(\.id))
        open(copy)
    }

    func duplicate(id: UUID) {
        guard !liveMode, let index = sets.firstIndex(where: { $0.id == id }) else { return }
        flushSave()
        var copy = sets[index]
        copy.id = UUID()
        copy.name = "\(copy.name) Copy"
        sets.insert(copy, at: index + 1)
        store.save(copy)
        store.saveOrder(sets.map(\.id))
        refreshPreload()
    }

    func delete(id: UUID) {
        guard !liveMode else { return }
        if id == set.id {
            deleteCurrent()
            return
        }
        store.delete(id: id)
        sets.removeAll { $0.id == id }
        store.saveOrder(sets.map(\.id))
        refreshPreload()
    }

    func moveSong(id: UUID, before index: Int) {
        guard !liveMode, let from = sets.firstIndex(where: { $0.id == id }) else { return }
        var destination = index
        if from < index { destination -= 1 }
        destination = min(max(0, destination), sets.count - 1)
        guard from != destination else { return }
        let item = sets.remove(at: from)
        sets.insert(item, at: destination)
        store.saveOrder(sets.map(\.id))
        refreshPreload()
    }

    func renameSong(id: UUID, name: String) {
        if id == set.id {
            rename(name)
            return
        }
        guard let index = sets.firstIndex(where: { $0.id == id }) else { return }
        sets[index].name = name
        store.save(sets[index])
    }

    func deleteCurrent() {
        guard !liveMode else { return }
        let removed = set.id
        let index = setIndex
        pendingSave?.cancel()
        pendingSave = nil
        store.delete(id: removed)
        sets.removeAll { $0.id == removed }
        if sets.isEmpty {
            let fresh = PerformanceSet.make(name: "Song 1")
            sets = [fresh]
            store.save(fresh)
        }
        store.saveOrder(sets.map(\.id))
        open(sets[min(index, sets.count - 1)])
    }

    func rename(_ name: String) {
        updateSet { $0.name = name }
        if let index = sets.firstIndex(where: { $0.id == set.id }) {
            sets[index].name = name
        }
    }

    /// Keeps the previous, current and next song resident: pads and every drum sample of the set list.
    func refreshPreload() {
        let index = setIndex
        var songs = [set]
        if sets.count > 1 {
            songs.append(sets[(index + 1) % sets.count])
            if sets.count > 2 { songs.append(sets[(index - 1 + sets.count) % sets.count]) }
        }
        var drumURLs: [URL] = []
        var seen = Set<URL>()
        for song in [set] + sets {
            for pad in song.drumPads {
                if let id = pad.assetID, let url = catalog.url(for: id), seen.insert(url).inserted { drumURLs.append(url) }
            }
        }
        bufferCache.pin(drumURLs, rate: drums.sampleRate, group: "drums")

        var padList: [URL] = []
        var padSeen = Set<URL>()
        for song in songs.prefix(2) {
            for layer in song.padLayers where layer.familyID != nil {
                let urls = padURLs(layer.familyID)
                let ordered = [urls[song.padPitch]].compactMap { $0 } + urls.values.sorted { $0.path < $1.path }
                for url in ordered where padSeen.insert(url).inserted { padList.append(url) }
            }
        }
        bufferCache.pin(padList, rate: pads.sampleRate, group: "pads")
    }
}
