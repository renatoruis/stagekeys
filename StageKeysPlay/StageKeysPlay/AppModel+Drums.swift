import Foundation

extension AppModel {
    func chooseDrum(_ index: Int) {
        selectedDrum = index
        drums.trigger(index: index, velocity: 1)
        pulse(.drum, index)
    }

    func setDrumSample(index: Int, id: String?) {
        updateSet { $0.drumPads[index].assetID = id }
        drums.load(index: index, url: id.flatMap { catalog.url(for: $0) })
        refreshPreload()
    }

    func setDrumGain(index: Int, gain: Double) {
        let value = min(1, max(0, gain))
        updateSet { $0.drumPads[index].gain = value }
        drums.setGain(index: index, gain: Float(value))
    }

    /// nil turns the send off.
    func setDrumReverb(index: Int, amount: Double?) {
        let value = amount.map { min(1, max(0, $0)) }
        updateSet { $0.drumPads[index].reverb = value }
        drums.setReverb(index: index, amount: value ?? 0)
    }

    func setDrumColor(index: Int, color: String) {
        updateSet { $0.drumPads[index].color = color }
    }

    func setDrumLayout(_ count: Int) {
        let layout = [4, 6, 8].contains(count) ? count : 8
        updateSet { $0.drumLayout = layout }
        if selectedDrum >= layout { selectedDrum = 0 }
    }

    func importDrum(index: Int) {
        importFile(kind: .drum) { id in
            self.catalogReload()
            self.setDrumSample(index: index, id: id)
        }
    }

    func previewDrumGain(index: Int, gain: Double) {
        drums.setGain(index: index, gain: Float(min(1, max(0, gain))))
    }

    func previewDrumReverb(index: Int, amount: Double) {
        drums.setReverb(index: index, amount: amount)
    }

    func drumTitle(_ index: Int) -> String {
        guard let id = set.drumPads[index].assetID else { return "\(index + 1)" }
        return catalog.drumSamples.first { $0.id == id }?.name ?? "\(index + 1)"
    }
}
