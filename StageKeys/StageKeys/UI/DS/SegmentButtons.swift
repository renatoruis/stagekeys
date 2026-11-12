import SwiftUI

struct SegmentButtons<Value: Hashable>: View {
    var options: [(value: Value, label: String)]
    var selection: Value
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isOn = option.value == selection
                Button {
                    onSelect(option.value)
                } label: {
                    Text(option.label)
                        .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                        .frame(minWidth: 28)
                        .padding(.horizontal, 6)
                        .frame(height: 22)
                        .foregroundStyle(isOn ? DS.onSelected : DS.textSecondary)
                        .background(isOn ? AnyShapeStyle(DS.selected) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: DS.radiusXS))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(2)
        .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(Color(hex: 0x343B4E), lineWidth: 1))
    }
}

struct LearnChip: View {
    var label: String
    var armed: Bool
    var action: () -> Void
    var clear: (() -> Void)?

    var body: some View {
        HStack(spacing: 3) {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .foregroundStyle(armed ? DS.onSelected : DS.textSecondary)
                    .background(armed ? AnyShapeStyle(DS.yellow) : AnyShapeStyle(DS.bgControl), in: RoundedRectangle(cornerRadius: DS.radiusXS))
                    .overlay(RoundedRectangle(cornerRadius: DS.radiusXS).strokeBorder(armed ? Color.clear : DS.borderDefault, lineWidth: 1))
            }
            .buttonStyle(PressStyle())
            .help(armed ? "Waiting for a controller — move a knob or press a button" : "Click, then move a MIDI control to map it")
            if let clear {
                Button(action: clear) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(DS.textMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .help("Clear mapping")
            }
        }
    }
}
