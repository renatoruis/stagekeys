import SwiftUI

struct TopBar: View {
    @Environment(AppModel.self) private var model
    @Binding var setlistOpen: Bool

    var body: some View {
        HStack(spacing: DS.space3) {
            songBlock
            Spacer(minLength: DS.space3)
            tempoBlock
            Spacer(minLength: DS.space3)
            StatusLine()
            MIDIIndicator()
            actionBlock
        }
        .padding(.leading, setlistOpen ? DS.space3 : DS.trafficLightInset)
        .padding(.trailing, DS.space3)
        .frame(height: 60)
        .background(WindowDragArea())
        .background(DS.bgApp)
    }

    // MARK: Song

    private var songBlock: some View {
        HStack(spacing: DS.space2) {
            TextButton(title: "Setlist", symbol: "line.3.horizontal", prominent: setlistOpen) {
                withAnimation(.easeOut(duration: 0.18)) { setlistOpen.toggle() }
            }
            .fixedSize()
            .help(setlistOpen ? "Hide setlist" : "Show setlist")
            IconButton(symbol: "chevron.left", label: "Previous song (←)", size: 28) { model.step(-1) }
                .disabled(model.sets.count < 2)
            VStack(alignment: .leading, spacing: 2) {
                songName
                HStack(spacing: 6) {
                    setName
                    Text("\(model.setIndex + 1) / \(model.sets.count)")
                        .font(.dsMeta.monospacedDigit())
                        .foregroundStyle(DS.textMuted)
                        .fixedSize()
                    Text("NEXT")
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                    Text(model.nextSetName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(minWidth: 180, maxWidth: 340, alignment: .leading)
            IconButton(symbol: "chevron.right", label: "Next song (→)", size: 28) { model.step(1) }
                .disabled(model.sets.count < 2)
        }
    }

    @ViewBuilder
    private var setName: some View {
        if model.liveMode {
            Text(model.rig.setName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: 110, alignment: .leading)
        } else {
            TextField("Set", text: Binding(get: { model.rig.setName }, set: { model.renameSetList($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(maxWidth: 110)
                .onSubmit { KeyCommands.releaseFocus() }
        }
    }

    @ViewBuilder
    private var songName: some View {
        if model.liveMode {
            Text(model.set.name)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Song", text: Binding(get: { model.set.name }, set: { model.rename($0) }))
                .textFieldStyle(.plain)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(DS.textPrimary)
                .onSubmit { KeyCommands.releaseFocus() }
        }
    }

    // MARK: Tempo / Key

    private var tempoBlock: some View {
        HStack(spacing: DS.space4) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(bpmText)
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .foregroundStyle(DS.textPrimary)
                Text("BPM")
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
            }
            Text(Self.signature(model.set.metronome.beatsPerBar))
                .font(.system(size: 14, weight: .medium).monospacedDigit())
                .foregroundStyle(DS.textSecondary)
            clickMark
            .help(model.metroRunning ? "Click on (Space to stop)" : "Click off (Space to start)")
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("KEY")
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
                Text(KeyButtons.label(for: model.set.padPitch))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DS.pads)
            }
        }
        .fixedSize()
    }

    // MARK: Actions

    private var actionBlock: some View {
        HStack(spacing: DS.space2) {
            TextButton(
                title: model.liveMode ? "Live" : "Edit",
                symbol: model.liveMode ? "circle.fill" : "slider.horizontal.3",
                prominent: model.liveMode,
                tint: model.liveMode ? DS.green : nil
            ) {
                model.setLiveMode(!model.liveMode)
            }
            .fixedSize()
            .help(model.liveMode ? "Live mode — structural edits locked. Click to edit." : "Edit mode. Click to go live.")
            if !model.liveMode {
                PowerButton(on: model.learnOn, color: DS.yellow, symbol: "dot.radiowaves.left.and.right", label: "MIDI Learn", action: model.toggleLearn)
            }
            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(DS.textSecondary)
                    .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderDefault, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .help("Audio and MIDI (⌘,)")
        }
    }

    private var clickMark: some View {
        let running = model.metroRunning
        let pulse = model.pulse
        let accent = running && pulse.accent
        let counting = running && pulse.counting
        let color: Color = {
            guard running else { return DS.bgControl }
            if counting { return DS.yellow }
            return DS.metronome
        }()
        return HStack(spacing: 5) {
            Circle()
                .fill(accent ? color : color.opacity(running ? 0.45 : 1))
                .overlay(Circle().strokeBorder(running ? Color.clear : DS.borderDefault, lineWidth: 1))
                .frame(width: accent ? 10 : 8, height: accent ? 10 : 8)
                .animation(.easeOut(duration: 0.08), value: pulse.beat)
            if running {
                Text("\(pulse.beat)")
                    .font(.system(size: 12, weight: accent ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(counting ? DS.yellow : (accent ? DS.metronome : DS.textSecondary))
                    .frame(width: 16, alignment: .leading)
                    .contentTransition(.numericText())
            }
            Text(counting ? "COUNT" : "CLICK")
                .font(.dsMeta)
                .foregroundStyle(running ? (counting ? DS.yellow : DS.metronome) : DS.textMuted)
        }
    }

    private var bpmText: String {
        let bpm = model.set.metronome.bpm
        return bpm == bpm.rounded() ? String(format: "%.0f", bpm) : String(format: "%.1f", bpm)
    }

    static func signature(_ beats: Int) -> String {
        switch beats {
        case 4: "4/4"
        case 3: "3/4"
        case 6: "6/8"
        default: "\(beats)/4"
        }
    }
}

/// Last MIDI message received; flashes on every new one.
struct MIDIIndicator: View {
    @Environment(AppModel.self) private var model
    @State private var flash = false

    var body: some View {
        let monitor = model.monitor
        HStack(spacing: 6) {
            Circle()
                .fill(flash ? DS.green : DS.bgControl)
                .frame(width: 7, height: 7)
            Text(monitor.label.isEmpty ? "MIDI" : monitor.label)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(monitor.label.isEmpty ? DS.textMuted : DS.textSecondary)
                .lineLimit(1)
        }
        .frame(minWidth: 120, alignment: .leading)
        .help(monitor.source.isEmpty ? "Last MIDI message" : "Last MIDI message from \(monitor.source)")
        .onChange(of: monitor.stamp) { _, _ in
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { flash = false }
        }
    }
}

struct StatusLine: View {
    @Environment(AppModel.self) private var model
    @State private var shown = ""
    @State private var dismiss: DispatchWorkItem?

    var body: some View {
        let persistent = isPersistent(model.status)
        let text = persistent ? model.status : shown
        HStack(spacing: 6) {
            if model.armed != nil {
                Circle().fill(DS.yellow).frame(width: 6, height: 6)
            } else if isError(text) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.red)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint(text))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 360, alignment: .trailing)
        .opacity(text.isEmpty ? 0 : 1)
        .animation(.easeOut(duration: 0.15), value: text.isEmpty)
        .onChange(of: model.statusVersion) { _, _ in schedule(model.status) }
        .accessibilityLabel(text)
    }

    private func schedule(_ status: String) {
        dismiss?.cancel()
        shown = status
        guard !status.isEmpty, !isPersistent(status) else { return }
        let work = DispatchWorkItem { shown = "" }
        dismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func isPersistent(_ text: String) -> Bool {
        model.armed != nil || isError(text) || text.hasPrefix("Loading")
    }

    private func isError(_ text: String) -> Bool {
        text.hasPrefix("Could not") || text.hasPrefix("No output")
    }

    private func tint(_ text: String) -> Color {
        if model.armed != nil { return DS.yellow }
        if isError(text) { return DS.red }
        return DS.textSecondary
    }
}
