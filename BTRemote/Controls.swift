import SwiftUI

let groupFill = Color.secondary.opacity(0.16)
let cellGap: CGFloat = 6

/// fires once on press and once on release; shared by hold-to-send controls
struct PressGesture: ViewModifier {
    let onPress: () -> Void
    let onRelease: () -> Void
    @Binding var pressed: Bool
    #if os(iOS)
        @Environment(\.scenePhase) private var scenePhase
    #endif

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !pressed {
                        pressed = true
                        Haptics.tap()
                        onPress()
                    }
                }
                .onEnded { _ in
                    // SPEC §7.3 C: if a teardown (view exit / app inactivity) already
                    // released, `pressed` is false and must not fire a duplicate
                    // non-neutral press through `onRelease` again.
                    if pressed {
                        pressed = false
                        onRelease()
                    }
                }
        )
        // SPEC §7.3 C: release the held state on app inactivity (a touch cancellation
        // arrives through `onEnded`); reactivation must not resume a held press — the
        // next touch starts a fresh press.
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
