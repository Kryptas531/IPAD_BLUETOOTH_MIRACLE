import SwiftUI

let groupFill = Color.secondary.opacity(0.16)
let cellGap: CGFloat = 6

/// fires once on press and once on release; shared by hold-to-send controls
struct PressGesture: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void
    @Binding var pressed: Bool
    @GestureState private var touching = false
    #if os(iOS)
        @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
        )
        .onChange(of: touching) { down in
            if down, !pressed {
                pressed = true; Haptics.tap(); onPress()
            } else if !down, pressed {
                pressed = false; onRelease()
            }
        }
        // GestureState resets on cancellation as well as touch end.
        #if os(iOS)
        .onChange(of: scenePhase) { phase in
            if phase != .active, pressed {
                pressed = false
                onRelease()
            }
        }
        #endif
        .onDisappear {
            if pressed {
                pressed = false
                onRelease()
            }
        }
    }
}

struct HoldButton<Background: View, Label: View>: View {
    let onPress: () -> Void
    let onRelease: () -> Void
    @ViewBuilder var background: () -> Background
    @ViewBuilder var label: () -> Label
    @State private var pressed = false

    var body: some View {
        ZStack {
            background()
            label().foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(pressed ? 0.5 : 1)
        .contentShape(Rectangle())
        .modifier(PressGesture(onPress: onPress, onRelease: onRelease, pressed: $pressed))
    }
}
