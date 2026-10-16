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
    @State private var focusSettled = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            KeysView()
                .padding(DS.space3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .ignoresSafeArea(.container, edges: .top)
        .background(DS.bgApp.onTapGesture { KeyCommands.releaseFocus() })
        .environment(\.meteringActive, phase == .active)
        .onAppear {
            model.setMetering(true)
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
        }
        .onChange(of: phase) { _, next in
            model.setMetering(next == .active)
        }
    }
}

enum KeyCommands {
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
