import SwiftUI

/// The layer's current sound; opens the sound browser.
struct SoundButton: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var slot: KeySlot
    @State private var open = false

    var body: some View {
        let font = model.catalog.soundFont(slot.fileID)
        Button { open = true } label: {
            HStack(spacing: DS.space2) {
                Image(systemName: SoundPicker.symbol(font?.subcategory ?? font?.category))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(font == nil ? DS.textMuted : DS.keyColors[index % DS.keyColors.count])
                    .frame(width: 18)
                Text(model.keyTitle(index))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(font == nil ? DS.textMuted : DS.textPrimary)
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
        .help("Choose a sound for layer \(index + 1)")
        .sheet(isPresented: $open) {
            SoundPicker(index: index) { open = false }
                .environment(model)
        }
    }
}

/// A sound on disk, or one listed in the online library that is not downloaded yet.
private struct SoundEntry: Identifiable {
    var id: String
    var name: String
    var category: String
    var subcategory: String?
    var font: SoundFont?
    var remote: RemoteSound?

    /// File name in the online library; nil for imported files.
    var file: String? { id.hasPrefix("sf2/") ? String(id.dropFirst("sf2/".count)) : nil }
}

/// Sounds by category: downloaded, online and imported. Files with several sounds open their own list.
struct SoundPicker: View {
    @Environment(AppModel.self) private var model
    var index: Int
    var close: () -> Void
    /// nil shows every category.
    @State private var category: String?
    @State private var subcategory: String?
    @State private var openFontID: String?
    @State private var query = ""

    private var slot: KeySlot { model.state.keySlots[index] }
    private var color: Color { DS.keyColors[index % DS.keyColors.count] }

    private var entries: [SoundEntry] {
        let fonts = model.catalog.soundFonts
        let remote = Dictionary(model.sounds.remote.map { ("sf2/\($0.file)", $0) }) { first, _ in first }
        let local = fonts.map { font in
            SoundEntry(id: font.id, name: font.name, category: font.category, subcategory: font.subcategory, font: font, remote: remote[font.id])
        }
        let ids = Set(fonts.map(\.id))
        let online = remote.filter { !ids.contains($0.key) }.map { id, sound in
            let parsed = ResourceCatalog.parseName((sound.file as NSString).deletingPathExtension)
            return SoundEntry(id: id, name: parsed.name, category: parsed.category, subcategory: parsed.subcategory, remote: sound)
        }
        return (local + online).sorted { $0.id < $1.id }
    }

    private func categories(_ entries: [SoundEntry]) -> [String] {
        let present = ResourceCatalog.orderedCategories(Set(entries.map(\.category)))
        return present.contains(ResourceCatalog.importedCategory) ? present : present + [ResourceCatalog.importedCategory]
    }

    private func subcategories(_ item: String, _ entries: [SoundEntry]) -> [String] {
        ResourceCatalog.orderedCategories(Set(entries.filter { $0.category == item }.compactMap(\.subcategory)))
    }

    var body: some View {
        let entries = entries
        VStack(spacing: 0) {
            header
            Rectangle().fill(DS.borderSoft).frame(height: 1)
            HStack(spacing: 0) {
                sidebar(entries)
                    .frame(width: 190)
                    .background(DS.bgApp)
                Rectangle().fill(DS.borderSoft).frame(width: 1)
                Group {
                    if let font = model.catalog.soundFonts.first(where: { $0.id == openFontID }) {
                        presetList(font)
                    } else {
                        fontGrid(entries)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle().fill(DS.borderSoft).frame(height: 1)
            footer
        }
        .frame(width: 880, height: 600)
        .background(DS.bgPanel)
        .preferredColorScheme(.dark)
        .onAppear {
            model.sounds.refreshIfStale()
            if let font = model.catalog.soundFont(slot.fileID) {
                category = font.category
                if font.presets.count > 1 { openFontID = font.id }
            } else if let id = slot.fileID, id.hasPrefix("sf2/") {
                category = ResourceCatalog.parseName(((id as NSString).lastPathComponent as NSString).deletingPathExtension).category
            }
        }
        .onChange(of: query) { _, text in
            if !text.isEmpty {
                category = nil
                subcategory = nil
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: DS.space3) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 3, height: 14)
            VStack(alignment: .leading, spacing: 2) {
                Text("LAYER \(index + 1)")
                    .font(.dsSection)
                    .tracking(0.8)
                    .foregroundStyle(DS.textSecondary)
                Text(model.keyTitle(index))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(slot.fileID == nil ? DS.textMuted : DS.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: DS.space3)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.textMuted)
                TextField("Search sounds", text: $query)
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
            .frame(width: 260, height: 30)
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

    private func sidebar(_ entries: [SoundEntry]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                sidebarRow(title: "All sounds", symbol: "square.grid.2x2", count: entries.count, value: nil)
                Text("CATEGORIES")
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
                    .padding(.horizontal, DS.space2)
                    .padding(.top, DS.space3)
                    .padding(.bottom, 2)
                ForEach(categories(entries).filter { $0 != ResourceCatalog.importedCategory }, id: \.self) { item in
                    sidebarRow(title: item, symbol: Self.symbol(item), count: entries.filter { $0.category == item }.count, value: item)
                    ForEach(subcategories(item, entries), id: \.self) { sub in
                        sidebarRow(
                            title: sub, symbol: Self.symbol(sub),
                            count: entries.filter { $0.category == item && $0.subcategory == sub }.count,
                            value: item, sub: sub
                        )
                    }
                }
                Text("CUSTOM")
                    .font(.dsMeta)
                    .foregroundStyle(DS.textMuted)
                    .padding(.horizontal, DS.space2)
                    .padding(.top, DS.space3)
                    .padding(.bottom, 2)
                sidebarRow(
                    title: ResourceCatalog.importedCategory,
                    symbol: Self.symbol(ResourceCatalog.importedCategory),
                    count: entries.filter { $0.category == ResourceCatalog.importedCategory }.count,
                    value: ResourceCatalog.importedCategory
                )
            }
            .padding(DS.space2)
        }
    }

    private func sidebarRow(title: String, symbol: String, count: Int, value: String?, sub: String? = nil) -> some View {
        let active = category == value && subcategory == sub && openFontID == nil && query.isEmpty
        let current = model.catalog.soundFont(slot.fileID)
        let holdsCurrent = value != nil && current?.category == value && (sub == nil || current?.subcategory == sub)
        return Button {
            category = value
            subcategory = sub
            openFontID = nil
            query = ""
        } label: {
            HStack(spacing: DS.space2) {
                Image(systemName: symbol)
                    .font(.system(size: sub == nil ? 12 : 11, weight: .medium))
                    .foregroundStyle(active ? color : DS.textSecondary)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: sub == nil ? 13 : 12, weight: active ? .semibold : .regular))
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
            .padding(.leading, sub == nil ? DS.space2 : DS.space2 + 18)
            .padding(.trailing, DS.space2)
            .frame(height: sub == nil ? 32 : 28)
            .background(active ? DS.bgControl : Color.clear, in: RoundedRectangle(cornerRadius: DS.radiusSM))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    // MARK: Sounds

    private func fontGrid(_ entries: [SoundEntry]) -> some View {
        let shown = entries.filter(matches)
        var sections: [(id: String, title: String?, entries: [SoundEntry])] = []
        if let category, let subcategory {
            sections = [(subcategory, nil, shown.filter { $0.category == category && $0.subcategory == subcategory })]
        } else if let category {
            let inCategory = shown.filter { $0.category == category }
            sections = [("", nil, inCategory.filter { $0.subcategory == nil })]
            for sub in subcategories(category, entries) {
                sections.append((sub, sub, inCategory.filter { $0.subcategory == sub }))
            }
        } else {
            sections = categories(entries).map { item in (item, item, shown.filter { $0.category == item }) }
        }
        sections.removeAll { $0.entries.isEmpty }
        return ScrollView {
            if sections.isEmpty {
                emptyState
            } else {
                VStack(alignment: .leading, spacing: DS.space4) {
                    ForEach(sections, id: \.id) { section in
                        VStack(alignment: .leading, spacing: DS.space2) {
                            if let title = section.title {
                                Text(title.uppercased())
                                    .font(.dsSection)
                                    .tracking(0.8)
                                    .foregroundStyle(DS.textMuted)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: DS.space2)], spacing: DS.space2) {
                                ForEach(section.entries) { entry in card(entry) }
                            }
                        }
                    }
                }
                .padding(DS.space4)
            }
        }
    }

    private func card(_ entry: SoundEntry) -> some View {
        let current = slot.fileID == entry.id
        let several = (entry.font?.presets.count ?? 0) > 1
        let state = entry.file.map { model.sounds.state($0) } ?? .downloaded
        let downloading: Double? = if case .downloading(let value) = state { value } else { nil }
        return Button {
            if let font = entry.font {
                if several {
                    openFontID = font.id
                } else if let preset = font.presets.first {
                    choose(font, preset)
                }
            } else if downloading == nil, let file = entry.file {
                model.sounds.download(file)
            }
        } label: {
            VStack(alignment: .leading, spacing: DS.space2) {
                HStack {
                    Image(systemName: Self.symbol(entry.subcategory ?? entry.category))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(current ? color : entry.font == nil ? DS.textMuted : DS.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(DS.bgControl, in: RoundedRectangle(cornerRadius: DS.radiusSM))
                    Spacer()
                    if current, entry.font != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(color)
                    } else if entry.font == nil, downloading == nil {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(DS.textMuted)
                    } else if several {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.textMuted)
                    }
                }
                Spacer(minLength: 0)
                Text(entry.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(entry.font == nil ? DS.textSecondary : DS.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let downloading {
                    ProgressView(value: downloading)
                        .progressViewStyle(.linear)
                        .tint(color)
                        .controlSize(.small)
                } else {
                    Text(caption(entry, state: state))
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(DS.space3)
            .frame(maxWidth: .infinity, minHeight: 112, alignment: .topLeading)
            .background(current ? DS.bgControl : DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusMD))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusMD)
                    .strokeBorder(current ? color : DS.borderSoft, style: StrokeStyle(lineWidth: current ? 1.5 : 1, dash: entry.font == nil ? [4, 3] : []))
            )
            .contentShape(RoundedRectangle(cornerRadius: DS.radiusMD))
        }
        .buttonStyle(PressStyle())
        .overlay(alignment: .topTrailing) {
            if downloading != nil, let file = entry.file {
                IconButton(symbol: "xmark", label: "Cancel download", size: 24) { model.sounds.cancel(file) }
                    .padding(DS.space3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if state == .update, let file = entry.file {
                Button { model.sounds.download(file) } label: {
                    Text("Update")
                        .font(.dsMeta.weight(.semibold))
                        .foregroundStyle(DS.onSelected)
                        .padding(.horizontal, 8)
                        .frame(height: 20)
                        .background(DS.yellow, in: Capsule())
                }
                .buttonStyle(PressStyle())
                .help("A newer version is in the online library. Click to download it.")
                .padding(DS.space3)
            }
        }
        .help(help(entry))
        .contextMenu {
            if entry.id.hasPrefix("user/") {
                Button("Remove from Library", role: .destructive) { model.removeSoundFont(entry.id) }
            } else if entry.font != nil, let file = entry.file {
                Button("Remove download", role: .destructive) { model.sounds.remove(file) }
            }
        }
    }

    private func caption(_ entry: SoundEntry, state: SoundLibrary.State) -> String {
        var detail: String?
        if let font = entry.font {
            if font.presets.count > 1 { detail = "\(font.presets.count) sounds" }
            if state == .removed { detail = [detail, "Not in the online library"].compactMap { $0 }.joined(separator: " · ") }
        } else if let remote = entry.remote {
            detail = ByteCountFormatter.string(fromByteCount: remote.size, countStyle: .file)
        }
        let place: String? = if category == nil, let sub = entry.subcategory {
            "\(entry.category) · \(sub)"
        } else if detail == nil {
            entry.subcategory ?? entry.category
        } else {
            nil
        }
        return [place, detail].compactMap { $0 }.joined(separator: " · ")
    }

    private func help(_ entry: SoundEntry) -> String {
        guard let font = entry.font else { return "\(entry.name): click to download" }
        let several = font.presets.count > 1
        return several ? "\(font.name): \(font.presets.count) sounds" : font.name
    }

    private func presetList(_ font: SoundFont) -> some View {
        let presets = font.presets.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || font.name.localizedCaseInsensitiveContains(query) }
        let place = [font.category, font.subcategory].compactMap { $0 }.joined(separator: " · ")
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.space3) {
                IconButton(symbol: "chevron.left", label: "Back to \(font.subcategory ?? font.category)", size: 28) { openFontID = nil }
                VStack(alignment: .leading, spacing: 2) {
                    Text(font.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                    Text("\(place) · \(font.presets.count) sounds")
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                }
                Spacer()
            }
            .padding(DS.space4)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: DS.space2)], spacing: DS.space2) {
                    ForEach(presets) { preset in
                        presetRow(font, preset)
                    }
                }
                .padding([.horizontal, .bottom], DS.space4)
            }
        }
    }

    private func presetRow(_ font: SoundFont, _ preset: SoundFontPreset) -> some View {
        let current = slot.fileID == font.id && slot.bank == preset.bank && slot.program == preset.program
        return Button { choose(font, preset) } label: {
            HStack(spacing: DS.space2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: current ? .semibold : .regular))
                    .foregroundStyle(current ? DS.textPrimary : DS.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(color)
                }
            }
            .padding(.horizontal, DS.space3)
            .frame(height: 40)
            .background(current ? DS.bgControl : DS.bgPanelAlt, in: RoundedRectangle(cornerRadius: DS.radiusSM))
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .strokeBorder(current ? color : DS.borderSoft, lineWidth: current ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: DS.space3) {
            if !query.isEmpty {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.textMuted)
                Text("No sounds match \u{201C}\(query)\u{201D}.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
            } else if category != ResourceCatalog.importedCategory {
                Image(systemName: "icloud")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.textMuted)
                Text(model.sounds.baseURL == nil ? "No sounds downloaded." : "No sounds yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
                Text(model.sounds.baseURL == nil ? "The online library is not set up." : "Refresh the library to see the online sounds.")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
            } else {
                Image(systemName: Self.symbol(ResourceCatalog.importedCategory))
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(DS.textMuted)
                Text("No imported sounds yet.")
                    .font(.system(size: 13))
                    .foregroundStyle(DS.textSecondary)
                Text("Import an SF2 file and it shows up here.")
                    .font(.dsLabel)
                    .foregroundStyle(DS.textMuted)
                TextButton(title: "Import SF2…", symbol: "square.and.arrow.down", action: importSound)
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    // MARK: Footer

    private var footer: some View {
        let sounds = model.sounds
        return HStack(spacing: DS.space2) {
            TextButton(title: "No sound", symbol: "minus.circle") {
                model.setKeySound(index: index, fileID: nil, bank: 0, program: 0)
                close()
            }
            .fixedSize()
            .disabled(slot.fileID == nil)
            .opacity(slot.fileID == nil ? 0.5 : 1)
            Spacer()
            if sounds.baseURL == nil {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(DS.yellow)
            }
            Text(libraryStatus)
                .font(.dsLabel)
                .foregroundStyle(sounds.error == nil ? DS.textMuted : DS.red)
                .lineLimit(1)
            TextButton(title: sounds.refreshing ? "Refreshing…" : "Refresh library", symbol: "arrow.clockwise") { sounds.refresh() }
                .fixedSize()
                .disabled(sounds.baseURL == nil || sounds.refreshing)
                .opacity(sounds.baseURL == nil ? 0.5 : 1)
            TextButton(title: "Import SF2…", symbol: "square.and.arrow.down", action: importSound)
                .fixedSize()
        }
        .padding(.horizontal, DS.space4)
        .frame(height: 52)
    }

    private var libraryStatus: String {
        let sounds = model.sounds
        let used = ByteCountFormatter.string(fromByteCount: sounds.usedBytes, countStyle: .file)
        if sounds.baseURL == nil { return "Online library URL not set · \(used) on disk" }
        if let error = sounds.error { return error }
        guard let fetched = sounds.fetched else { return "Not refreshed yet · \(used) on disk" }
        let when = fetched.timeIntervalSinceNow > -60 ? "just now" : RelativeDateTimeFormatter().localizedString(for: fetched, relativeTo: Date())
        return "Updated \(when) · \(used) on disk"
    }

    private func choose(_ font: SoundFont, _ preset: SoundFontPreset) {
        model.setKeySound(index: index, fileID: font.id, bank: preset.bank, program: preset.program)
        close()
    }

    /// Closes the sheet first so the open panel is not stacked on top of it.
    private func importSound() {
        close()
        DispatchQueue.main.async { model.importSoundFont(index: index) }
    }

    private func matches(_ entry: SoundEntry) -> Bool {
        guard !query.isEmpty else { return true }
        return entry.name.localizedCaseInsensitiveContains(query)
            || entry.category.localizedCaseInsensitiveContains(query)
            || (entry.subcategory?.localizedCaseInsensitiveContains(query) ?? false)
            || (entry.font?.presets.contains { $0.name.localizedCaseInsensitiveContains(query) } ?? false)
    }

    static func symbol(_ category: String?) -> String {
        switch category {
        case "Nord": "n.square"
        case "Piano": "pianokeys"
        case "Electric Piano": "pianokeys.inverse"
        case "Organ": "slider.vertical.3"
        case "Pad": "cloud"
        case "Strings": "music.quarternote.3"
        case "Synth": "waveform"
        case "Bell": "bell"
        case "Vox": "music.mic"
        case "Accordion": "rectangle.split.3x1"
        case "FX": "sparkles"
        case "Collection": "square.stack.3d.up"
        case ResourceCatalog.importedCategory: "tray.and.arrow.down"
        default: "music.note"
        }
    }
}
