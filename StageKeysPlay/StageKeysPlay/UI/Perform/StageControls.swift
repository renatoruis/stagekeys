import AudioToolbox.AUCocoaUIView
import AVFoundation
import SwiftUI

/// Opens the Supermassive's own editor; its settings are saved when the sheet closes.
struct SpaceEditorButton: View {
    @Environment(AppModel.self) private var model
    var node: AVAudioUnit?
    var title: String
    @State private var open = false

    var body: some View {
        if let node {
            TextButton(title: "Space", symbol: "slider.horizontal.3") { open = true }
                .fixedSize()
                .help("Edit the Valhalla Supermassive behind the \(title) Space knobs")
                .sheet(isPresented: $open, onDismiss: model.saveSpaceSettings) {
                    PluginEditor(node: node, title: "\(title) · Valhalla Supermassive") { open = false }
                }
        }
    }
}

private struct PluginEditor: View {
    let node: AVAudioUnit
    let title: String
    let done: () -> Void
    @State private var view: NSView?

    var body: some View {
        VStack(spacing: DS.space2) {
            HStack {
                Text(title)
                    .font(.dsLabel)
                    .foregroundStyle(DS.textSecondary)
                Spacer()
                TextButton(title: "Done", symbol: "checkmark", prominent: true, action: done)
                    .fixedSize()
            }
            if let view {
                HostedView(view: view)
                    .frame(width: view.frame.width, height: view.frame.height)
            } else {
                Text("This plugin has no editor")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
                    .frame(width: 420, height: 120)
            }
        }
        .padding(DS.space3)
        .onAppear { view = Self.cocoaView(node.audioUnit) }
    }

    /// A fresh AUv2 Cocoa editor on every open: `requestViewController` only answers the first time.
    private static func cocoaView(_ unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, nil) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        var info = AudioUnitCocoaViewInfo(
            mCocoaAUViewBundleLocation: Unmanaged.passUnretained(URL(fileURLWithPath: "/") as CFURL),
            mCocoaAUViewClass: Unmanaged.passUnretained("" as CFString)
        )
        size = UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size)
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &info, &size) == noErr else { return nil }
        let location = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let name = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let factory = Bundle(url: location)?.classNamed(name) as? NSObject.Type,
              let base = factory.init() as? AUCocoaUIBase else { return nil }
        return base.uiView(forAudioUnit: unit, with: .zero)
    }
}

private struct HostedView: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

struct LearnState: Equatable {
    var target: BindingTarget
    var index: Int
    var label: String
    var armed: Bool
    var bound: Bool

    init(_ model: AppModel, _ target: BindingTarget, _ index: Int) {
        self.target = target
        self.index = index
        label = model.bindingLabel(target: target, index: index)
        armed = model.isArmed(target, index: index)
        bound = model.rig.binding(for: target, index: index) != nil
    }
}

struct LearnChipFor: View {
    @Environment(AppModel.self) private var model
    var state: LearnState
    var prefix = ""

    var body: some View {
        LearnChip(
            label: prefix + state.label,
            armed: state.armed,
            action: { model.arm(state.target, index: state.index) },
            clear: state.bound ? { model.clearBinding(target: state.target, index: state.index) } : nil
        )
    }
}

extension View {
    /// The MIDI Learn chip under a shared control (Knob), which has no Learn of its own.
    func learnChip(_ state: LearnState?, width: CGFloat) -> some View {
        VStack(spacing: 3) {
            self
            if let state {
                LearnChipFor(state: state)
            }
        }
        .frame(width: width)
    }
}

struct KnobMIDI: Equatable {
    var lit: Bool
    var mapped: Bool
    var learn: LearnState?

    init(_ model: AppModel, _ target: BindingTarget, _ index: Int, _ kind: StageActivity.Kind) {
        lit = model.isLit(kind, index)
        mapped = model.rig.binding(for: target, index: index) != nil
        learn = model.learnOn ? LearnState(model, target, index) : nil
    }
}

enum EffectKnobs {
    static func hertz(_ value: Double) -> String {
        if value >= 0.98 { return "Open" }
        let hz = 200.0 * pow(90.0, value)
        return hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz))"
    }

    /// Shelving gain, 0.5 is flat (±12 dB).
    static func decibels(_ value: Double) -> String {
        let db = Int(((value - 0.5) * 24).rounded())
        return db == 0 ? "0 dB" : String(format: "%+d dB", db)
    }
}

struct MeterBar: View {
    @Environment(\.meteringActive) private var active
    var channel: Int

    var body: some View {
        LevelMeter(channel: channel, active: active)
            .padding(.vertical, 14)
    }
}
