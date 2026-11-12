import SwiftUI

extension DS {
    static let keys = cyan
    static let keyColors = [cyan, mint, orange, pink]
    static let pads = purple
    static let padColors = [purple, yellow, red, cyan]
    static let metronome = orange

    static func drumColor(_ raw: String) -> Color {
        switch DrumColor(rawValue: raw) ?? .stone {
        case .stone: Color(hex: 0x4E5870)
        case .blue: blue
        case .green: green
        case .amber: orange
        case .pink: pink
        case .violet: purple
        case .red: red
        case .white: textPrimary
        }
    }
}

extension MeterStore.Channel {
    static let keys = 0
    static let keysMaster = 4
    static let pad = 5
    static let drums = 9
    static let metronome = 10
}
