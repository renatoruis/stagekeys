import AppKit
import SwiftUI

/// The app version in the top bar; opens a popover with the site, GitHub and Pix.
struct AboutButton: View {
    var appName: String
    var colors: [Color]
    @State private var open = false

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    var body: some View {
        Button { open.toggle() } label: {
            Text("v\(Self.version)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(open ? DS.textSecondary : DS.textMuted)
                .frame(height: 28)
                .padding(.horizontal, 4)
        }
        .buttonStyle(PressStyle())
        .help("About \(appName)")
        .popover(isPresented: $open, arrowEdge: .bottom) {
            AboutPanel(appName: appName, version: Self.version, colors: colors)
        }
    }
}

private struct AboutPanel: View {
    var appName: String
    var version: String
    var colors: [Color]
    @State private var copied = false

    private static let pix = "renatoruis@gmail.com"

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space3) {
            HStack(spacing: DS.space3) {
                LogoBars(colors: colors)
                VStack(alignment: .leading, spacing: 2) {
                    Text(appName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                    Text("Version \(version)")
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                }
            }
            Text("Free, made as a hobby for friends who play keys.")
                .font(.dsLabel)
                .foregroundStyle(DS.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: DS.space1) {
                link("Website", detail: "stagekeys.com.br", symbol: "globe", url: "https://stagekeys.com.br")
                link("Star on GitHub", detail: "renatoruis/stagekeys", symbol: "star", url: "https://github.com/renatoruis/stagekeys")
                link("Contact", detail: Self.pix, symbol: "envelope", url: "mailto:\(Self.pix)?subject=\(appName)")
                row("Buy me a coffee (Pix)", detail: Self.pix, symbol: "cup.and.saucer") {
                    TextButton(title: copied ? "Copied" : "Copy", symbol: copied ? "checkmark" : "doc.on.doc", tint: copied ? DS.green : nil) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.pix, forType: .string)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    .fixedSize()
                }
            }
        }
        .padding(DS.space4)
        .frame(width: 300)
    }

    private func link(_ title: String, detail: String, symbol: String, url: String) -> some View {
        Button {
            if let url = URL(string: url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? url) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            row(title, detail: detail, symbol: symbol) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.textMuted)
            }
        }
        .buttonStyle(PressStyle())
    }

    private func row<Trailing: View>(_ title: String, detail: String, symbol: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: DS.space2) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DS.textPrimary)
                Text(detail)
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.space2)
            trailing()
        }
        .padding(.horizontal, DS.space2)
        .frame(height: 40)
        .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderSoft, lineWidth: 1))
    }
}

/// The four bars of the StageKeys logo.
private struct LogoBars: View {
    var colors: [Color]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(zip([10.0, 16.0, 12.0, 18.0], colors).enumerated()), id: \.offset) { _, bar in
                Capsule()
                    .fill(bar.1)
                    .frame(width: 4, height: bar.0)
            }
        }
        .frame(width: 32, height: 32)
        .background(DS.bgApp, in: RoundedRectangle(cornerRadius: DS.radiusSM))
        .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderSoft, lineWidth: 1))
    }
}
