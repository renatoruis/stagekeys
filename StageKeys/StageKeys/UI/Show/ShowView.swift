import SwiftUI

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

