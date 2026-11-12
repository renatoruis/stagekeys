import Foundation

enum ImportKind {
    case soundFont
    case pad
    case drum

    var subpath: String {
        switch self {
        case .soundFont: "sf2"
        case .pad: "pads"
        case .drum: "drums"
        }
    }

    var allowedTypes: [String] {
        switch self {
        case .soundFont: ["sf2"]
        case .pad, .drum: ["m4a", "wav", "aiff", "aif", "mp3", "caf"]
        }
    }
}
