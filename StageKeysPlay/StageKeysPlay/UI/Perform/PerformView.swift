import AppKit
import SwiftUI

private struct MeteringActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var meteringActive: Bool {
        get { self[MeteringActiveKey.self] }
        set { self[MeteringActiveKey.self] = newValue }
    }
}

struct PerformView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var phase
    @State private var setlistOpen = false
    @State private var keys = KeyCommands()
    @State private var focusSettled = false

    var body: some View {
        HStack(spacing: 0) {
            if setlistOpen {
                SetlistDrawer(close: { withAnimation(.easeOut(duration: 0.18)) { setlistOpen = false } })
                    .frame(width: 280)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            VStack(spacing: 0) {
                TopBar(setlistOpen: $setlistOpen)
                ShowView()
                    .padding(DS.space3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(DS.bgApp.onTapGesture { KeyCommands.releaseFocus() })
        .environment(\.meteringActive, phase == .active)
        .onAppear {
            model.setMetering(true)
            keys.install(model)
            DispatchQueue.main.async { KeyCommands.releaseFocus() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // The first key-window event lands after onAppear; drop the auto-focused text field once.
            guard !focusSettled else { return }
            focusSettled = true
            DispatchQueue.main.async { KeyCommands.releaseFocus() }
        }
        .onDisappear {
            model.setMetering(false)
            keys.remove()
        }
        .onChange(of: phase) { _, next in
            model.setMetering(next == .active)
        }
    }
}

/// Pads, drums and click on one screen, sized for playing live.
struct ShowView: View {
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: DS.space3) {
                PadSection()
                    .frame(width: geo.size.width * 0.54)
                VStack(spacing: DS.space3) {
                    MetronomeCard()
                    DrumGrid()
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

final class KeyCommands {
    private var monitor: Any?

    func install(_ model: AppModel) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] event in
            guard let model else { return event }
            let blocked: NSEvent.ModifierFlags = [.command, .option, .control]
            guard event.modifierFlags.intersection(blocked).isEmpty else { return event }
            if NSApp.keyWindow?.firstResponder is NSText { return event }
            switch event.keyCode {
            case 123:
                model.step(-1)
                return nil
            case 124:
                model.step(1)
                return nil
            case 49:
                model.toggleMetronome()
                return nil
            default:
                return event
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    static func releaseFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }
}

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

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
