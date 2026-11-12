import AppKit
import SwiftUI

struct SetlistDrawer: View {
    @Environment(AppModel.self) private var model
    var close: () -> Void
    @State private var pendingDelete: PerformanceSet?
    @State private var renaming: UUID?
    @State private var renameDraft = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.space3) {
            HStack {
                Text("SETLIST")
                    .font(.dsSection)
                    .foregroundStyle(DS.textSecondary)
                    .padding(.leading, DS.trafficLightInset - DS.space3)
                Spacer()
                IconButton(symbol: "xmark", label: "Close setlist", action: close)
            }
            Text(model.rig.setName)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DS.textPrimary)
                .lineLimit(1)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(Array(model.sets.enumerated()), id: \.element.id) { index, song in
                        songRow(song, index: index)
                    }
                }
            }
            if !model.liveMode {
                HStack(spacing: DS.space2) {
                    TextButton(title: "Add song", symbol: "plus", action: model.newSet)
                    TextButton(title: "Duplicate", action: model.duplicateCurrent)
                }
            }
            if model.learnOn {
                LearnChipFor(state: LearnState(model, .previousSong, 0), prefix: "Previous ")
                LearnChipFor(state: LearnState(model, .nextSong, 0), prefix: "Next ")
            }
        }
        .padding(DS.space3)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(DS.bgPanel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DS.borderSoft).frame(width: 1)
        }
        .confirmationDialog(
            "Delete \u{201C}\(pendingDelete?.name ?? "")\u{201D}?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { song in
            Button("Delete Song", role: .destructive) { model.delete(id: song.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the song and its Pads, Drums and Metronome settings from the set. This cannot be undone.")
        }
    }

    private func beginRename(_ song: PerformanceSet) {
        renameDraft = song.name
        renaming = song.id
        DispatchQueue.main.async { renameFocused = true }
    }

    private func commitRename() {
        if let id = renaming {
            let name = renameDraft.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { model.renameSong(id: id, name: name) }
        }
        renaming = nil
        KeyCommands.releaseFocus()
    }

    private func songRow(_ song: PerformanceSet, index: Int) -> some View {
        let current = song.id == model.set.id
        let next = model.sets.count > 1 && song.id == model.sets[(model.setIndex + 1) % model.sets.count].id
        return HStack(spacing: DS.space2) {
            if !model.liveMode {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DS.textMuted)
                    .frame(width: 16, height: 28)
                    .contentShape(Rectangle())
                    .onDrag { NSItemProvider(object: song.id.uuidString as NSString) }
                    .help("Drag to reorder")
            }
            VStack(alignment: .leading, spacing: 1) {
                if renaming == song.id {
                    TextField("Song name", text: $renameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DS.textPrimary)
                        .focused($renameFocused)
                        .onSubmit(commitRename)
                        .onExitCommand { renaming = nil; KeyCommands.releaseFocus() }
                        .onChange(of: renameFocused) { _, focused in if !focused, renaming == song.id { commitRename() } }
                } else {
                    Text(String(format: "%02d  %@", index + 1, song.name))
                        .font(.system(size: 13, weight: current ? .semibold : .regular))
                        .foregroundStyle(current ? DS.textPrimary : DS.textSecondary)
                        .lineLimit(1)
                }
                if current {
                    Text("CURRENT")
                        .font(.dsMeta)
                        .foregroundStyle(DS.blue)
                } else if next {
                    Text("NEXT")
                        .font(.dsMeta)
                        .foregroundStyle(DS.textMuted)
                }
            }
            Spacer(minLength: 0)
            if !model.liveMode && current {
                IconButton(symbol: "trash", label: "Delete song", size: 24) { pendingDelete = song }
            }
        }
        .padding(.horizontal, DS.space2)
        .padding(.vertical, 6)
        .frame(minHeight: 40)
        .background(current ? DS.bgPanelAlt : Color.clear, in: RoundedRectangle(cornerRadius: DS.radiusSM))
        .contentShape(Rectangle())
        .onTapGesture { if renaming != song.id { model.open(song) } }
        .contextMenu {
            if !model.liveMode {
                Button("Rename") { beginRename(song) }
                Button("Duplicate") { model.duplicate(id: song.id) }
                Divider()
                Button("Delete…", role: .destructive) { pendingDelete = song }
            }
        }
        .onDrop(of: [.plainText], isTargeted: nil) { providers in
            guard !model.liveMode, let provider = providers.first else { return false }
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let raw = object as? String, let id = UUID(uuidString: raw) else { return }
                DispatchQueue.main.async { model.moveSong(id: id, before: index) }
            }
            return true
        }
    }
}

