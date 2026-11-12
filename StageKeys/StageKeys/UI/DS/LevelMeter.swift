import SwiftUI

struct LevelMeter: View {
    var channel: Int
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !active)) { _ in
            let reading = MeterStore.shared.reading(channel)
            Canvas { context, size in
                let track = CGRect(origin: .zero, size: size)
                context.fill(Path(roundedRect: track, cornerRadius: 2), with: .color(Color(hex: 0x202532)))
                let level = Self.scale(reading.level)
                if level > 0 {
                    let height = size.height * level
                    let rect = CGRect(x: 0, y: size.height - height, width: size.width, height: height)
                    context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .linearGradient(
                        Gradient(stops: [
                            .init(color: DS.green, location: 0),
                            .init(color: DS.green, location: 0.72),
                            .init(color: DS.yellow, location: 0.9),
                            .init(color: DS.red, location: 1),
                        ]),
                        startPoint: CGPoint(x: 0, y: size.height),
                        endPoint: .zero
                    ))
                }
                let hold = Self.scale(reading.hold)
                if hold > 0.02 {
                    let y = size.height * (1 - hold)
                    let color = reading.hold >= 0.99 ? DS.red : DS.textSecondary
                    context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1.5)), with: .color(color))
                }
                if reading.clipping {
                    context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: 4)), with: .color(DS.red))
                }
            }
        }
        .frame(width: 5)
        .accessibilityHidden(true)
    }

    static func scale(_ peak: Float) -> CGFloat {
        guard peak > 0.00001 else { return 0 }
        let db = 20 * log10(Double(peak))
        return CGFloat(min(1, max(0, (db + 54) / 54)))
    }
}
