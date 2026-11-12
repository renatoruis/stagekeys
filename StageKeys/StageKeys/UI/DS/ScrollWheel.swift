import AppKit
import SwiftUI

final class ScrollWheelRouter {
    static let shared = ScrollWheelRouter()

    private var monitor: Any?
    private var owner: UUID?
    private var handler: ((Double) -> Void)?

    func hover(_ id: UUID, inside: Bool, handler: @escaping (Double) -> Void) {
        if inside {
            owner = id
            self.handler = handler
            installIfNeeded()
        } else if owner == id {
            owner = nil
            self.handler = nil
        }
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let handler = self?.handler else { return event }
            let scale: Double = event.hasPreciseScrollingDeltas ? 400 : 40
            handler(Double(event.scrollingDeltaY) / scale)
            return nil
        }
    }
}

final class ValueBox {
    var value: Double = 0
}

struct ContinuousControl: ViewModifier {
    var value: Double
    var defaultValue: Double
    var onCommit: (Double) -> Void
    /// Double-click calls this instead of committing `defaultValue`.
    var onReset: (() -> Void)?
    @State private var box = ValueBox()
    @State private var id = UUID()
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            .focusEffectDisabled()
            .overlay(
                RoundedRectangle(cornerRadius: DS.radiusSM)
                    .strokeBorder(DS.borderFocus.opacity(focused ? 0.5 : 0), lineWidth: 1.5)
                    .padding(-3)
                    .allowsHitTesting(false)
            )
            .onAppear { box.value = value }
            .onChange(of: value) { _, next in box.value = next }
            .onHover { inside in
                ScrollWheelRouter.shared.hover(id, inside: inside) { delta in
                    step(delta)
                }
            }
            .onTapGesture(count: 2) {
                if let onReset { onReset() } else { commit(defaultValue) }
            }
            .onKeyPress(.upArrow, phases: [.down, .repeat]) { press in
                step(press.modifiers.contains(.shift) ? 0.01 : 0.05)
                return .handled
            }
            .onKeyPress(.downArrow, phases: [.down, .repeat]) { press in
                step(press.modifiers.contains(.shift) ? -0.01 : -0.05)
                return .handled
            }
            .onKeyPress(.home) {
                commit(0)
                return .handled
            }
            .onKeyPress(.end) {
                commit(1)
                return .handled
            }
            .accessibilityValue("\(Int((value * 100).rounded())) %")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(0.05)
                case .decrement: step(-0.05)
                @unknown default: break
                }
            }
    }

    private func step(_ delta: Double) {
        commit(box.value + delta)
    }

    private func commit(_ next: Double) {
        let clamped = min(1, max(0, next))
        box.value = clamped
        onCommit(clamped)
    }
}

extension View {
    func continuousControl(value: Double, defaultValue: Double, onCommit: @escaping (Double) -> Void, onReset: (() -> Void)? = nil) -> some View {
        modifier(ContinuousControl(value: value, defaultValue: defaultValue, onCommit: onCommit, onReset: onReset))
    }
}
