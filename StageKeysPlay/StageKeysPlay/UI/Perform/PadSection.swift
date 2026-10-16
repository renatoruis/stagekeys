import SwiftUI

struct PadSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let running = model.set.padsRunning
        Panel(title: "Pads", color: DS.pads) {
            HStack(spacing: DS.space3) {
                SpaceEditorButton(node: model.pads.spaceNode, title: "Pads")
                if model.learnOn {
                    LearnChipFor(state: LearnState(model, .padsTransport, 0), prefix: "Play/Stop ")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: DS.space4) {
            HStack(alignment: .center, spacing: DS.space4) {
                PowerButton(
                    on: running,
                    color: DS.pads,
                    symbol: running ? "stop.fill" : "play.fill",
                    label: running ? "Stop all pads" : "Play all pads",
                    size: 64
                ) {
                    model.setPadsRunning(!running)
                }
                .overlay(Circle().strokeBorder(model.isLit(.padPlay, 0) ? DS.pads : Color.clear, lineWidth: 2))
                Text(running ? "Playing" : "Stopped")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(running ? DS.pads : DS.textSecondary)
                Spacer(minLength: 0)
                let master = KnobMIDI(model, .padMaster, 0, .padMaster)
                Knob(
                    label: "Master",
                    value: model.set.padMaster,
                    color: DS.pads,
                    defaultValue: 1,
                    size: 48,
                    lit: master.lit,
                    mapped: master.mapped,
                    onChange: { model.previewPadMaster($0) },
                    onCommit: { model.setPadMaster($0) }
                )
                .learnChip(master.learn, width: 56)
                .help("Level of all pads")
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("KEY")
                        .font(.dsSection)
                        .foregroundStyle(DS.textMuted)
                    Text(KeyButtons.label(for: model.set.padPitch))
                        .font(.system(size: 34, weight: .semibold))
                        .foregroundStyle(DS.pads)
                }
            }
            KeyButtons(selection: model.set.padPitch, color: DS.pads, height: 40, fontSize: 14) {
                model.setPadPitch($0)
            }
            .equatable()
            HStack(spacing: DS.space2) {
                ForEach(0..<PadEngine.layerCount, id: \.self) { index in
                    PadStrip(
                        index: index,
                        layer: model.set.padLayers[index],
                        family: model.padFamilyTitle(index),
                        source: model.padSourceTitle(index),
                        volumeLearn: model.learnOn ? LearnState(model, .padVolume, index) : nil,
                        toggleLearn: model.learnOn ? LearnState(model, .padToggle, index) : nil,
                        volumeMapped: model.rig.binding(for: .padVolume, index: index) != nil,
                        cutoff: KnobMIDI(model, .padCutoff, index, .padCutoff),
                        levelLit: model.isLit(.padLevel, index),
                        playLit: model.isLit(.padPlay, index),
                        running: model.set.padsRunning,
                        live: model.liveMode
                    )
                    .equatable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

struct PadStrip: View, Equatable {
    @Environment(AppModel.self) private var model
    var index: Int
    var layer: PadLayer
    var family: String
    var source: String
    var volumeLearn: LearnState?
    var toggleLearn: LearnState?
    var volumeMapped: Bool
    var cutoff: KnobMIDI
    var levelLit: Bool
    var playLit: Bool
    var running: Bool
    var live: Bool
    @State private var picking = false

    static func == (lhs: PadStrip, rhs: PadStrip) -> Bool {
        lhs.index == rhs.index && lhs.layer == rhs.layer && lhs.family == rhs.family && lhs.source == rhs.source
            && lhs.volumeLearn == rhs.volumeLearn && lhs.toggleLearn == rhs.toggleLearn
            && lhs.volumeMapped == rhs.volumeMapped && lhs.cutoff == rhs.cutoff
            && lhs.levelLit == rhs.levelLit && lhs.playLit == rhs.playLit && lhs.running == rhs.running && lhs.live == rhs.live
    }

    var body: some View {
        let color = DS.padColors[index]
        let loaded = layer.familyID != nil
        VStack(spacing: DS.space2) {
            HStack {
                Text("\(index + 1)")
                    .font(.dsChannel)
                    .foregroundStyle(color)
                if loaded {
                    Text(source.uppercased())
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                        .lineLimit(1)
                }
                Spacer()
                if loaded && !live {
                    PowerButton(
                        on: layer.followMIDI,
                        color: color,
                        symbol: "pianokeys",
                        label: layer.followMIDI ? "Follows incoming MIDI notes. Click to stay on the song key." : "Stays on the song key. Click to follow incoming MIDI notes.",
                        size: 28
                    ) {
                        model.setPadFollow(index: index, follow: !layer.followMIDI)
                    }
                }
                if loaded {
                    PowerButton(
                        on: layer.enabled,
                        color: color,
                        label: layer.enabled ? "Disable pad" : "Enable pad",
                        size: 28
                    ) {
                        model.setPadEnabled(index: index, enabled: !layer.enabled)
                    }
                    .overlay(Circle().strokeBorder(playLit ? color : Color.clear, lineWidth: 2))
                }
            }
            if live {
                Text(family)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(loaded ? DS.textPrimary : DS.textMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            } else {
                LibraryButton(
                    title: family,
                    symbol: LibrarySymbols.pad(source),
                    color: color,
                    empty: !loaded,
                    help: "Choose a pad for slot \(index + 1)"
                ) { picking = true }
            }
            if !loaded {
                Spacer(minLength: 0)
                if !live {
                    TextButton(title: "Import loop…", symbol: "square.and.arrow.down") { model.importPad(index: index) }
                }
            }
            if loaded {
            HStack(spacing: DS.space2) {
                Knob(
                    label: "Cutoff",
                    value: layer.cutoff,
                    color: color,
                    defaultValue: 1,
                    size: 48,
                    enabled: layer.enabled,
                    lit: cutoff.lit,
                    mapped: cutoff.mapped,
                    format: EffectKnobs.hertz,
                    onChange: { model.previewPadCutoff(index: index, cutoff: $0) },
                    onCommit: { model.setPadCutoff(index: index, value: $0) },
                    onReset: { model.setPadCutoff(index: index, value: nil) }
                )
                .learnChip(cutoff.learn, width: 56)
                Knob(
                    label: "Space",
                    value: layer.space,
                    color: color,
                    size: 48,
                    enabled: layer.enabled && model.pads.spaceNode != nil,
                    onChange: { model.previewPadSpace(index: index, value: $0) },
                    onCommit: { model.setPadSpace(index: index, value: $0) },
                    onReset: { model.setPadSpace(index: index, value: nil) }
                )
                .help(model.pads.spaceNode != nil ? "Valhalla Supermassive send" : "Valhalla Supermassive not found")
            }
            HStack(alignment: .bottom, spacing: DS.space2) {
                VerticalFader(
                    value: layer.volume,
                    color: color,
                    defaultValue: 0.7,
                    lit: levelLit,
                    enabled: layer.enabled,
                    mapped: volumeMapped,
                    onChange: { model.previewPadVolume(index: index, volume: $0) },
                    onCommit: { model.setPadVolume(index: index, volume: $0) }
                )
                MeterBar(channel: MeterStore.Channel.pad + index)
            }
            .frame(minHeight: 140, maxHeight: .infinity)
            Text("\(Int((layer.volume * 100).rounded()))")
                .font(.dsValue)
                .foregroundStyle(layer.enabled ? DS.textPrimary : DS.textMuted)
            if let volumeLearn {
                LearnChipFor(state: volumeLearn)
            }
            if let toggleLearn {
                LearnChipFor(state: toggleLearn, prefix: "Enable ")
            }
            }
        }
        .padding(DS.space2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
        .opacity(loaded && !layer.enabled ? 0.7 : 1)
        .sheet(isPresented: $picking) {
            PadPicker(index: index) { picking = false }
                .environment(model)
        }
    }
}

private struct PadPicker: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var close: () -> Void

    var body: some View {
        let imported = ResourceCatalog.importedCategory
        LibraryPicker(
            meta: "Pad \(index + 1)",
            title: model.padFamilyTitle(index),
            color: DS.padColors[index],
            noun: "pads",
            items: model.catalog.padFamilies.map { family in
                LibraryItem(
                    id: family.id,
                    name: family.name,
                    detail: family.pitches.count >= 12 ? "All keys" : "\(family.pitches.count) keys",
                    section: family.isImported ? imported : "Library"
                )
            },
            sections: ["Library", imported],
            selection: model.set.padLayers[index].familyID,
            importTitle: "Import loop…",
            symbol: LibrarySymbols.pad,
            onChoose: { model.setPadFamily(index: index, family: $0) },
            onImport: { model.importPad(index: index) },
            close: close
        )
    }
}
