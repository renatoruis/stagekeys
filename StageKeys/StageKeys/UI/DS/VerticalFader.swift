import SwiftUI

struct VerticalFader: View {
    var value: Double
    var color: Color
    var defaultValue: Double = 0.8
    var label: String = "Volume"
    var lit = false
    var desk = false
    /// False when the owning slot is muted/disabled: the fader stays operable but reads as inactive.
    var enabled = true
    /// A hardware control is bound to this fader.
    var mapped = false
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void

    @State private var dragValue: Double?

    private var thumbHeight: CGFloat { desk ? 46 : 28 }
    private var thumbWidth: CGFloat { desk ? 52 : 34 }
    private var trackWidth: CGFloat { desk ? 10 : 6 }
    private var accent: Color { enabled ? color : color.opacity(0.35) }

    var body: some View {
        GeometryReader { geo in
            let shown = dragValue ?? value
            let travel = max(geo.size.height - thumbHeight, 1)
            let thumbY = (1 - min(1, max(0, shown))) * travel + thumbHeight / 2
            ZStack(alignment: .top) {
                FaderTrack(value: shown, color: accent, inset: thumbHeight / 2)
                    .frame(width: trackWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                FaderThumb(color: accent, active: dragValue != nil || lit)
                    .frame(width: thumbWidth, height: thumbHeight)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(lit ? color : Color.clear, lineWidth: 2))
                    .position(x: geo.size.width / 2, y: thumbY)
                if mapped {
                    Circle()
                        .fill(enabled ? color : DS.textMuted)
                        .frame(width: 5, height: 5)
                        .position(x: geo.size.width / 2, y: 4)
                        .help("MIDI mapped")
                        .allowsHitTesting(false)
                }
                if dragValue != nil {
                    Text("\(Int((shown * 100).rounded()))")
                        .font(.dsValue)
                        .foregroundStyle(DS.textPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Color(hex: 0x0D1018), in: RoundedRectangle(cornerRadius: DS.radiusXS))
                        .overlay(RoundedRectangle(cornerRadius: DS.radiusXS).strokeBorder(Color(hex: 0x303749)))
                        .position(x: geo.size.width / 2, y: max(10, thumbY - thumbHeight / 2 - 12))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { gesture in
                        let next = 1 - min(1, max(0, (gesture.location.y - thumbHeight / 2) / travel))
                        dragValue = next
                        onChange(next)
                    }
                    .onEnded { _ in
                        if let dragValue { onCommit(dragValue) }
                        dragValue = nil
                    }
            )
        }
        .frame(width: thumbWidth + 4)
        .continuousControl(value: value, defaultValue: defaultValue, onCommit: onCommit)
        .accessibilityLabel(label)
    }
}

private struct FaderTrack: View, Equatable {
    var value: Double
    var color: Color
    var inset: CGFloat

    var body: some View {
        Canvas { context, size in
            let track = CGRect(x: 0, y: inset, width: size.width, height: max(0, size.height - inset * 2))
            let shape = Path(roundedRect: track, cornerRadius: size.width / 2)
            context.fill(shape, with: .color(Color(hex: 0x202532)))
            context.stroke(shape, with: .color(Color(hex: 0x3A4153)), lineWidth: 1)
            let height = track.height * min(1, max(0, value))
            let fill = CGRect(x: 0, y: track.maxY - height, width: size.width, height: height)
            context.fill(Path(roundedRect: fill, cornerRadius: size.width / 2), with: .color(color))
        }
    }
}

private struct FaderThumb: View, Equatable {
    var color: Color
    var active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(
                LinearGradient(
                    colors: active ? [Color(hex: 0x7A84A0), Color(hex: 0x4C5570)] : [Color(hex: 0x69738C), Color(hex: 0x41495F)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
            )
            .overlay(
                Rectangle()
                    .fill(color)
                    .frame(height: 3)
                    .padding(.horizontal, 8)
            )
    }
}
