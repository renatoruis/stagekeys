import SwiftUI

struct AudioView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Devices")
                        .font(.dsSection)
                        .foregroundStyle(DS.textSecondary)
                    Spacer()
                    if model.liveMode {
                        Text("Routing is locked in Live")
                            .font(.dsLabel)
                            .foregroundStyle(DS.textMuted)
                    }
                    Button("Refresh") { model.router.refreshDevices() }
                    Button(model.learnOn ? "MIDI Learn on" : "MIDI Learn") {
                        model.toggleLearn()
                    }
                    .disabled(model.liveMode)
                }
                ForEach(Motor.allCases) { motor in
                    motorRow(motor)
                }
                Divider()
                Text("Buffer")
                    .font(.dsSection)
                    .foregroundStyle(DS.textSecondary)
                Picker("Buffer", selection: bufferBinding) {
                    Text("64").tag(64)
                    Text("128").tag(128)
                    Text("256").tag(256)
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .disabled(model.liveMode)
                Divider()
                Text("MIDI inputs")
                    .font(.dsSection)
                    .foregroundStyle(DS.textSecondary)
                if model.midiSources.isEmpty {
                    Text("No inputs found.")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.midiSources) { source in
                    HStack(spacing: 16) {
                        Toggle(source.name, isOn: Binding(
                            get: { model.rig.enabledMIDISources.contains(source.id) },
                            set: { _ in model.toggleMIDISource(source.id) }
                        ))
                        .frame(width: 320, alignment: .leading)
                        Toggle("Plays Keys", isOn: Binding(
                            get: { model.rig.keyboardSourceIDs.contains(source.id) },
                            set: { _ in model.toggleKeyboardSource(source.id) }
                        ))
                        .disabled(!model.rig.enabledMIDISources.contains(source.id))
                    }
                    .disabled(model.liveMode)
                }
                Text(model.rig.keyboardSourceIDs.isEmpty
                     ? "No keyboard chosen: every input plays Keys."
                     : "Keyboards play Keys. The other inputs only control the app.")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
                Divider()
                Text("MIDI mappings")
                    .font(.dsSection)
                    .foregroundStyle(DS.textSecondary)
                if model.rig.bindings.isEmpty {
                    Text("Nothing mapped. Turn on MIDI Learn, then click a control and move the hardware (or the other way round).")
                        .font(.dsLabel)
                        .foregroundStyle(DS.textMuted)
                }
                ForEach(sortedBindings) { binding in
                    HStack(spacing: 12) {
                        Text(binding.target.title(index: binding.index))
                            .frame(width: 200, alignment: .leading)
                        Text(binding.match.label)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.textSecondary)
                        Spacer()
                        Button("Clear") { model.clearBinding(target: binding.target, index: binding.index) }
                            .disabled(model.liveMode)
                    }
                }
                Divider()
                Text("Keyboard shortcuts")
                    .font(.dsSection)
                    .foregroundStyle(DS.textSecondary)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    ForEach(Self.shortcuts, id: \.keys) { item in
                        GridRow {
                            Text(item.keys)
                                .font(.system(size: 12, weight: .medium).monospaced())
                                .foregroundStyle(DS.textPrimary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusXS))
                            Text(item.action)
                                .font(.system(size: 12))
                                .foregroundStyle(DS.textSecondary)
                        }
                    }
                }
                Text("Knobs and faders: scroll or drag to adjust, ↑/↓ to step (⇧ for fine), double-click to reset.")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let shortcuts: [(keys: String, action: String)] = [
        ("⌘,", "Audio and MIDI settings"),
    ]

    private func motorRow(_ motor: Motor) -> some View {
        let route = model.rig.route(for: motor)
        let device = model.router.device(uid: route.deviceUID)
        let options = model.router.channelOptions(for: device)
        return HStack(spacing: 12) {
            Text(motor.title)
                .frame(width: 100, alignment: .leading)
            Picker("Device", selection: deviceBinding(motor)) {
                ForEach(model.devices) { item in
                    Text(item.name).tag(Optional(item.uid))
                }
            }
            .labelsHidden()
            .frame(width: 280)
            .disabled(model.liveMode)
            Picker("Channel", selection: pickBinding(motor, options: options)) {
                ForEach(options) { option in
                    Text(option.title).tag(option.pick)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            .disabled(model.liveMode)
            Spacer()
        }
    }

    private var sortedBindings: [MIDIBinding] {
        let order = BindingTarget.allCases
        return model.rig.bindings.sorted {
            let lhs = order.firstIndex(of: $0.target) ?? 0
            let rhs = order.firstIndex(of: $1.target) ?? 0
            return lhs == rhs ? $0.index < $1.index : lhs < rhs
        }
    }

    private var bufferBinding: Binding<Int> {
        Binding(get: { model.rig.bufferFrames }, set: { model.setBuffer($0) })
    }

    private func deviceBinding(_ motor: Motor) -> Binding<String?> {
        Binding(
            get: { model.rig.route(for: motor).deviceUID ?? model.router.device(uid: nil)?.uid },
            set: { uid in
                if let uid { model.setDevice(motor: motor, uid: uid) }
            }
        )
    }

    private func pickBinding(_ motor: Motor, options: [ChannelOption]) -> Binding<ChannelPick> {
        Binding(
            get: {
                let pick = model.rig.route(for: motor).pick
                return options.contains(where: { $0.pick == pick }) ? pick : (options.first?.pick ?? .stereo)
            },
            set: { model.setPick(motor: motor, pick: $0) }
        )
    }
}
