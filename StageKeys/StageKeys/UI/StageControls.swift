import SwiftUI

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

extension View {
    /// The MIDI Learn chip under a shared control (Knob), which has no Learn of its own.
    func learnChip(_ state: LearnState?, prefix: String = "") -> some View {
        VStack(spacing: 3) {
            self
            if let state {
                LearnChipFor(state: state, prefix: prefix)
            }
        }
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

enum EffectKnobs {
    static func hertz(_ value: Double) -> String {
        if value >= 0.98 { return "Open" }
        let hz = 200.0 * pow(90.0, value)
        return hz >= 1000 ? String(format: "%.1fk", hz / 1000) : "\(Int(hz))"
    }

    static func pan(_ value: Double) -> String {
        let amount = Int(((value - 0.5) * 200).rounded())
        return amount == 0 ? "C" : (amount < 0 ? "L\(-amount)" : "R\(amount)")
    }

    static func cents(_ value: Double) -> String {
        let cents = Int(((value - 0.5) * 100).rounded())
        return cents == 0 ? "0 ct" : String(format: "%+d ct", cents)
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
