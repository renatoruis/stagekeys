import SwiftUI

struct LibraryItem: Identifiable, Equatable {
    var id: String
    var name: String
    var detail: String
    var section: String
}

/// The current pad, drum sample or click sound; opens its library browser.
struct LibraryButton: View {
    var title: String
    var symbol: String
    var color: Color
    var empty: Bool
    var help: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DS.space2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(empty ? DS.textMuted : color)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(empty ? DS.textMuted : DS.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.textMuted)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.slotGradient, in: RoundedRectangle(cornerRadius: DS.radiusSM))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderDefault, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// Items by section, imported files under Custom. Without imports and with one section the sidebar is hidden.
struct LibraryPicker: View {
    var meta: String
    var title: String
    var color: Color
    /// Plural shown in the search field and counts, e.g. "pads".
    var noun: String
    var items: [LibraryItem]
    var sections: [String]
    var selection: String?
    /// nil: nothing can be imported here.
    var importTitle: String?
    var allowsNone = true
    var sectionTitle: (String) -> String = { $0 }
    var symbol: (String) -> String
    var onChoose: (String?) -> Void
    var onImport: () -> Void = {}
    var close: () -> Void
    /// nil shows every section.
    @State private var section: String?
    @State private var query = ""

    private static let imported = ResourceCatalog.importedCategory

    private var allSections: [String] {
        let library = sections.filter { $0 != Self.imported }
        return importTitle == nil ? library : library + [Self.imported]
    }

    private var showsSidebar: Bool { allSections.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.borderSoft).frame(height: 1)
            HStack(spacing: 0) {
                if showsSidebar {
                    sidebar
                        .frame(width: 190)
                        .background(DS.bgApp)
                    Rectangle().fill(DS.borderSoft).frame(width: 1)
                }
                grid
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(DS.borderSoft).frame(height: 1)
            footer
        }
        .frame(width: showsSidebar ? 880 : 600, height: showsSidebar ? 600 : 440)
        .background(DS.bgPanel)
        .preferredColorScheme(.dark)
        .onAppear {
            section = items.first { $0.id == selection }?.section
        }
        .onChange(of: query) { _, text in
            if !text.isEmpty { section = nil }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.space3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 3, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(meta.uppercased())
                    .font(.dsSection)
                    .tracking(0.8)
                    .foregroundStyle(DS.textSecondary)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(selection == nil ? DS.textMuted : DS.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.space3)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.textMuted)
                TextField("Search \(noun)", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textPrimary)
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(DS.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(width: 240, height: 30)
            .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
            .overlay(RoundedRectangle(cornerRadius: DS.radiusSM).strokeBorder(DS.borderDefault, lineWidth: 1))
            TextButton(title: "Done", symbol: "checkmark", prominent: true, action: close)
                .fixedSize()
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, DS.space4)
        .frame(height: 64)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(title: "All \(noun)", symbol: "square.grid.2x2", count: items.count, value: nil)
                groupTitle("CATEGORIES")
                ForEach(allSections.filter { $0 != Self.imported }, id: \.self) { item in
                    sidebarRow(title: sectionTitle(item), symbol: symbol(item), count: count(item), value: item)
                }
                if importTitle != nil {
                    groupTitle("CUSTOM")
                    sidebarRow(title: Self.imported, symbol: symbol(Self.imported), count: count(Self.imported), value: Self.imported)
                }
            }
            .padding(DS.space2)
        }
    }

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.dsMeta)
            .foregroundStyle(DS.textMuted)
            .padding(.horizontal, DS.space2)
            .padding(.top, DS.space3)
            .padding(.bottom, 2)
    }

    private func sidebarRow(title: String, symbol: String, count: Int, value: String?) -> some View {
        let active = section == value && query.isEmpty
        let holdsCurrent = value != nil && items.first { $0.id == selection }?.section == value
        return Button {
            section = value
            query = ""
        } label: {
            HStack(spacing: DS.space2) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? color : DS.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular))
                    .foregroundStyle(active ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
                if holdsCurrent {
                    Circle().fill(color).frame(width: 5, height: 5)
                }
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.dsMeta.monospacedDigit())
                    .foregroundStyle(DS.textMuted)
            }
            .padding(.horizontal, DS.space2)
            .frame(height: 32)
            .background(active ? DS.bgControl : Color.clear, in: RoundedRectangle(cornerRadius: DS.radiusSM))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    private func count(_ item: String) -> Int {
        items.filter { $0.section == item }.count
    }

    // MARK: Items

    private var grid: some View {
        let shown = section.map { [$0] } ?? allSections
        let groups = shown.compactMap { item -> (String, [LibraryItem])? in
            let matching = items.filter { $0.section == item && matches($0) }
            return matching.isEmpty ? nil : (item, matching)
        }
        return ScrollView {
            if groups.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: DS.space4) {
                    ForEach(groups, id: \.0) { item, entries in
                        VStack(alignment: .leading, spacing: DS.space2) {
                            if section == nil && showsSidebar {
                                Text(sectionTitle(item).uppercased())
                                    .font(.dsSection)
                                    .tracking(0.8)
                                    .foregroundStyle(DS.textMuted)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: DS.space2)], spacing: DS.space2) {
                                ForEach(entries) { entry in card(entry) }
                            }
                        }
                    }
                }
                .padding(DS.space4)
            }
        }
    }

    private func card(_ item: LibraryItem) -> some View {
        let current = selection == item.id
        return Button {
            onChoose(item.id)
            close()
        } label: {
            VStack(alignment: .leading, spacing: DS.space2) {
                HStack {
                    Image(systemName: symbol(item.section))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(current ? color : DS.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                    Spacer()
                    if current {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(color)
                    }
                }
                Spacer(minLength: 0)
                Text(item.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DS.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.detail)
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
            }
            .padding(DS.space3)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(current ? DS.bgControl : DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .strokeBorder(current ? color : DS.borderSoft, lineWidth: current ? 1.5 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusMD))
        }
        .buttonStyle(PressStyle())
        .help(item.name)
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.space3) {
            if !query.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.textMuted)
                Text("No \(noun) match \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
            } else {
                Image(systemName: symbol(Self.imported))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.textMuted)
                Text("Nothing imported yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
                if let importTitle {
                    Text("Imported files show up here.")
                        .font(.dsLabel)
                        .foregroundStyle(DS.textMuted)
                    TextButton(title: importTitle, symbol: "square.and.arrow.down", action: importFile)
                        .fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, showsSidebar ? 120 : 60)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: DS.space2) {
            if allowsNone {
                TextButton(title: "None", symbol: "minus.circle") {
                    onChoose(nil)
                    close()
                }
                .fixedSize()
                .disabled(selection == nil)
                .opacity(selection == nil ? 0.5 : 1)
            }
            Spacer()
            if let importTitle {
                Text("Imported files are listed under Custom.")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
                TextButton(title: importTitle, symbol: "square.and.arrow.down", action: importFile)
                    .fixedSize()
            }
        }
        .padding(.horizontal, DS.space4)
        .frame(height: 52)
    }

    /// Closes the sheet first so the open panel is not stacked on top of it.
    private func importFile() {
        close()
        DispatchQueue.main.async(execute: onImport)
    }

    private func matches(_ item: LibraryItem) -> Bool {
        guard !query.isEmpty else { return true }
        return item.name.localizedCaseInsensitiveContains(query)
            || sectionTitle(item.section).localizedCaseInsensitiveContains(query)
    }
}

enum LibrarySymbols {
    static func pad(_ section: String) -> String {
        section == ResourceCatalog.importedCategory ? "tray.and.arrow.down" : "cloud"
    }

    static func drum(_ section: String) -> String {
        switch section {
        case "Kicks": "speaker.wave.3"
        case "Snares": "circle.circle"
        case "Claps": "hands.clap"
        case "Snaps": "hand.tap"
        case "HiHats": "circle.lefthalf.filled"
        case "Shakers": "waveform.path"
        case "Tambourines": "circle.dashed"
        case "Woods": "rectangle.portrait"
        case "Subs": "speaker.wave.1"
        case "FX": "sparkles"
        case "Loops": "repeat"
        case ResourceCatalog.importedCategory: "tray.and.arrow.down"
        default: "music.note"
        }
    }
}
