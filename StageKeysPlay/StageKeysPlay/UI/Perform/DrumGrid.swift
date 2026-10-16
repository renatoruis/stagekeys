import SwiftUI

struct DrumGrid: View {
    @Environment(AppModel.self) private var model
    @State private var picking: Int?

    var body: some View {
        let layout = model.set.drumLayout
        let columns = layout == 4 ? 2 : (layout == 6 ? 3 : 4)
        Panel(title: "Drums", color: DS.green) {
            HStack(spacing: DS.space2) {
                if !model.liveMode {
                    SegmentButtons(options: [(4, "4"), (6, "6"), (8, "8")], selection: layout) { model.setDrumLayout($0) }
                }
                MeterBar(channel: MeterStore.Channel.drums)
                    .frame(height: 22)
            }
        } content: {
            VStack(spacing: DS.space3) {
                GeometryReader { geo in
                    let rows = max(layout / columns, 1)
                    let rowHeight = max(80, (geo.size.height - CGFloat(rows - 1) * 8) / CGFloat(rows))
                    let grid = Array(repeating: GridItem(.flexible(), spacing: 8), count: columns)
                    LazyVGrid(columns: grid, spacing: 8) {
                        ForEach(0..<layout, id: \.self) { index in
                            DrumPadCell(
                                index: index,
                                title: model.drumTitle(index),
                                color: model.set.drumPads[index].color,
                                loaded: model.set.drumPads[index].assetID != nil,
                                selected: model.selectedDrum == index,
                                lit: model.isLit(.drum, index),
                                live: model.liveMode,
                                learn: model.learnOn ? LearnState(model, .drumNote, index) : nil,
                                onEdit: {
                                    guard !model.liveMode else { return }
                                    model.selectedDrum = index
                                    picking = index
                                }
                            )
                            .equatable()
                            .frame(height: rowHeight)
                        }
                    }
                }
                if !model.liveMode {
                    DrumEditor(index: model.selectedDrum) { picking = model.selectedDrum }
                }
            }
        }
        .sheet(isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } })) {
            if let picking {
                DrumPicker(index: picking) { self.picking = nil }
                    .environment(model)
            }
        }
    }
}

/// Sample, level, reverb and color of the selected pad.
private struct DrumEditor: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var choose: () -> Void

    var body: some View {
        let pad = model.set.drumPads[index]
        let color = DS.drumColor(pad.color)
        let category = model.catalog.drumSamples.first { $0.id == pad.assetID }?.category ?? ""
        HStack(spacing: DS.space3) {
            Text("PAD \(index + 1)")
                .font(.dsSection)
                .foregroundStyle(DS.textMuted)
                .fixedSize()
            LibraryButton(
                title: pad.assetID == nil ? "Empty" : model.drumTitle(index),
                symbol: LibrarySymbols.drum(category),
                color: color,
                empty: pad.assetID == nil,
                help: "Choose a sample for pad \(index + 1)",
                action: choose
            )
            .frame(maxWidth: 240)
            Knob(
                label: "Gain",
                value: pad.gain,
                color: color,
                defaultValue: 0.9,
                size: 40,
                onChange: { model.previewDrumGain(index: index, gain: $0) },
                onCommit: { model.setDrumGain(index: index, gain: $0) }
            )
            Knob(
                label: "Reverb",
                value: pad.reverb,
                color: color,
                size: 40,
                onChange: { model.previewDrumReverb(index: index, amount: $0) },
                onCommit: { model.setDrumReverb(index: index, amount: $0) },
                onReset: { model.setDrumReverb(index: index, amount: nil) }
            )
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                ForEach(DrumColor.allCases) { swatch in
                    Button {
                        model.setDrumColor(index: index, color: swatch.rawValue)
                    } label: {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(DS.drumColor(swatch.rawValue))
                            .frame(width: 18, height: 18)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(pad.color == swatch.rawValue ? DS.textPrimary : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(PressStyle())
                    .help(swatch.title)
                    .accessibilityLabel(swatch.title)
                }
            }
        }
        .padding(DS.space2)
        .background(DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
    }
}

private struct DrumPicker: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var close: () -> Void

    var body: some View {
        LibraryPicker(
            meta: "Drum pad \(index + 1)",
            title: model.set.drumPads[index].assetID == nil ? "Empty" : model.drumTitle(index),
            color: DS.drumColor(model.set.drumPads[index].color),
            noun: "samples",
            items: model.catalog.drumSamples.map {
                LibraryItem(id: $0.id, name: $0.name, detail: ResourceCatalog.categoryTitle($0.category), section: $0.category)
            },
            sections: model.catalog.drumCategories,
            selection: model.set.drumPads[index].assetID,
            importTitle: "Import sample…",
            sectionTitle: ResourceCatalog.categoryTitle,
            symbol: LibrarySymbols.drum,
            onChoose: { model.setDrumSample(index: index, id: $0) },
            onImport: { model.importDrum(index: index) },
            close: close
        )
    }
}

struct DrumPadCell: View, Equatable {
    @Environment(AppModel.self) private var model
    var index: Int
    var title: String
    var color: String
    var loaded: Bool
    var selected: Bool
    var lit: Bool
    var live: Bool
    var learn: LearnState?
    var onEdit: () -> Void

    static func == (lhs: DrumPadCell, rhs: DrumPadCell) -> Bool {
        lhs.index == rhs.index && lhs.title == rhs.title && lhs.color == rhs.color && lhs.loaded == rhs.loaded
            && lhs.selected == rhs.selected && lhs.lit == rhs.lit && lhs.live == rhs.live && lhs.learn == rhs.learn
    }

    var body: some View {
        Group {
            if loaded {
                padFace
            } else {
                Button(action: onEdit) {
                    Text(live ? "Empty" : "+ Add Drum")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(live ? DS.textMuted : DS.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderDefault, lineWidth: 1))
                }
                .buttonStyle(PressStyle())
                .disabled(live)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Dark ink on bright fills, light ink on the neutral stone pad.
    private var ink: Color {
        DrumColor(rawValue: color) == .stone ? DS.textPrimary : DS.onSelected
    }

    private var padFace: some View {
        let fill = DS.drumColor(color)
        return Button {
            if let learn {
                model.selectedDrum = index
                model.arm(learn.target, index: index)
            } else {
                model.chooseDrum(index)
            }
        } label: {
            VStack(spacing: 2) {
                Spacer(minLength: 0)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(ink)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                if let learn {
                    Text(learn.label)
                        .font(.dsMeta)
                        .padding(.horizontal, 4)
                        .background(learn.armed ? DS.yellow : Color.black.opacity(0.25), in: Capsule())
                        .foregroundStyle(learn.armed ? DS.onSelected : DS.textPrimary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(colors: [fill, fill.opacity(0.78)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: DS.radiusSM)
            )
            .overlay(alignment: .topLeading) {
                Text("\(index + 1)")
                    .font(.dsValue)
                    .foregroundStyle(ink.opacity(0.7))
                    .padding(8)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .fill(Color.white.opacity(lit ? 0.35 : 0))
                    .allowsHitTesting(false)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .strokeBorder(lit || selected ? DS.textPrimary : Color.white.opacity(0.08), lineWidth: lit || selected ? 2 : 1)
            )
            .animation(lit ? nil : .easeOut(duration: 0.12), value: lit)
        }
        .buttonStyle(PressStyle())
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contextMenu {
            if !model.liveMode {
                Button("Edit pad \(index + 1)", action: onEdit)
            }
        }
        .accessibilityLabel("Pad \(index + 1), \(title)")
    }
}
