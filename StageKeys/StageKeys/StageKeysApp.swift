import SwiftUI

@main
struct StageKeysApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            PerformView()
                .environment(model)
                .frame(minWidth: 1200, minHeight: 760)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1360, height: 860)
        .windowResizability(.contentMinSize)

        Settings {
            AudioView()
                .environment(model)
                .frame(width: 680, height: 620)
                .background(DS.bgPanel)
                .preferredColorScheme(.dark)
        }
    }
}
