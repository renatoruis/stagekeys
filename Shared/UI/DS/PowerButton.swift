import SwiftUI

struct PowerButton: View {
    var on: Bool
    var color: Color
    var symbol: String = "power"
    var label: String
    var size: CGFloat = 28
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .frame(width: size, height: size)
                .foregroundStyle(on ? DS.onSelected : DS.textMuted)
                .background(on ? AnyShapeStyle(color) : AnyShapeStyle(DS.bgControl), in: RoundedRectangle(cornerRadius: DS.radiusSM))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .strokeBorder(on ? Color.clear : DS.borderDefault, lineWidth: 1)
                )
        }
        .buttonStyle(PressStyle())
        .help(label)
        .accessibilityLabel(label)
        .accessibilityValue(on ? "On" : "Off")
    }
}

struct IconButton: View {
    var symbol: String
    var label: String
    var size: CGFloat = 28
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .medium))
                .frame(width: size, height: size)
                .foregroundStyle(DS.textSecondary)
                .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderDefault, lineWidth: 1))
        }
        .buttonStyle(PressStyle())
        .help(label)
        .accessibilityLabel(label)
    }
}

struct TextButton: View {
    var title: String
    var symbol: String?
    var prominent = false
    /// Semantic accent. Prominent: fills the button. Otherwise: tints text and border.
    var tint: Color? = nil
    var fills = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
                .padding(.horizontal, 10)
                .frame(maxWidth: fills ? .infinity : nil)
                .frame(height: 28)
                .foregroundStyle(foreground)
                .background(background, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.radiusSM)
                        .strokeBorder(border, lineWidth: 1)
                )
        }
        .buttonStyle(PressStyle())
    }

    private var foreground: Color {
        if prominent { return DS.onSelected }
        return tint ?? DS.textSecondary
    }

    private var background: AnyShapeStyle {
        guard prominent else { return AnyShapeStyle(DS.bgControl) }
        return AnyShapeStyle(tint ?? DS.selected)
    }

    private var border: Color {
        if prominent { return .clear }
        return tint?.opacity(0.7) ?? DS.borderDefault
    }
}

struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .brightness(configuration.isPressed ? 0.08 : 0)
            .contentShape(Rectangle())
    }
}
