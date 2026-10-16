import SwiftUI

/// Four SF2 layers, played from the keyboard inputs.
struct KeysView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Panel(title: "Keys", color: DS.keys) {
            HStack(spacing: DS.space3) {
                TransposeControl()
                if model.learnOn {
                    LearnChipFor(state: LearnState(model, .transposeDown, 0), prefix: "− ")
                    LearnChipFor(state: LearnState(model, .transposeUp, 0), prefix: "+ ")
                }
                KeysStatsView()
                SpaceEditorButton(node: model.keys.spaceNode, title: "Keys")
                if model.learnOn {
                    LearnChipFor(state: LearnState(model, .keysPanic, 0), prefix: "Panic ")
                }
                TextButton(title: "Panic", symbol: "exclamationmark.octagon", tint: DS.red, action: model.keysPanic)
                    .fixedSize()
                    .help("Stop every Keys note now")
            }
        } content: {
            VStack(spacing: DS.space3) {
                HStack(spacing: DS.space2) {
                    ForEach(0..<SF2Engine.partCount, id: \.self) { index in
                        KeyStrip(index: index)
                    }
                    MasterStrip()
                }
                .frame(maxHeight: .infinity)
                HStack(spacing: DS.space2) {
                    ControllersView()
                    KeyboardMap()
                }
                .frame(height: 120)
            }
        }
    }
}

/// Master fader of the four layers, metered after the output limiter.
private struct MasterStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let master = model.state.master
        VStack(spacing: DS.space2) {
            Text("MASTER")
                .font(.dsMeta.weight(.semibold))
                .foregroundStyle(DS.textMuted)
                .frame(height: 28)
            HStack(alignment: .bottom, spacing: DS.space2) {
                VerticalFader(
                    value: master,
                    color: DS.keys,
                    defaultValue: 1,
                    label: "Master",
                    lit: model.isLit(.master, 0),
                    desk: true,
                    mapped: model.rig.binding(for: .masterVolume, index: 0) != nil,
                    onChange: { model.previewMaster($0) },
                    onCommit: { model.setMaster($0) }
                )
                MeterBar(channel: MeterStore.Channel.master)
            }
            .frame(maxHeight: .infinity)
            Text("\(Int((master * 100).rounded()))")
                .font(.dsValue)
                .foregroundStyle(DS.textPrimary)
            if model.learnOn {
                LearnChipFor(state: LearnState(model, .masterVolume, 0))
            }
        }
        .padding(DS.space2)
        .frame(width: 96)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
    }
}

/// Transpose for all four layers.
private struct TransposeControl: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let value = model.state.transpose
        HStack(spacing: DS.space1) {
            Text("TRANSPOSE")
                .font(.dsMeta)
                .foregroundStyle(DS.textMuted)
            IconButton(symbol: "minus", label: "Transpose down", size: 26) {
                model.setKeysTranspose(value - 1)
            }
            Text(value == 0 ? "0" : String(format: "%+d", value))
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(value == 0 ? DS.textSecondary : DS.keys)
                .frame(minWidth: 30)
                .onTapGesture(count: 2) { model.setKeysTranspose(0) }
                .help("Semitones for all layers. Double-click to reset.")
            IconButton(symbol: "plus", label: "Transpose up", size: 26) {
                model.setKeysTranspose(value + 1)
            }
        }
    }
}

/// Voices and audio load, polled from the render reports.
private struct KeysStatsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let stats = model.keys.stats()
            let voices = stats.voices.reduce(0, +)
            let load = min(1, stats.load)
            HStack(spacing: DS.space3) {
                Text("\(voices) voices")
                    .font(.dsValue)
                    .foregroundStyle(DS.textSecondary)
                    .frame(minWidth: 70, alignment: .trailing)
                HStack(spacing: 6) {
                    Text("CPU")
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(DS.bgControl)
                            Capsule()
                                .fill(load > 0.7 ? DS.red : (load > 0.4 ? DS.yellow : DS.green))
                                .frame(width: geo.size.width * load)
                        }
                    }
                    .frame(width: 70, height: 6)
                    Text("\(Int((load * 100).rounded()))%")
                        .font(.dsValue)
                        .foregroundStyle(DS.textSecondary)
                        .frame(width: 36, alignment: .leading)
                }
                .help("Share of each audio buffer spent rendering the Keys")
            }
        }
    }
}

/// Sustain pedal, pitch bend and mod wheel as the Keys receive them.
private struct ControllersView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.05)) { _ in
            let state = model.keys.controllers()
            VStack(spacing: DS.space2) {
                HStack(spacing: DS.space2) {
                    wheel("PB", fill: Self.bendFill(state.bend), lit: abs(state.bend) > 0.01)
                        .help("Pitch bend")
                    wheel("MOD", fill: 0...state.modWheel, lit: state.modWheel > 0.01)
                        .help("Modulation wheel")
                }
                Text("SUS")
                    .font(.dsMeta.weight(.semibold))
                    .foregroundStyle(state.sustain ? DS.onSelected : DS.textMuted)
                    .frame(maxWidth: .infinity, minHeight: 20)
                    .background(state.sustain ? DS.keys : DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                    .help("Sustain pedal")
            }
            .frame(width: 64)
        }
    }

    private static func bendFill(_ bend: Double) -> ClosedRange<Double> {
        let value = 0.5 + min(1, max(-1, bend)) / 2
        return min(0.5, value)...max(0.5, value)
    }

    /// `fill` is the lit span of the track, 0 at the bottom.
    private func wheel(_ label: String, fill: ClosedRange<Double>, lit: Bool) -> some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let height = geo.size.height
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 4).fill(DS.bgControl)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(lit ? DS.keys : DS.textMuted.opacity(0.5))
                        .frame(height: max(2, height * (fill.upperBound - fill.lowerBound)))
                        .offset(y: -height * fill.lowerBound)
                }
            }
            .frame(maxWidth: .infinity)
            Text(label)
                .font(.dsMeta)
                .foregroundStyle(lit ? DS.textPrimary : DS.textMuted)
        }
    }
}

/// 88 keys with the notes currently sounding. Click or drag to play.
private struct KeyboardMap: View {
    @Environment(AppModel.self) private var model
    @State private var held: Int?

    private static let low = 21
    private static let high = 108
    private static let whiteNotes = (low...high).filter { !isBlack($0) }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 0.05)) { _ in
                let active = model.keys.stats().keys
                Canvas { context, size in
                    Self.draw(context: context, size: size, active: active)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in press(at: value.location, size: geo.size) }
                    .onEnded { _ in release() }
            )
        }
        .onDisappear(perform: release)
        .help("Click or drag to play; lower on the key is louder")
    }

    private func press(at point: CGPoint, size: CGSize) {
        let layout = Layout(size: size)
        guard let note = layout.note(at: point), note != held else { return }
        release()
        let depth = (point.y - layout.top) / max(1, layout.keyHeight)
        let velocity = Int(40 + 87 * min(1, max(0, depth)))
        held = note
        model.playKey(note, velocity: velocity)
    }

    private func release() {
        guard let note = held else { return }
        held = nil
        model.playKey(note, velocity: 0)
    }

    private static func isBlack(_ note: Int) -> Bool {
        [1, 3, 6, 8, 10].contains(note % 12)
    }

    private struct Layout {
        let top: CGFloat
        let keyHeight: CGFloat
        let whiteWidth: CGFloat

        init(size: CGSize) {
            top = 0
            keyHeight = size.height - top
            whiteWidth = size.width / CGFloat(KeyboardMap.whiteNotes.count)
        }

        func frame(_ note: Int) -> CGRect {
            if !KeyboardMap.isBlack(note) {
                let index = KeyboardMap.whiteNotes.firstIndex(of: note) ?? 0
                return CGRect(x: CGFloat(index) * whiteWidth, y: top, width: whiteWidth, height: keyHeight)
            }
            let left = frame(note - 1).minX
            return CGRect(x: left + whiteWidth * 0.65, y: top, width: whiteWidth * 0.7, height: keyHeight * 0.6)
        }

        func note(at point: CGPoint) -> Int? {
            guard point.y >= top, point.y <= top + keyHeight else { return nil }
            let index = Int(point.x / whiteWidth)
            guard KeyboardMap.whiteNotes.indices.contains(index) else { return nil }
            let white = KeyboardMap.whiteNotes[index]
            for black in [white - 1, white + 1] where black >= KeyboardMap.low && black <= KeyboardMap.high && KeyboardMap.isBlack(black) {
                if frame(black).contains(point) { return black }
            }
            return white
        }
    }

    private static func draw(context: GraphicsContext, size: CGSize, active: [Set<Int>]) {
        let layout = Layout(size: size)
        let frame = layout.frame

        func color(for note: Int) -> Color? {
            for index in active.indices where active[index].contains(note) {
                return DS.keyColors[index % DS.keyColors.count]
            }
            return nil
        }

        for note in whiteNotes {
            let rect = frame(note).insetBy(dx: 0.5, dy: 0)
            let fill = color(for: note) ?? Color(hex: 0xD8DCE6)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
            if note % 12 == 0 {
                context.draw(
                    Text("C\(note / 12 - 1)").font(.system(size: 8, weight: .medium)).foregroundColor(DS.onSelected.opacity(0.6)),
                    at: CGPoint(x: rect.midX, y: rect.maxY - 7)
                )
            }
        }
        for note in low...high where isBlack(note) {
            let rect = frame(note)
            let fill = color(for: note) ?? Color(hex: 0x1A1D26)
            context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(fill))
        }
    }
}

/// Octave shift of one layer, sized like a knob so it sits in the knob grid.
private struct OctaveControl: View {
    var octave: Int
    var enabled: Bool
    var onChange: (Int) -> Void

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 2) {
                IconButton(symbol: "minus", label: "Octave down", size: 22) { step(-1) }
                    .disabled(octave <= KeySlot.octaveRange.lowerBound)
                IconButton(symbol: "plus", label: "Octave up", size: 22) { step(1) }
                    .disabled(octave >= KeySlot.octaveRange.upperBound)
            }
            .frame(height: 40)
            Text("Octave")
                .font(.dsLabel)
                .foregroundStyle(enabled ? DS.textMuted : DS.textDisabled)
                .lineLimit(1)
            Text(octave == 0 ? "0" : String(format: "%+d", octave))
                .font(.dsValue)
                .foregroundStyle(octave == 0 ? DS.textDisabled : (enabled ? DS.textPrimary : DS.textMuted))
                .onTapGesture(count: 2) { onChange(0) }
        }
        .help("Octave shift of this layer; double-click the value to reset")
    }

    private func step(_ delta: Int) {
        onChange(min(KeySlot.octaveRange.upperBound, max(KeySlot.octaveRange.lowerBound, octave + delta)))
    }
}

/// Per-layer settings that rarely change during a set: pan, tune, bend and the MIDI input.
private struct LayerSettings: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var color: Color

    var body: some View {
        let slot = model.state.keySlots[index]
        VStack(alignment: .leading, spacing: DS.space3) {
            Text("LAYER \(index + 1)")
                .font(.dsSection)
                .foregroundStyle(DS.textMuted)
            HStack(spacing: DS.space3) {
                Knob(
                    label: "Pan", value: slot.pan, color: color, defaultValue: 0.5, size: 40,
                    lit: model.isLit(.knob(.keysPan), index), mapped: mapped(.keysPan), format: EffectKnobs.pan,
                    onChange: { value in model.setKeyEffects(index: index) { $0.pan = value } },
                    onCommit: { value in model.setKeyEffects(index: index) { $0.pan = value } },
                    onReset: { model.setKeyEffects(index: index) { $0.pan = nil } }
                )
                .learnChip(learn(.keysPan))
                Knob(
                    label: "Tune", value: slot.tune, color: color, defaultValue: 0.5, size: 40,
                    lit: model.isLit(.knob(.keysTune), index), mapped: mapped(.keysTune), format: EffectKnobs.cents,
                    onChange: { value in model.setKeyEffects(index: index) { $0.tune = value } },
                    onCommit: { value in model.setKeyEffects(index: index) { $0.tune = value } },
                    onReset: { model.setKeyEffects(index: index) { $0.tune = nil } }
                )
                .help("Fine tune, ±50 cents; double-click to reset")
                .learnChip(learn(.keysTune))
            }
            row("Bend") {
                SegmentButtons(options: [(0, "Off"), (1, "On")], selection: slot.bend ? 1 : 0) { value in
                    model.setKeyEffects(index: index) { $0.bend = value == 1 }
                }
                if let state = learn(.keysBendToggle) {
                    LearnChipFor(state: state)
                }
            }
            row("Input") {
                Picker("Input", selection: Binding(
                    get: { slot.inputID },
                    set: { id in model.setKeyEffects(index: index) { $0.inputID = id } }
                )) {
                    Text("Keyboards").tag(Int32?.none)
                    ForEach(model.midiSources) { source in
                        Text(source.name).tag(Int32?(source.id))
                    }
                    if let id = slot.inputID, !model.midiSources.contains(where: { $0.id == id }) {
                        Text("Disconnected input").tag(Int32?(id))
                    }
                }
                .labelsHidden()
                .help("Keyboards: the inputs marked Keyboard in Audio settings")
            }
            row("Channel") {
                Picker("Channel", selection: Binding(
                    get: { slot.channel },
                    set: { channel in model.setKeyEffects(index: index) { $0.channel = channel } }
                )) {
                    Text("All").tag(Int?.none)
                    ForEach(0..<16, id: \.self) { channel in
                        Text("\(channel + 1)").tag(Int?(channel))
                    }
                }
                .labelsHidden()
            }
        }
        .padding(DS.space3)
        .frame(width: 260)
    }

    private func mapped(_ target: BindingTarget) -> Bool {
        model.rig.binding(for: target, index: index) != nil
    }

    private func learn(_ target: BindingTarget) -> LearnState? {
        model.learnOn ? LearnState(model, target, index) : nil
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(spacing: DS.space2) {
            Text(title)
                .font(.dsLabel)
                .foregroundStyle(DS.textMuted)
                .frame(width: 56, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }
}

private struct KeyStrip: View {
    @Environment(AppModel.self) private var model
    var index: Int
    @State private var settingsOpen = false

    var body: some View {
        let slot = model.state.keySlots[index]
        let color = DS.keyColors[index % DS.keyColors.count]
        let loaded = slot.fileID != nil
        let live = model.liveMode
        VStack(spacing: DS.space2) {
            HStack {
                Text("\(index + 1)")
                    .font(.dsChannel)
                    .foregroundStyle(color)
                if let font = model.catalog.soundFont(slot.fileID) {
                    Text((font.subcategory.map { "\(font.category) · \($0)" } ?? font.category).uppercased())
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                        .lineLimit(1)
                }
                loadBadge
                Spacer()
                if loaded {
                    PowerButton(on: customized(slot), color: color, symbol: "slider.horizontal.3", label: "Layer settings: pan, tune, bend, MIDI input", size: 20) {
                        settingsOpen.toggle()
                    }
                    .popover(isPresented: $settingsOpen, arrowEdge: .bottom) {
                        LayerSettings(index: index, color: color)
                            .environment(model)
                    }
                    Button {
                        model.setKeyEffects(index: index) { $0.modCutoff.toggle() }
                    } label: {
                        pill("MOD", on: slot.modCutoff, color: color)
                    }
                    .buttonStyle(PressStyle())
                    .help(slot.modCutoff ? "Mod wheel controls Cutoff (on)" : "Mod wheel controls Cutoff (off)")
                    PowerButton(on: slot.enabled, color: color, label: slot.enabled ? "Disable layer" : "Enable layer", size: 28) {
                        model.setKeyEnabled(index: index, enabled: !slot.enabled)
                    }
                }
            }
            if live {
                Text(model.keyTitle(index))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(loaded ? DS.textPrimary : DS.textMuted)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            } else {
                SoundButton(index: index, slot: slot)
            }
            if loaded {
                controls(slot: slot, color: color, live: live)
            } else {
                Spacer(minLength: 0)
                if !live {
                    TextButton(title: "Import SF2…", symbol: "square.and.arrow.down") { model.importSoundFont(index: index) }
                }
            }
        }
        .padding(DS.space2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
        .opacity(loaded && !slot.enabled ? 0.7 : 1)
    }

    @ViewBuilder
    private var loadBadge: some View {
        switch model.keyLoadState(index) {
        case .loading:
            ProgressView().controlSize(.mini)
                .help("Loading into memory")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DS.red)
                .help("Could not load this sound")
        case .ready, .idle:
            EmptyView()
        }
    }

    private func customized(_ slot: KeySlot) -> Bool {
        slot.pan != nil || slot.tune != nil || !slot.bend || slot.inputID != nil || slot.channel != nil
    }

    private func mapped(_ target: BindingTarget) -> Bool {
        model.rig.binding(for: target, index: index) != nil
    }

    private func learn(_ target: BindingTarget) -> LearnState? {
        model.learnOn ? LearnState(model, target, index) : nil
    }

    /// An effect knob of this layer, with its MIDI mapping. `preview: false` applies only on release.
    private func knob(
        _ label: String, _ target: BindingTarget, _ value: Double?, color: Color, defaultValue: Double = 0,
        enabled: Bool, mapped extra: Bool = false, preview: Bool = true,
        format: @escaping (Double) -> String = { "\(Int(($0 * 100).rounded()))" },
        set: @escaping (inout KeySlot, Double?) -> Void
    ) -> some View {
        Knob(
            label: label, value: value, color: color, defaultValue: defaultValue, size: 40, enabled: enabled,
            lit: model.isLit(.knob(target), index), mapped: extra || mapped(target), format: format,
            onChange: { value in if preview { model.setKeyEffects(index: index) { set(&$0, value) } } },
            onCommit: { value in model.setKeyEffects(index: index) { set(&$0, value) } },
            onReset: { model.setKeyEffects(index: index) { set(&$0, nil) } }
        )
        .learnChip(learn(target))
    }

    private func pill(_ title: String, on: Bool, color: Color) -> some View {
        Text(title)
            .font(.dsMeta.weight(.semibold))
            .foregroundStyle(on ? DS.onSelected : DS.textMuted)
            .padding(.horizontal, 6)
            .frame(height: 20)
            .background(on ? color : DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
    }

    @ViewBuilder
    private func controls(slot: KeySlot, color: Color, live: Bool) -> some View {
        Grid(horizontalSpacing: 0, verticalSpacing: DS.space2) {
            GridRow {
                knob("Cutoff", .keysCutoff, slot.cutoff, color: color, defaultValue: 1, enabled: slot.enabled,
                     mapped: slot.modCutoff, format: EffectKnobs.hertz) { $0.cutoff = $1 }
                    .frame(maxWidth: .infinity)
                knob("Reso", .keysResonance, slot.resonance, color: color, enabled: slot.enabled) { $0.resonance = $1 }
                    .help("Filter resonance; works once Cutoff is lowered")
                    .frame(maxWidth: .infinity)
                knob("Low", .keysLow, slot.low, color: color, defaultValue: 0.5, enabled: slot.enabled,
                     format: EffectKnobs.decibels) { $0.low = $1 }
                    .frame(maxWidth: .infinity)
                knob("High", .keysHigh, slot.high, color: color, defaultValue: 0.5, enabled: slot.enabled,
                     format: EffectKnobs.decibels) { $0.high = $1 }
                    .frame(maxWidth: .infinity)
            }
            GridRow {
                knob("Comp", .keysCompressor, slot.compressor, color: color, enabled: slot.enabled, preview: false) { $0.compressor = $1 }
                    .frame(maxWidth: .infinity)
                knob("Reverb", .keysReverb, slot.reverb, color: color, enabled: slot.enabled, preview: false) { $0.reverb = $1 }
                    .frame(maxWidth: .infinity)
                knob("Space", .keysSpace, slot.space, color: color, enabled: slot.enabled && model.keys.spaceNode != nil) { $0.space = $1 }
                    .help(model.keys.spaceNode != nil ? "Valhalla Supermassive send" : "Valhalla Supermassive not found")
                    .frame(maxWidth: .infinity)
                OctaveControl(octave: slot.octave, enabled: slot.enabled) { value in
                    model.setKeyEffects(index: index) { $0.octave = value }
                }
                .learnChip(learn(.keysOctaveDown), prefix: "− ")
                .learnChip(learn(.keysOctaveUp), prefix: "+ ")
                .frame(maxWidth: .infinity)
            }
        }
        HStack(spacing: DS.space2) {
            Button {
                model.setKeyEffects(index: index) { $0.sustain.toggle() }
            } label: {
                pill("SUS", on: slot.sustain, color: color)
            }
            .buttonStyle(PressStyle())
            .help(slot.sustain ? "Sustain pedal holds this layer (on)" : "Sustain pedal holds this layer (off)")
            Menu {
                ForEach(VelocityCurve.allCases, id: \.self) { curve in
                    Button(curve.title) { model.setKeyEffects(index: index) { $0.velocity = curve } }
                }
            } label: {
                pill(slot.velocity == .normal ? "VEL" : "VEL \(slot.velocity.title.uppercased())", on: slot.velocity != .normal, color: color)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Velocity curve of this layer")
            Spacer(minLength: 0)
        }
        if model.keyIsOrgan(index) {
            HStack(spacing: DS.space2) {
                Text("Rotary")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
                SegmentButtons(options: [(0, "Off"), (1, "On")], selection: slot.rotary) { value in
                    model.setKeyEffects(index: index) { $0.rotary = value }
                }
                if let state = learn(.keysRotaryToggle) {
                    LearnChipFor(state: state)
                }
                Spacer(minLength: 0)
            }
        }
        HStack(alignment: .bottom, spacing: DS.space2) {
            VerticalFader(
                value: slot.volume,
                color: color,
                defaultValue: 0.8,
                lit: model.isLit(.keysLevel, index),
                desk: true,
                enabled: slot.enabled,
                mapped: model.rig.binding(for: .keysVolume, index: index) != nil,
                onChange: { model.previewKeyVolume(index: index, volume: $0) },
                onCommit: { model.setKeyVolume(index: index, volume: $0) }
            )
            MeterBar(channel: MeterStore.Channel.keys + index)
        }
        .frame(minHeight: 120, maxHeight: .infinity)
        Text("\(Int((slot.volume * 100).rounded()))")
            .font(.dsValue)
            .foregroundStyle(slot.enabled ? DS.textPrimary : DS.textMuted)
        if model.learnOn {
            LearnChipFor(state: LearnState(model, .keysVolume, index))
            LearnChipFor(state: LearnState(model, .keysToggle, index), prefix: "Enable ")
            LearnChipFor(state: LearnState(model, .keysModToggle, index), prefix: "MOD ")
        }
    }
}
