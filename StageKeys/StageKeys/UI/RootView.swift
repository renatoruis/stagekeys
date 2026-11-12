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

struct RootView: View {
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
                Group {
                    switch model.tab {
                    case .show: ShowView()
                    case .keys: KeysView()
                    }
                }
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

struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
