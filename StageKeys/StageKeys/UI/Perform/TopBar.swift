import SwiftUI

struct TopBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: DS.space3) {
            Spacer(minLength: DS.space3)
            StatusLine()
            MIDIIndicator()
            actionBlock
        }
        .padding(.leading, DS.trafficLightInset)
        .padding(.trailing, DS.space3)
        .frame(height: 60)
        .background(WindowDragArea())
        .background(DS.bgApp)
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
