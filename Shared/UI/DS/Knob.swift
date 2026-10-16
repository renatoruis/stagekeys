import SwiftUI

struct Knob: View {
    var label: String
    /// nil: the effect is off and the knob rests at `defaultValue`; moving it turns the effect on.
    var value: Double?
    var color: Color
    var defaultValue: Double = 0
    var size: CGFloat = 40
    /// False when the owning slot is muted/disabled: the knob stays operable but reads as inactive.
    var enabled = true
    /// Incoming MIDI just moved this knob (short pulse).
    var lit = false
    /// A hardware control is bound to this knob.
    var mapped = false
    var format: (Double) -> String = { "\(Int(($0 * 100).rounded()))" }
    var onChange: (Double) -> Void
    var onCommit: (Double) -> Void
    /// Double-click turns the effect off again.
    var onReset: (() -> Void)? = nil

    @State private var dragValue: Double?
    @State private var dragOrigin: Double = 0

    var body: some View {
        let shown = dragValue ?? value ?? defaultValue
        let off = dragValue == nil && value == nil
        VStack(spacing: 3) {
            KnobFace(value: shown, color: off ? DS.textDisabled : (enabled ? color : color.opacity(0.35)))
                .frame(width: size, height: size)
                .overlay(
                    Circle()
                        .strokeBorder(color, lineWidth: 2)
                        .padding(-3)
                        .opacity(lit ? 1 : 0)
                        .animation(lit ? nil : .easeOut(duration: 0.2), value: lit)
                        .allowsHitTesting(false)
                )
                .overlay(alignment: .topTrailing) {
                    if mapped {
                        Circle()
                            .fill(enabled ? color : DS.textMuted)
                            .frame(width: 5, height: 5)
                            .offset(x: 2, y: -2)
                            .help("MIDI mapped")
                    }
                }
                .contentShape(Circle())
                .gesture(drag)
                .continuousControl(value: shown, defaultValue: defaultValue, onCommit: onCommit, onReset: onReset)
                .accessibilityLabel(label)
            Text(label)
                .font(.dsLabel)
                .foregroundStyle(enabled ? DS.textMuted : DS.textDisabled)
                .lineLimit(1)
            Text(off ? "Off" : format(shown))
                .font(.dsValue)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(dragValue != nil ? DS.textAccent : (off ? DS.textDisabled : (enabled ? DS.textPrimary : DS.textMuted)))
        }
        .frame(width: size + 8)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { gesture in
                if dragValue == nil { dragOrigin = value ?? defaultValue }
                let next = min(1, max(0, dragOrigin - gesture.translation.height / 160))
                dragValue = next
                onChange(next)
            }
            .onEnded { _ in
                if let dragValue { onCommit(dragValue) }
                dragValue = nil
            }
    }
}

private struct KnobFace: View, Equatable {
    var value: Double
    var color: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = min(size.width, size.height) / 2
            let ringRadius = radius - 2
            let start = Angle.degrees(135)
            let sweep = 270.0

            var track = Path()
            track.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: .degrees(135 + sweep), clockwise: false)
            let ringWidth = max(3, size.width * 0.075)
            context.stroke(track, with: .color(Color(hex: 0x303748)), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))

            let clamped = min(1, max(0, value))
            if clamped > 0.001 {
                var fill = Path()
                fill.addArc(center: center, radius: ringRadius, startAngle: start, endAngle: .degrees(135 + sweep * clamped), clockwise: false)
                context.stroke(fill, with: .color(color), style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
            }

            let bodyRadius = radius - 7
            let bodyRect = CGRect(x: center.x - bodyRadius, y: center.y - bodyRadius, width: bodyRadius * 2, height: bodyRadius * 2)
            context.fill(
                Path(ellipseIn: bodyRect),
                with: .radialGradient(
                    Gradient(colors: [Color(hex: 0x69738C), Color(hex: 0x414859), Color(hex: 0x252A36)]),
                    center: CGPoint(x: bodyRect.minX + bodyRect.width * 0.35, y: bodyRect.minY + bodyRect.height * 0.3),
                    startRadius: 0,
                    endRadius: bodyRadius * 1.6
                )
            )

            let angle = (135 + sweep * clamped) * .pi / 180
            let inner = bodyRadius * 0.25
            let outer = bodyRadius * 0.85
            var needle = Path()
            needle.move(to: CGPoint(x: center.x + cos(angle) * inner, y: center.y + sin(angle) * inner))
            needle.addLine(to: CGPoint(x: center.x + cos(angle) * outer, y: center.y + sin(angle) * outer))
            context.stroke(needle, with: .color(Color(hex: 0xD8E2FF)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
    }
}
