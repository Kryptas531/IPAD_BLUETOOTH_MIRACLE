import SwiftUI

struct RemoteView: View {
    let goToSetup: () -> Void

    @Environment(\.hid) private var hid
    @AppStorage(AppSettings.developerModeKey) private var developerMode = false

    var body: some View {
        if hid.isActive || developerMode {
            DeckPanel(hid: hid)
                .padding(12)
        } else {
            NotConnectedView(icon: "rectangle.grid.2x2", goToSetup: goToSetup)
        }
    }
}

struct DeckPanel: View {
    let hid: HIDInput
    @State private var page = 0
    @State private var showFKeys = false

    private struct DeckKey {
        let label: String
        let key: Keycode?
        let consumer: ConsumerReport?
        let modifiers: KeyboardModifiers

        init(_ label: String, key: Keycode, modifiers: KeyboardModifiers = []) {
            self.label = label
            self.key = key
            consumer = nil
            self.modifiers = modifiers
        }

        init(_ label: String, consumer: ConsumerReport) {
            self.label = label
            key = nil
            self.consumer = consumer
            modifiers = []
        }

        init(_ label: String) {
            self.label = label
            key = nil
            consumer = nil
            modifiers = []
        }
    }

    private var fKeyRows: [[DeckKey]] {
        [
            [DeckKey("F1", key: .f1), DeckKey("F2", key: .f2), DeckKey("F3", key: .f3), DeckKey("F4", key: .f4)],
            [DeckKey("F5", key: .f5), DeckKey("F6", key: .f6), DeckKey("F7", key: .f7), DeckKey("F8", key: .f8)],
            [DeckKey("F9", key: .f9), DeckKey("F10", key: .f10), DeckKey("F11", key: .f11), DeckKey("F12", key: .f12)]
        ]
    }

    private var keys: [[DeckKey]] {
        if showFKeys { return fKeyRows }
        return page == 0
            ? [
                [DeckKey("COPY", key: .c, modifiers: .leftCtrl), DeckKey("PASTE", key: .v, modifiers: .leftCtrl), DeckKey("CUT", key: .x, modifiers: .leftCtrl), DeckKey("UNDO", key: .z, modifiers: .leftCtrl)],
                [DeckKey("TASK MGR", key: .escape, modifiers: [.leftCtrl, .leftShift]), DeckKey("EXPLORER", key: .e, modifiers: .leftGUI), DeckKey("SEARCH", key: .s, modifiers: .leftGUI), DeckKey("DESKTOP", key: .d, modifiers: .leftGUI)],
                [DeckKey("TASK VIEW", key: .tab, modifiers: .leftGUI), DeckKey("DESK ←", key: .leftArrow, modifiers: [.leftGUI, .leftCtrl]), DeckKey("DESK →", key: .rightArrow, modifiers: [.leftGUI, .leftCtrl]), DeckKey("SCREENSHOT", key: .s, modifiers: [.leftGUI, .leftShift])],
                [DeckKey("VOL-", consumer: ConsumerReport(key: .volumeDown)), DeckKey("MUTE", consumer: ConsumerReport(key: .mute)), DeckKey("VOL+", consumer: ConsumerReport(key: .volumeUp)), DeckKey("PLAY/PAUSE", consumer: ConsumerReport(key: .playPause))]
            ]
            : [
                [DeckKey("ESC", key: .escape), DeckKey("TAB", key: .tab), DeckKey("ENTER", key: .return), DeckKey("BACKSPACE", key: .backspace)],
                [DeckKey("INSERT", key: .insert), DeckKey("DELETE", key: .delete), DeckKey("HOME", key: .home), DeckKey("END", key: .end)],
                [DeckKey("PGUP", key: .pageUp), DeckKey("UP", key: .upArrow), DeckKey("PGDN", key: .pageDown), DeckKey("PRTSC", key: .printScreen)],
                [DeckKey("LEFT", key: .leftArrow), DeckKey("DOWN", key: .downArrow), DeckKey("RIGHT", key: .rightArrow), DeckKey("F-KEYS")]
            ]
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("DECK")
                    .font(.headline)
                Spacer()
                Button(showFKeys ? "←" : (page == 0 ? "PAGE 2" : "PAGE 1")) {
                    if showFKeys {
                        showFKeys = false
                    } else {
                        page = page == 0 ? 1 : 0
                    }
                }
                .buttonStyle(.bordered)
            }
            ForEach(Array(keys.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        button(item)
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 24)
                .onEnded { value in
                    if showFKeys {
                        showFKeys = false
                        return
                    }
                    if value.translation.width < -40 {
                        page = 1
                    } else if value.translation.width > 40 {
                        page = 0
                    }
                }
        )
    }

    @ViewBuilder
    private func button(_ item: DeckKey) -> some View {
        if item.key == nil, item.consumer == nil {
            HoldButton(
                onPress: {
                    Haptics.tap()
                    showFKeys = true
                },
                onRelease: {},
                background: { RoundedRectangle(cornerRadius: 8).fill(groupFill) },
                label: { Text(item.label).font(.caption.weight(.medium)) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HoldButton(
                onPress: {
                    if let key = item.key {
                        hid.sendKeyboard(KeyboardReport(modifiers: item.modifiers, keys: [key]))
                    } else if let consumer = item.consumer {
                        hid.sendConsumer(consumer)
                    }
                },
                onRelease: {
                    if item.key != nil {
                        hid.sendKeyboard(.zero)
                    } else {
                        hid.sendConsumer(.zero)
                    }
                },
                background: { RoundedRectangle(cornerRadius: 8).fill(groupFill) },
                label: { Text(item.label).font(.caption.weight(.medium)) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

#if DEBUG
    #Preview {
        RemoteView(goToSetup: {})
    }
#endif
