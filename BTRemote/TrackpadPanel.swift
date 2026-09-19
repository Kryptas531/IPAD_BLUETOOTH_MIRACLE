import SwiftUI

struct TrackpadPanel: View {
    let hid: HIDInput
    var mode: PadMode = .trackpad

    @AppStorage(AppSettings.touchpadSensitivityKey) private var touchpadSensitivity = AppSettings.defaultPointerSensitivity
    @AppStorage(AppSettings.scrollSensitivityKey) private var scrollSensitivity = AppSettings.defaultScrollSensitivity
    #if os(macOS)
        @State private var dragOffset: CGSize = .zero
    #endif

    var body: some View {
        VStack(spacing: cellGap) {
            HStack(spacing: cellGap) {
                surface
                if mode == .trackpad {
                    scrollColumn.frame(width: 46)
                }
            }
            .frame(maxHeight: .infinity)
            mouseButtonsRow.frame(height: 52)
        }
    }

    private var surface: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(groupFill)
            #if os(iOS)
                if mode == .touch || mode == .deck {
                    VStack(spacing: 8) {
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 44))
                            .foregroundColor(.secondary)
                        Text(L10n.Input.inDevelopment)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } else {
                    TouchpadView(
                        moveSensitivity: touchpadSensitivity,
                        scrollSensitivity: scrollSensitivity,
                        onMove: { hid.move(dx: $0, dy: $1) },
                        onScroll: { hid.scroll($0) },
                        onLeftClick: { Haptics.tap(); hid.click(.left) },
                        onRightClick: { Haptics.tap(); hid.click(.right) },
                        onDragDown: { Haptics.tap(); hid.sendMouse(MouseReport(buttons: .left)) },
                        onDragMove: { hid.sendMouse(MouseReport(buttons: .left, dX: $0, dY: $1)) },
                        onDragUp: { hid.sendMouse(.zero) }
                    )
                }
            #endif
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if os(macOS)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        let dx = HIDInput.clamp((value.translation.width - dragOffset.width) * touchpadSensitivity)
                        let dy = HIDInput.clamp((value.translation.height - dragOffset.height) * touchpadSensitivity)
                        dragOffset = value.translation
                        hid.move(dx: dx, dy: dy)
                    }
                    .onEnded { _ in
                        dragOffset = .zero
                        hid.sendMouse(.zero)
                    }
            )
        #endif
    }

    private var scrollAmount: Int8 {
        max(1, HIDInput.clamp(CGFloat(3 * scrollSensitivity)))
    }

    private var scrollColumn: some View {
        VStack(spacing: cellGap) {
            scrollButton("arrow.up", L10n.Mouse.wheelUp, scrollAmount)
            scrollButton("arrow.down", L10n.Mouse.wheelDown, -scrollAmount)
        }
    }

    private var mouseButtonsRow: some View {
        HStack(spacing: cellGap) {
            mouseButton(.left, icon: "cursorarrow.click", L10n.Mouse.leftButton)
            mouseButton(.middle, icon: "smallcircle.filled.circle", L10n.Mouse.middleButton)
            mouseButton(.right, icon: "cursorarrow.click.2", L10n.Mouse.rightButton)
        }
    }

    private func mouseButton(_ button: MouseButtons, icon: String, _ label: LocalizedStringKey) -> some View {
        HoldButton(
            onPress: { Haptics.tap(); hid.sendMouse(MouseReport(buttons: button)) },
            onRelease: { hid.sendMouse(.zero) },
            background: { RoundedRectangle(cornerRadius: 12).fill(groupFill) },
            label: { Image(systemName: icon).font(.body) }
        )
        .accessibilityLabel(label)
    }

    private func scrollButton(_ icon: String, _ label: LocalizedStringKey, _ wheel: Int8) -> some View {
        HoldButton(
            onPress: { Haptics.tap(); hid.scroll(wheel) },
            onRelease: {},
            background: { RoundedRectangle(cornerRadius: 12).fill(groupFill) },
            label: { Image(systemName: icon).font(.body) }
        )
        .accessibilityLabel(label)
    }
}
