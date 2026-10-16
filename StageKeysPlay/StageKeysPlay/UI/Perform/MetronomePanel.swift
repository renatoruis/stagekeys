import SwiftUI

/// Click: start/stop, beat pulse, tempo and tap; in Edit, its settings below.
struct MetronomeCard: View {
    @Environment(AppModel.self) private var model
    @State private var bpmDraft = ""
    @FocusState private var bpmFocused: Bool
    @State private var picking = false

    var body: some View {
        let settings = model.set.metronome
        let running = model.metroRunning
        Panel(title: "Click", color: DS.metronome) {
            HStack(spacing: DS.space2) {
                if model.learnOn {
                    LearnChipFor(state: LearnState(model, .metroToggle, 0), prefix: "Click ")
                    LearnChipFor(state: LearnState(model, .countIn, 0), prefix: "Count ")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: DS.space3) {
                HStack(spacing: DS.space2) {
                    PowerButton(
                        on: running,
                        color: DS.metronome,
                        symbol: running ? "stop.fill" : "play.fill",
                        label: running ? "Stop click (Space)" : "Start click (Space)",
                        size: 56
                    ) {
                        model.toggleMetronome()
                    }
                    BeatDots(beats: settings.beatsPerBar)
                    Spacer(minLength: 0)
                    MetroButton(title: "−") { model.setBPM(settings.bpm - 0.5) }
                    VStack(spacing: 0) {
                        bpmField(settings.bpm)
                        Text("BPM · \(TopBar.signature(settings.beatsPerBar))")
                            .font(.dsMeta)
                            .foregroundStyle(DS.textMuted)
                    }
                    .frame(width: 96)
                    MetroButton(title: "+") { model.setBPM(settings.bpm + 0.5) }
                    MetroButton(title: "Count", prominent: model.pulse.counting, action: model.countIn)
                        .help(running ? "Count in from the next bar" : "Start the click with a count-in")
                    MetroButton(title: "Tap", prominent: true, action: model.tapTempo)
                        .help("Tap tempo")
                }
                if !model.liveMode {
                    Rectangle().fill(DS.borderSoft).frame(height: 1)
                    settingsRows(settings)
                }
            }
        }
        .sheet(isPresented: $picking) {
            ClickPicker { picking = false }
                .environment(model)
        }
    }

    @ViewBuilder
    private func bpmField(_ bpm: Double) -> some View {
        if model.liveMode {
            Text(Self.formatted(bpm))
                .font(.system(size: 34, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
        } else {
            TextField("BPM", text: $bpmDraft)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.center)
                .font(.system(size: 34, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.textPrimary)
                .focused($bpmFocused)
                .onSubmit(commitBPM)
                .onAppear { bpmDraft = Self.formatted(bpm) }
                .onChange(of: bpm) { _, next in
                    if !bpmFocused { bpmDraft = Self.formatted(next) }
                }
                .onChange(of: bpmFocused) { _, focused in
                    if !focused { commitBPM() }
                }
                .help("Type a tempo in whole or .5 steps, then Enter")
        }
    }

    private func settingsRows(_ settings: MetronomeSettings) -> some View {
        VStack(alignment: .leading, spacing: DS.space3) {
            HStack(alignment: .bottom, spacing: DS.space3) {
                SettingField(title: "Sound") {
                    LibraryButton(
                        title: model.catalog.clickStyles.first { $0.id == settings.styleID }?.name ?? settings.styleID,
                        symbol: "metronome",
                        color: DS.metronome,
                        empty: false,
                        help: "Choose the click sound"
                    ) { picking = true }
                    .frame(width: 150)
                }
                SettingField(title: "Time") {
                    SegmentButtons(options: [(4, "4/4"), (6, "6/8")], selection: settings.beatsPerBar) {
                        model.setBeatsPerBar($0)
                    }
                }
                SettingField(title: "Subdivision") {
                    SegmentButtons(options: [(1, "♩"), (2, "♪♪"), (3, "3"), (4, "♬")], selection: settings.subdivision) {
                        model.setSubdivision($0)
                    }
                }
                Spacer(minLength: 0)
                Knob(
                    label: "Vol",
                    value: settings.volume,
                    color: DS.metronome,
                    defaultValue: 0.8,
                    size: 40,
                    onChange: { model.previewMetronomeVolume($0) },
                    onCommit: { model.setMetronomeVolume($0) }
                )
                MeterBar(channel: MeterStore.Channel.metronome)
                    .frame(height: 64)
            }
            HStack(alignment: .bottom, spacing: DS.space3) {
                SettingField(title: "Count-in") {
                    SegmentButtons(options: [(0, "Off"), (1, "1 bar"), (2, "2 bars")], selection: settings.countInBars) {
                        model.setCountIn($0)
                    }
                }
                SettingField(title: "Voice") {
                    SegmentButtons(
                        options: [(0, "Off"), (1, settings.beatsPerBar == 6 ? "1 2 3" : "1 2 3 4"), (2, "1 · 2 · 3 · 4")],
                        selection: settings.countVoice ? (settings.countSpaced ? 2 : 1) : 0
                    ) { value in
                        model.setCountVoice(value != 0, spaced: value == 2)
                    }
                    .disabled(settings.countInBars == 0)
                    .opacity(settings.countInBars == 0 ? 0.5 : 1)
                    .help("Spoken count-in: every beat, or spaced (one count every other beat, over at least two bars)")
                }
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: DS.space3) {
                SettingField(title: "Accent") {
                    SegmentButtons(options: [(true, "On 1"), (false, "Off")], selection: settings.accentEnabled) {
                        model.setAccentEnabled($0)
                    }
                }
                SettingField(title: "MIDI clock") {
                    SegmentButtons(options: ClockMode.allCases.map { ($0, $0.title) }, selection: settings.clockMode) {
                        model.setClockMode($0)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func commitBPM() {
        if !model.acceptBPM(bpmDraft) {
            bpmDraft = Self.formatted(model.set.metronome.bpm)
        }
        KeyCommands.releaseFocus()
    }

    static func formatted(_ bpm: Double) -> String {
        bpm == bpm.rounded() ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
    }
}

private struct ClickPicker: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void

    var body: some View {
        let settings = model.set.metronome
        LibraryPicker(
            meta: "Click",
            title: model.catalog.clickStyles.first { $0.id == settings.styleID }?.name ?? settings.styleID,
            color: DS.metronome,
            noun: "sounds",
            items: model.catalog.clickStyles.map { LibraryItem(id: $0.id, name: $0.name, detail: "Click sound", section: "Click") },
            sections: ["Click"],
            selection: settings.styleID,
            importTitle: nil,
            allowsNone: false,
            symbol: { _ in "metronome" },
            onChoose: { if let id = $0 { model.setClickStyle(id) } },
            close: close
        )
    }
}

private struct BeatDots: View {
    @Environment(AppModel.self) private var model
    var beats: Int

    var body: some View {
        let pulse = model.pulse
        let running = model.metroRunning
        HStack(spacing: 5) {
            ForEach(1...max(1, beats), id: \.self) { beat in
                let current = running && pulse.beat == beat
                let color = pulse.counting ? DS.yellow : DS.metronome
                Circle()
                    .fill(current ? color : DS.bgControl)
                    .frame(width: beat == 1 ? 14 : 10, height: beat == 1 ? 14 : 10)
            }
        }
        .animation(.easeOut(duration: 0.06), value: pulse.beat)
    }
}

struct SettingField<Content: View>: View {
    var title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space1) {
            Text(title)
                .font(.dsLabel)
                .foregroundStyle(DS.textMuted)
            content()
        }
    }
}

struct MetroButton: View {
    var title: String
    var prominent = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(prominent ? DS.onSelected : DS.textSecondary)
                .frame(minWidth: 52, minHeight: 48)
                .padding(.horizontal, 6)
                .background(prominent ? AnyShapeStyle(DS.metronome) : AnyShapeStyle(DS.bgControl), in: RoundedRectangle(cornerRadius: DS.radiusMD))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusMD)
                        .strokeBorder(prominent ? Color.clear : DS.borderDefault, lineWidth: 1)
                )
        }
        .buttonStyle(PressStyle())
    }
}
