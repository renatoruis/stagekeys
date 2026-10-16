import SwiftUI

struct Panel<Accessory: View, Content: View>: View {
    /// Optional section title. Workspaces omit it because the active engine tab already names them.
    var title: String?
    var color: Color
    private var hasAccessory: Bool
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, color: Color, @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.color = color
        self.hasAccessory = true
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space3) {
            if title != nil || hasAccessory {
                HStack(spacing: DS.space2) {
                    if let title {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(color)
                            .frame(width: 3, height: 12)
                        Text(title.uppercased())
                            .font(.dsSection)
                            .tracking(0.8)
                            .foregroundStyle(DS.textSecondary)
                    }
                    Spacer(minLength: 0)
                    accessory()
                }
            }
            content()
        }
        .padding(DS.space3)
        .background(DS.bgPanel, in: RoundedRectangle(cornerRadius: DS.radiusLG))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusLG).strokeBorder(DS.borderSoft, lineWidth: 1))
    }
}

extension Panel where Accessory == EmptyView {
    init(title: String? = nil, color: Color, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.color = color
        self.hasAccessory = false
        self.accessory = { EmptyView() }
        self.content = content
    }
}

struct Inset<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(DS.space2)
            .background(DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
    }
}
