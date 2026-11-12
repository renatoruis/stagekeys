import SwiftUI

enum DS {
    static let bgApp = Color(hex: 0x10131D)
    static let bgPanel = Color(hex: 0x171B27)
    static let bgPanelAlt = Color(hex: 0x1D2230)
    static let bgRaised = Color(hex: 0x202635)
    static let bgControl = Color(hex: 0x272D3D)
    static let bgControlHover = Color(hex: 0x30374A)
    static let bgControlActive = Color(hex: 0x384159)

    static let borderSoft = Color(hex: 0x2B3141)
    static let borderDefault = Color(hex: 0x3B4357)
    static let borderStrong = Color(hex: 0x4A536A)
    static let borderFocus = Color(hex: 0x7898E8)

    static let textPrimary = Color(hex: 0xEEF3FF)
    static let textSecondary = Color(hex: 0xAAB3C9)
    static let textMuted = Color(hex: 0x747D96)
    static let textDisabled = Color(hex: 0x545D72)
    static let textAccent = Color(hex: 0xB9CBFF)

    static let blue = Color(hex: 0x4B6FFF)
    static let green = Color(hex: 0x42D576)
    static let orange = Color(hex: 0xFFAE45)
    static let purple = Color(hex: 0x985CF4)
    static let pink = Color(hex: 0xE96ABB)
    static let red = Color(hex: 0xEF6262)
    static let cyan = Color(hex: 0x48C7D9)
    static let yellow = Color(hex: 0xF4C85A)
    static let mint = Color(hex: 0x5CD6C0)

    /// Neutral chosen fill.
    static let selected = Color(hex: 0xD9DFEE)
    static let onSelected = Color(hex: 0x171B24)

    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space6: CGFloat = 24

    /// Horizontal room reserved for the macOS traffic lights in a hidden-title-bar window.
    static let trafficLightInset: CGFloat = 80

    static let radiusXS: CGFloat = 6
    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 12
    static let radiusLG: CGFloat = 16

    static let controlGradient = LinearGradient(
        colors: [Color(hex: 0x30374A), Color(hex: 0x282E3E)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let slotGradient = LinearGradient(
        colors: [Color(hex: 0x32394D), Color(hex: 0x292F41)],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Font {
    static let dsSection = Font.system(size: 11, weight: .semibold).width(.expanded)
    static let dsChannel = Font.system(size: 13, weight: .medium)
    static let dsLabel = Font.system(size: 11, weight: .regular)
    static let dsValue = Font.system(size: 12, weight: .semibold).monospacedDigit()
    static let dsMeta = Font.system(size: 10, weight: .regular)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
