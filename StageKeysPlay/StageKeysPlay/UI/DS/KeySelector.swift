import SwiftUI

struct KeyButtons: View, Equatable {
    var selection: String
    var color: Color
    var height: CGFloat = 26
    var fontSize: CGFloat = 11
    var onSelect: (String) -> Void

    static let keys: [(token: String, label: String)] = [
        ("C", "C"), ("Cs", "C#"), ("D", "D"), ("Ds", "Eb"), ("E", "E"), ("F", "F"),
        ("Fs", "F#"), ("G", "G"), ("Gs", "Ab"), ("A", "A"), ("As", "Bb"), ("B", "B"),
    ]

    static func label(for token: String) -> String {
        keys.first { $0.token == token }?.label ?? token
    }

    static func == (lhs: KeyButtons, rhs: KeyButtons) -> Bool {
        lhs.selection == rhs.selection && lhs.color == rhs.color
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Self.keys, id: \.token) { key in
                let on = key.token == selection
                Button {
                    onSelect(key.token)
                } label: {
                    Text(key.label)
                        .font(.system(size: fontSize, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? DS.onSelected : DS.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: height)
                        .background(on ? color : DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusXS))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.radiusXS)
                                .strokeBorder(on ? Color.clear : DS.borderDefault, lineWidth: 1)
                        )
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("Key \(key.label)")
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
