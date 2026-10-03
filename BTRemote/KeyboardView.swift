import SwiftUI

#if os(iOS)
    import UIKit
#endif

private let keyHeight: CGFloat = 44

/// Touch-to-mouse surface mode on the Windows input screen.
enum PadMode: String {
    case game
    case trackpad
    case touch
    case deck
    /// Single Windows-input surface (trackpad + shortcuts + text entry) that replaced the
    /// separate TRACKPAD and DECK modes on iPad (SPEC §7.1 A).
    case control

    /// iPad uses the unified CONTROL surface; macOS keeps the upstream trackpad surface.
    static var defaultMode: PadMode {
        #if os(iOS)
            .control
        #else
            .trackpad
        #endif
    }

    /// SPEC §7.1 A upgrade rule: a previously persisted TRACKPAD or DECK mode selection migrates
    /// to CONTROL on the first launch after this change, so an existing install never opens into
    /// a removed mode. GAME, TOUCH and every other persisted setting are preserved unchanged.
    static func migratePersistedSelection() {
        guard let stored = PadMode(rawValue: UserDefaults.standard.string(forKey: AppSettings.padModeKey) ?? ""),
              stored == .trackpad || stored == .deck
        else { return }
        UserDefaults.standard.set(PadMode.control.rawValue, forKey: AppSettings.padModeKey)
    }
}

/// One of the three mutually exclusive temporary CONTROL surfaces (SPEC §7.1 C/E).
/// `nil` means no surface is open and the pad owns the whole surface.
enum AppSurface {
    case textEntry
    case extraKeys
    case moreShortcuts
}

struct KeyboardView: View {
    let goToSetup: () -> Void
    var openSettings: () -> Void = {}

    @Environment(\.hid) private var hid
    @AppStorage(AppSettings.developerModeKey) private var developerMode = false
    @AppStorage(AppSettings.liveTypingKey) private var liveTyping = true
    @AppStorage(AppSettings.padModeKey) private var padMode = PadMode.defaultMode
    @AppStorage(AppSettings.touchpadSensitivityKey) private var touchpadSensitivity = AppSettings.defaultPointerSensitivity
    @AppStorage(AppSettings.gameInputModeKey) private var gameInputMode = GameInputMode.touch
    @AppStorage(AppSettings.gyroSensitivityKey) private var gyroSensitivity = AppSettings.defaultGyroSensitivity
    @EnvironmentObject private var directInput: DirectInputController
    @EnvironmentObject private var lowEnergy: HIDPeripheral
    #if os(iOS)
        @StateObject private var gyro = GyroAimController()
        @StateObject private var windows = WindowsForegroundClient.shared
        @Environment(\.scenePhase) private var scenePhase
        /// SPEC §7.3 C: the root installs a register closure `(callback?) -> Void`:
        /// this view registers `releasePCInput` on appear (so the root can invoke it
        /// synchronously BEFORE switching target) and unregisters (passes `nil`) on
        /// disappear after teardown. The root guards the registered callback by session
        /// token, so an old view's unregister cannot clear the new session's callback.
        var registerPCRelease: (((() -> Void)?) -> Void)? = nil
    #endif
    @State private var text = ""
    @State private var sent = ""
    @State private var resetting = false
    @State private var gameChromeVisible = true
    @State private var showKeyboard = false
    /// SPEC §7.1 C/E: at most one of "Text entry" / "Extra keys" / "More shortcuts" is open.
    @State private var surface: AppSurface? = nil
    @State private var showDirectInputControls = false
    @State private var mods: KeyboardModifiers = []
    @State private var held: KeyboardModifiers = []
    @FocusState private var focused: Bool
    @StateObject private var typist = KeyTypist()

    var body: some View {
        if hid.isActive || developerMode {
            editor
        } else {
            NotConnectedView(icon: "keyboard", goToSetup: goToSetup)
        }
    }

    private var editor: some View {
        GeometryReader { geo in
            if padMode == .control {
                controlSurface(landscape: geo.size.width > geo.size.height)
            } else if geo.size.width > geo.size.height {
            if padMode == .game {
                ZStack(alignment: .top) {
                    #if os(iOS)
                        if gameInputMode == .racing {
                            // SPEC §5.2 I: the free racing surface uses raw UIKit touches.
                            // It is not the §7.1 CONTROL pad and not the relative-mouse
                            // path, and it covers the whole GAME surface behind the racing
                            // controls, so a thumb drag can drive RX at the same time as
                            // steering, the pedals and the ability buttons.
                            RacingSurfaceView(
                                onTouchBegan: { gyro.beginRacingTouch(at: $0) },
                                onTouchMoved: { gyro.moveRacingTouch(to: $0) },
                                onTouchEnded: { gyro.endRacingTouch() }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            TrackpadPanel(
                                hid: hid, mode: padMode, metrics: lowEnergy.performanceMetrics,
                                // SPEC §5.2 H: racing never reuses the relative-mouse path,
                                // so touch movement is not sent in RACING; touch and hybrid
                                // keep the §5.1 behaviour exactly.
                                touchMovementEnabled: gameInputMode == .touch || gameInputMode == .hybrid
                            )
                        }
                    #else
                        // SPEC §5.2: RACING is an iPad-only nested GAME source; the macOS
                        // build keeps the pre-§5.2 surface byte-for-byte unchanged.
                        TrackpadPanel(
                            hid: hid, mode: padMode, metrics: lowEnergy.performanceMetrics,
                            touchMovementEnabled: gameInputMode != .gyro
                        )
                    #endif
                    if gameChromeVisible {
                        VStack(spacing: 4) {
                            controlBar
                            Spacer()
                            bottomStrip
                            #if os(iOS)
                                if gameInputMode == .racing {
                                    // SPEC §5.2 J: brake/gas and three ability buttons.
                                    racingControls
                                }
                            #endif
                            HStack(spacing: 6) {
                                Text(L10n.Settings.trackingSpeed).font(.caption2)
                                Slider(value: $touchpadSensitivity, in: AppSettings.pointerSensitivityRange)
                                    .frame(maxWidth: 180)
                                Toggle(isOn: $developerMode) {
                                    Text(L10n.Settings.developerMode).font(.caption2)
                                }
                                .fixedSize()
                            }
                            #if os(iOS)
                                HStack(spacing: 6) {
                                    // SPEC §5.1 I: GAME input source, gyro sensitivity, recenter.
                                    // SPEC §5.2 G: RACING is nested inside GAME, not a fourth
                                    // top-level mode; touch/gyro/hybrid keep their existing
                                    // behaviour, labels and defaults unchanged.
                                    Picker(L10n.Input.source, selection: $gameInputMode) {
                                        Text(L10n.Input.touch).tag(GameInputMode.touch)
                                        Text(L10n.Input.gyro).tag(GameInputMode.gyro)
                                        Text(L10n.Input.hybrid).tag(GameInputMode.hybrid)
                                        Text(L10n.Input.racing).tag(GameInputMode.racing)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(maxWidth: 260)
                                    Text(L10n.Settings.gyroSensitivity).font(.caption2)
                                    Slider(value: $gyroSensitivity, in: AppSettings.gyroSensitivityRange)
                                        .frame(maxWidth: 180)
                                    // SPEC §5.2 J: in RACING the re-baseline control lives in
                                    // the always-visible racing row, so it is not duplicated here.
                                    if gameInputMode != .racing {
                                        Button(L10n.Action.recenter) {
                                            Haptics.tap()
                                            gyro.recenter()
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                    if gameInputMode != .touch, !gyro.isAvailable {
                                        Text(L10n.Input.motionUnavailable)
                                            .font(.caption2)
                                            .foregroundColor(.orange)
                                    }
                                }
                            #endif
                            if showKeyboard {
                                inputField
                                keyPanel
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        // The GAME chrome spans the whole screen (Spacer between the top bar and
                        // the bottom strip), so its material fill must not take part in hit
                        // testing: a full-screen material layer on top of TrackpadPanel swallows
                        // the touches used by the GAME touch/hybrid input source (SPEC §5.1 B),
                        // which is why movement only worked after the chrome auto-hid.
                        // The decorative layer is therefore explicitly non-interactive; the
                        // buttons/picker/sliders/keyboard controls are siblings drawn above it
                        // and stay interactive.
                        .background {
                            Rectangle()
                                .fill(.thinMaterial)
                                .opacity(0.88)
                                .allowsHitTesting(false)
                        }
                    } else {
                        // SPEC §5.2 J: the GAME chrome auto-hides after 3 s, but the racing pedals, the
                        // three ability buttons and RECENTER stay on the play surface, so the
                        // player can always reach them while RACING is selected.
                        VStack(spacing: 4) {
                            Button("•••") {
                                gameChromeVisible = true
                            }
                            .font(.caption2)
                            .buttonStyle(.bordered)
                            .padding(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            #if os(iOS)
                                if gameInputMode == .racing {
                                    // SPEC §5.2 J: brake/gas, three ability buttons and RECENTER.
                                    racingControls
                                }
                            #endif
                        }
                    }
                }
            } else {
                ZStack(alignment: .bottom) {
                    VStack(spacing: 4) {
                        controlBar
                            .padding(.horizontal, 8)
                        TrackpadPanel(hid: hid, mode: padMode, metrics: lowEnergy.performanceMetrics)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        bottomStrip
                    }
                    if showKeyboard {
                        VStack(spacing: 6) {
                            inputField
                            keyPanel
                        }
                        .padding(8)
                        .background(.thinMaterial.opacity(0.94))
                    }
                }
            }
        } else {
                VStack(spacing: 12) {
                    controlBar
                    inputField
                    keyPanel
                    TrackpadPanel(hid: hid, mode: padMode, metrics: lowEnergy.performanceMetrics)
                        .frame(maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .padding()
        .onChange(of: liveTyping) { _ in clear() }
        .task(id: padMode) {
            gameChromeVisible = true
            // SPEC §7.1 C/E: entering a mode starts with every temporary surface closed.
            surface = nil
            #if os(iOS)
                configureGyro()
            #endif
            guard padMode == .game else { return }
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if !Task.isCancelled { gameChromeVisible = false }
        }
        #if os(iOS)
            .onChange(of: gameInputMode) { _ in configureGyro() }
            .onChange(of: gyroSensitivity) { _ in applyGyroSensitivity() }
            // SPEC §5.1 G: becoming active again re-baselines the motion source.
            // SPEC §5.2 L: resigning active, backgrounding or suspension stops the motion
            // source and neutralizes every racing source, so Windows is never left with a
            // stuck axis, trigger or button and no in-flight sample can write LX afterwards.
            // SPEC §7.3 C: the same exit/inactive path also cancels every PC input session
            // artifact (typing queue, arrow repeater, Direct Input capture, held state).
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    configureGyro()
                } else {
                    releasePCInput()
                }
            }
            // SPEC §5.2 L: the same neutralization covers the link itself. When the connected
            // central disappears (or the HID service goes away) the racing sources are stopped
            // and released, so a still-held brake/gas, ability button or RX is never sent and
            // cached into a disconnected host, and never survives locally into the next session.
            // A reconnect restarts the same single motion pipeline and re-baselines it.
            // SPEC §7.3 C: the link-gone path clears local/pending state only; the next
            // session starts neutral and never replays old presses, text or repeats.
            .onChange(of: lowEnergy.connectedCentrals) { centrals in
                if centrals.isEmpty {
                    releasePCInput()
                } else {
                    configureGyro()
                }
            }
            // SPEC §5.2 L: the gamepad report has its own subscribers, tracked separately
            // because every report characteristic shares the 0x2A4D UUID. If the host stops
            // subscribing to the gamepad while it still subscribes to keyboard/mouse, the
            // central stays connected, so racing must still be stopped and neutralized here;
            // otherwise the next gyro sample would send and cache a non-neutral state into a
            // host that has no gamepad. A host that (re)subscribes while RACING is selected
            // restarts the same single motion pipeline and re-baselines it.
            .onChange(of: lowEnergy.gamepadSubscribedCentrals) { centrals in
                if centrals.isEmpty {
                    releasePCInput()
                } else if gameInputMode == .racing {
                    configureGyro()
                }
            }
            .onChange(of: lowEnergy.isHIDServiceAdded) { added in
                if added {
                    configureGyro()
                } else {
                    releasePCInput()
                }
            }
            // SPEC §7.3 C: register the PC session release on appear so the root can
            // invoke it synchronously before switching target; on disappear run the
            // teardown first, then unregister so an old view cannot clear the next
            // session's callback.
            .onAppear {
                registerPCRelease?({ self.releasePCInput() })
            }
            // SPEC §5.2 L / §7.3 C: the view disappearing also stops and neutralizes.
            .onDisappear {
                releasePCInput()
                registerPCRelease?(nil)
            }
            // SPEC §7.1 E: opening the "Text entry" surface and focusing its field are different
            // events. Only tapping/focusing the field makes Text entry the visible surface.
            // CONTROL keeps the keyboard safe area so the field, Send and Clear stay visible and
            // usable above the iOS keyboard; GAME/macOS keep the previous behaviour.
            .onChange(of: focused) { isFocused in
                guard padMode == .control else { return }
                if isFocused {
                    surface = .textEntry
                } else if surface == .textEntry {
                    surface = nil
                }
            }
            .ignoresSafeArea(.keyboard, edges: padMode == .control ? [] : .bottom)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { accessoryBar }
            }
        #endif
    }

    // MARK: - §7.1 unified CONTROL surface

    /// The live pad stays the visual and interactive centre in both orientations; the compact
    /// always-visible controls only take their own strip at the outer edges (landscape) or above
    /// and below (portrait), so the pad keeps the dominant share of the surface (SPEC §7.1 B/F).
    @ViewBuilder
    private func controlSurface(landscape: Bool) -> some View {
        // SPEC §7.2: when the Windows helper reports a known application, render that app's
        // configured action set (AppLayouts) with the existing KeyCap handling; otherwise keep the
        // generic §7.1 quick set (unknown token / no link / disconnect -> generic fallback).
        // The action set may be longer than the generic 8-key quick set (VS Code has 11 actions),
        // so split the rendered keys into two halves around the central pad instead of a fixed
        // prefix(4)+suffix(4); a fixed 4+4 silently dropped any key beyond the eighth. For the
        // 8-key generic set the split stays 4+4, so the generic layout is unchanged.
        let keys = appActionKeys
        let split = (keys.count + 1) / 2
        let leadingKeys = Array(keys.prefix(split))
        let trailingKeys = Array(keys.dropFirst(split))
        if landscape {
            VStack(spacing: 4) {
                controlBar
                    .padding(.horizontal, 8)
                HStack(spacing: 4) {
                    keyColumn(leadingKeys)
                    padSurface
                    keyColumn(trailingKeys)
                }
                entryControls
            }
        } else {
            VStack(spacing: 4) {
                controlBar
                keyRow(leadingKeys)
                padSurface
                keyRow(trailingKeys)
                entryControls
            }
        }
    }

    /// SPEC §7.2: the dynamic action set for the currently-reported Windows application, or the
    /// SPEC §7.2: the dynamic action set for the currently-reported Windows application, or the
    /// generic §7.1 quick set when no application is known (client disconnected / unknown identity).
    /// The returned keycaps are rendered with the unchanged `keyRow`/`keyColumn`/`keyCapButton`
    /// dispatch, so no new keycodes or HID reports are introduced.
    private var appActionKeys: [KeyCap] {
        #if os(iOS)
            return AppLayouts.set(for: windows.identity)?.keys ?? quickKeys
        #else
            return quickKeys
        #endif
    }

    /// The live trackpad with the single open temporary surface drawn over it (SPEC §7.1 C/E).
    private var padSurface: some View {
        ZStack(alignment: .bottom) {
            TrackpadPanel(hid: hid, mode: .control, metrics: lowEnergy.performanceMetrics)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            surfaceOverlay
        }
    }

    /// SPEC §7.1 B: the always-visible quick set contains only these existing DECK actions and the
    /// reports they already send — no new keycodes and no new reports. `ALT+TAB` and `WIN+L` are
    /// deliberately absent; they are combined keycaps belonging to the "Extra keys" panel (§7.1 E).
    private var quickKeys: [KeyCap] {
        [
            KeyCap(.text(L10n.Deck.copyKey), L10n.Deck.copyKey, .combo(.c, .leftCtrl)),
            KeyCap(.text(L10n.Deck.paste), L10n.Deck.paste, .combo(.v, .leftCtrl)),
            KeyCap(.text(L10n.Deck.cut), L10n.Deck.cut, .combo(.x, .leftCtrl)),
            KeyCap(.text(L10n.Deck.undo), L10n.Deck.undo, .combo(.z, .leftCtrl)),
            KeyCap(.text(L10n.Deck.taskView), L10n.Deck.taskView, .combo(.tab, .leftGUI)),
            KeyCap(.text(L10n.Deck.screenshot), L10n.Deck.screenshot, .combo(.s, [.leftGUI, .leftShift])),
            KeyCap(.text(L10n.Deck.search), L10n.Deck.search, .combo(.s, .leftGUI)),
            KeyCap(.text(L10n.Deck.playPause), L10n.Deck.playPause, .consumer(.playPause)),
        ]
    }

    /// The three distinct entry controls of SPEC §7.1 E: "More shortcuts" (the full DECK panel),
    /// "Extra keys" (the custom keycap panel) and "Text entry" (the input field). They are
    /// mutually exclusive: opening one closes the others.
    private var entryControls: some View {
        HStack(spacing: 4) {
            entryButton(L10n.Input.moreShortcuts, tag: .moreShortcuts)
            entryButton(L10n.Input.extraKeys, tag: .extraKeys)
            entryButton(L10n.Input.textEntry, tag: .textEntry)
        }
    }

    private func entryButton(_ label: LocalizedStringKey, tag: AppSurface) -> some View {
        Button {
            Haptics.tap()
            toggleSurface(tag)
        } label: {
            Text(label)
                .font(.footnote)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(surface == tag ? Color.accentColor : groupFill))
                .foregroundColor(surface == tag ? .white : .primary)
        }
        .buttonStyle(.plain)
    }

    /// SPEC §7.1 C/E: one single temporary panel per entry control. Only the control hit areas are
    /// interactive; the decorative material behind them explicitly opts out of hit testing so the
    /// pad's free surface stays touchable (SPEC §7.1 D).
    @ViewBuilder
    private var surfaceOverlay: some View {
        if let surface {
            surfacePanel(surface)
        }
    }

    @ViewBuilder
    private func surfacePanel(_ surface: AppSurface) -> some View {
        switch surface {
        case .textEntry:
            inputField
                .padding(8)
                .background { nonInteractiveSurface }
        case .extraKeys:
            VStack(spacing: 6) {
                keyPanel
                bottomStrip
            }
            .padding(8)
            .background { nonInteractiveSurface }
        case .moreShortcuts:
            DeckPanel(hid: hid)
                .padding(8)
                .background { nonInteractiveSurface }
        }
    }

    /// Decorative material behind a temporary surface; never participates in hit testing.
    private var nonInteractiveSurface: some View {
        Rectangle()
            .fill(.thinMaterial)
            .opacity(0.94)
            .allowsHitTesting(false)
    }

    /// SPEC §7.1 C/E: opening a surface closes the other two; re-tapping the same entry control
    /// closes it. Opening "Extra keys"/"More shortcuts" clears field focus so the native iOS
    /// keyboard is never shown next to a custom panel, and opening "Text entry" alone never forces
    /// focus into the field. Closing "Text entry" clears focus too, so the native iOS keyboard is
    /// dismissed together with the surface.
    private func toggleSurface(_ target: AppSurface) {
        if surface == target {
            surface = nil
            if target == .textEntry { focused = false }
            return
        }
        surface = target
        if target != .textEntry { focused = false }
    }

    /// Mirrors `keyRow` vertically: the landscape quick set sits in narrow columns at the outer
    /// edges so the pad keeps the whole middle of the screen.
    private func keyColumn(_ keys: [KeyCap]) -> some View {
        VStack(spacing: cellGap) {
            ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                keyCapButton(key)
                    .frame(width: 76, height: keyHeight)
            }
        }
    }

    #if os(iOS)
        /// Apply the slider value to the running source only. Changing sensitivity must
        /// not restart CoreMotion or clear the attitude baseline, otherwise moving the
        /// slider re-baselines the gyro mid-use and loses deltas (SPEC §5.1 C/G).
        @MainActor private func applyGyroSensitivity() {
            gyro.sensitivity = gyroSensitivity
        }

        /// Wire the gyro source to the existing relative-mouse report path and start or stop
        /// it according to the selected GAME input source (SPEC §5.1 B/G). SPEC §5.2 G/H:
        /// RACING reuses the same single motion pipeline with the absolute baseline
        /// mapping; `sensitivity` stays the §5.1 mouse setting and racing does not use it.
        @MainActor private func configureGyro() {
            gyro.sensitivity = gyroSensitivity
            // SPEC §5.2 L: every exit from RACING (to touch, gyro or hybrid) must send the neutral
            // gamepad report BEFORE the next source is configured. `start` resets the in-memory
            // state without sending it, so without this a held brake/gas, an ability button or
            // a deflected stick would stay latched on Windows. RACING -> touch and leaving GAME
            // are covered by `stop()`, which neutralizes as well.
            if gyro.mode == .racing, gameInputMode != .racing {
                gyro.neutralizeRacing()
            }
            gyro.mode = gameInputMode
            guard padMode == .game else {
                gyro.stop()
                return
            }
            if gameInputMode == .touch {
                gyro.stop()
            } else {
                gyro.start(hid)
            }
        }

        /// SPEC §7.3 C: the single named teardown for every PC exit path (view disappear,
        /// app inactivity, or the link going away). Before any next session begins it cancels
        /// the in-flight typing queue and arrow repeater, releases everything bound to the old
        /// session (`directInput.stop()` detaches the physical keyboard/mouse; `typist.cancel()`
        /// clears queue + captured send closure), neutralizes held/sticky modifiers, keyboard,
        /// mouse and gamepad over the still-existing link, and resets temporary text/focus and
        /// local state. Old presses, text or repeats are never replayed; the next session
        /// starts neutral. This changes no BLE pairing or transport behavior.
        @MainActor private func releasePCInput() {
            typist.cancel()
            gyro.stop()
            directInput.stop()
            mods = []
            held = []
            if !text.isEmpty {
                resetting = true
                text = ""
            }
            sent = ""
            focused = false
            surface = nil
            showKeyboard = false
            showDirectInputControls = false
            if hid.isActive {
                hid.sendKeyboard(.zero)
                hid.sendMouse(.zero)
            }
        }

        /// SPEC §5.2 J/L: the racing controls — brake (LT), gas (RT), three ability buttons
        /// (A, B, X) and RECENTER. All momentary: press asserts, release clears, and each
        /// control only clears its own field, so several can be held at the same time. They
        /// reuse the existing `HoldButton`/`PressGesture` affordance unchanged. This row is
        /// NOT part of the auto-hiding GAME chrome: it stays visible and tappable on the
        /// racing surface for the whole session, and every target is 44 pt high (the same
        /// height as the §5/§7.1 keyboard keys) so it stays usable in landscape.
        private var racingControls: some View {
            HStack(spacing: 6) {
                racingTrigger(L10n.Input.brake, .brake)
                racingTrigger(L10n.Input.gas, .gas)
                racingButton(L10n.Input.boost, .a)
                racingButton(L10n.Input.ability1, .b)
                racingButton(L10n.Input.ability2, .x)
                Button {
                    Haptics.tap()
                    gyro.recenter()
                } label: {
                    Text(L10n.Action.recenter).font(.footnote).lineLimit(1).minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 6).fill(groupFill))
                }
                .buttonStyle(.plain)
            }
            .frame(height: 44)
        }

        private func racingTrigger(_ label: LocalizedStringKey, _ trigger: GamepadTrigger) -> some View {
            HoldButton(
                onPress: {
                    Haptics.tap()
                    gyro.setRacingTrigger(trigger, pressed: true)
                },
                onRelease: {
                    gyro.setRacingTrigger(trigger, pressed: false)
                },
                background: { RoundedRectangle(cornerRadius: 6).fill(groupFill) },
                label: { Text(label).font(.footnote).lineLimit(1).minimumScaleFactor(0.5) }
            )
            .accessibilityLabel(label)
        }

        private func racingButton(_ label: LocalizedStringKey, _ button: GamepadButtons) -> some View {
            HoldButton(
                onPress: {
                    Haptics.tap()
                    gyro.setRacingButton(button, pressed: true)
                },
                onRelease: {
                    gyro.setRacingButton(button, pressed: false)
                },
                background: { RoundedRectangle(cornerRadius: 6).fill(groupFill) },
                label: { Text(label).font(.footnote).lineLimit(1).minimumScaleFactor(0.5) }
            )
            .accessibilityLabel(label)
        }

    #endif

    // Compact row: input-surface mode switcher + Direct Input release + connection status.
    private var controlBar: some View {
        HStack(spacing: 8) {
            modeSwitcher
            if directInput.isCapturing {
                Button(L10n.DirectInput.release) {
                    Haptics.tap()
                    directInput.stop()
                }
                .buttonStyle(.bordered)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                // SPEC §7: tiny indicators only — Bluetooth radio waves = BLE/HID link up,
                // hand-in-rectangle = HID service ready, keyboard = Direct Input capturing.
                statusDot("dot.radiowaves.left.and.right", on: hid.isConnected)
                statusDot("rectangle.and.hand.point.up.left", on: hid.isActive)
                #if os(iOS)
                    // SPEC §7: Direct Input = compact status icon; long-press the
                    // keyboard indicator to reveal capture/release controls.
                    statusDot("keyboard", on: directInput.isCapturing)
                        .padding(4)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            Haptics.tap()
                            showDirectInputControls = true
                        }
                        // Enable is offered only while nothing is captured; Release only while it is.
                        // With no external keyboard/trackpad detected the dialog explains why
                        // Enable would be unavailable.
                        .confirmationDialog(
                            directInput.hasInputDevice
                                ? L10n.DirectInput.section
                                : L10n.DirectInput.iosNoDevice,
                            isPresented: $showDirectInputControls,
                            titleVisibility: .visible
                        ) {
                            if directInput.isCapturing {
                                Button(L10n.DirectInput.release) {
                                    Haptics.tap()
                                    directInput.stop()
                                }
                            } else {
                                Button(L10n.DirectInput.enable) {
                                    Haptics.tap()
                                    directInput.start(hid)
                                }
                                .disabled(!directInput.hasInputDevice)
                            }
                            Button(L10n.Action.notNow, role: .cancel) {}
                        }
                #else
                    statusDot("keyboard", on: directInput.isCapturing)
                #endif
            }
            #if os(iOS)
                // Single top-bar options control: Settings and the Connection/Setup route.
                // SetupView keeps the live connection state and connected-device names, so the
                // bar itself stays free of any permanent status panel.
                Menu {
                    Button {
                        Haptics.tap()
                        openSettings()
                    } label: {
                        Label(L10n.Action.settings, systemImage: "slider.horizontal.3")
                    }
                    Button {
                        Haptics.tap()
                        goToSetup()
                    } label: {
                        Label(L10n.Remote.openSetup, systemImage: "network")
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(groupFill))
                        .contentShape(Rectangle())
                }
                .accessibilityLabel(L10n.Remote.menu)
            #endif
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            modeButton(L10n.Input.game, tag: .game)
            #if os(iOS)
                // SPEC §7.1 A: on iPad there is no separate TRACKPAD and no separate DECK mode.
                modeButton(L10n.Input.control, tag: .control)
                modeButton(L10n.Input.touch, tag: .touch, disabled: true)
            #else
                modeButton(L10n.Input.trackpad, tag: .trackpad)
                modeButton(L10n.Input.touch, tag: .touch, disabled: true)
                modeButton(L10n.Input.deck, tag: .deck)
            #endif
        }
    }

    private func modeButton(_ label: LocalizedStringKey, tag: PadMode, disabled: Bool = false) -> some View {
        Button {
            Haptics.tap()
            padMode = tag
        } label: {
            Text(label)
                .font(.footnote)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(padMode == tag ? Color.accentColor : groupFill))
                .foregroundColor(padMode == tag ? .white : .primary)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func statusDot(_ symbol: String, on: Bool) -> some View {
        Image(systemName: symbol)
            .font(.caption)
            .foregroundStyle(on ? Color.green : Color.secondary)
            .accessibilityValue(on ? "Connected" : "Disconnected")
    }

    private var bottomStrip: some View {
        HStack(spacing: 6) {
            keyCapButton(KeyCap(.text(L10n.Keyboard.ctrl), L10n.Keyboard.ctrl, .modifier(.leftCtrl)))
            keyCapButton(KeyCap(.text(L10n.Keyboard.win), L10n.Keyboard.win, .modifier(.leftGUI)))
            keyCapButton(KeyCap(.text(L10n.Keyboard.alt), L10n.Keyboard.alt, .modifier(.leftAlt)))
            keyCapButton(KeyCap(.text(L10n.Keyboard.shift), L10n.Keyboard.shift, .modifier(.leftShift)))
            Spacer(minLength: 8)
            keyCapButton(KeyCap(.text(L10n.Keyboard.esc), L10n.Keyboard.esc, .key(.escape)))
            keyCapButton(KeyCap(.text(L10n.Keyboard.tab), L10n.Keyboard.tab, .key(.tab)))
            keyCapButton(KeyCap(.text(L10n.Keyboard.enter), L10n.Keyboard.enter, .key(.return)))
            Button {
                Haptics.tap()
                if padMode == .control {
                    // SPEC §7.1 E: this is the explicit close/toggle affordance inside the
                    // temporary "Extra keys" panel. Toggling Extra keys must never focus the
                    // text field and must never summon the native iOS keyboard.
                    toggleSurface(.extraKeys)
                } else {
                    showKeyboard.toggle()
                    if showKeyboard { focused = true }
                }
            } label: {
                if padMode == .control {
                    Label(L10n.Input.extraKeys, systemImage: "keyboard")
                        .font(.caption)
                        .padding(.horizontal, 6)
                } else {
                    Image(systemName: "keyboard")
                        .font(.caption)
                        .padding(.horizontal, 6)
                }
            }
        }
        .frame(height: 34)
    }

    @ViewBuilder
    private var accessoryBar: some View {
        accessoryKey("escape", L10n.Keyboard.esc) { press(.escape) }
        accessoryKey("arrow.right.to.line", L10n.Keyboard.tab) { press(.tab) }
        Button {
            Haptics.tap()
            toggle(.leftCtrl)
        } label: {
            Text(L10n.Keyboard.ctrl)
                .foregroundStyle(mods.contains(.leftCtrl) ? Color.accentColor : Color.primary)
        }
        .accessibilityLabel(L10n.Keyboard.ctrl)
        ArrowPad { press($0) }
        accessoryKey("delete.left", L10n.Keyboard.backspace) { press(.backspace) }
        Spacer()
        Button(L10n.Keyboard.done) { focused = false }
    }

    private func accessoryKey(_ symbol: String, _ label: LocalizedStringKey, _ tap: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            tap()
        } label: {
            Image(systemName: symbol).foregroundStyle(Color.primary)
        }
        .accessibilityLabel(label)
    }

    private var inputField: some View {
        HStack(spacing: 8) {
            TextField(L10n.Keyboard.prompt, text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .autocorrectionDisabled()
            #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.asciiCapable)
            #endif
                .onChange(of: text) { handleChange($0) }
                .onSubmit { liveTyping ? press(.return) : send() }
            if !liveTyping {
                Button(L10n.Keyboard.send) { send() }
                    .buttonStyle(.borderedProminent)
                    .disabled(text.isEmpty)
            }
            Button(L10n.Keyboard.clear) { clear() }
                .buttonStyle(.bordered)
        }
    }

    private var keyPanel: some View {
        VStack(spacing: 6) {
            keyRow(fRow)
            keyRow(row1)
            keyRow(row2)
            keyRow(row3)
            keyRow(row4)
            keyRow(row5)
        }
    }

    private func keyRow(_ keys: [KeyCap]) -> some View {
        GeometryReader { geo in
            let total = keys.reduce(0) { $0 + $1.weight }
            let gaps = 6 * CGFloat(max(keys.count - 1, 0))
            let unit = max(0, (geo.size.width - gaps) / total)
            HStack(spacing: 6) {
                ForEach(Array(keys.enumerated()), id: \.offset) { _, key in
                    keyCapButton(key).frame(width: unit * key.weight)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: keyHeight)
    }

    @ViewBuilder
    private func keyCapButton(_ key: KeyCap) -> some View {
        let armed: Bool = {
            if case let .modifier(mod) = key.action { return mods.contains(mod) }
            return false
        }()
        // SPEC §7.2 F: resolve a data-configured action's target once here (pure read + parse, no
        // HID side effects at render time) so an unconfigured action renders as a disabled keycap
        // and a configured one reuses the existing `HIDInput.keyReports` + `KeyTypist` send path.
        let dataReports: [KeyboardReport] = {
            if case let .layout(action) = key.action {
                return UserTargets.keyReports(for: action)
            }
            return []
        }()
        switch key.action {
        case let .key(code):
            Button {
                Haptics.tap()
                press(code)
            } label: {
                keyLabel(key.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(armed ? Color.accentColor : groupFill))
                    .foregroundColor(armed ? .white : .primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key.accessibility)
        case let .modifier(mod):
            HoldButton(
                onPress: {
                    Haptics.tap()
                    held.insert(mod)
                    typist.send = hid.sendKeyboard
                    typist.enqueue([KeyboardReport(modifiers: held, keys: [])])
                },
                onRelease: {
                    held.subtract(mod)
                    typist.send = hid.sendKeyboard
                    typist.enqueue([KeyboardReport(modifiers: held, keys: [])])
                },
                background: { RoundedRectangle(cornerRadius: 6).fill(armed ? Color.accentColor : groupFill) },
                label: { keyLabel(key.label).foregroundColor(armed ? Color.white : Color.primary) }
            )
            .accessibilityLabel(key.accessibility)
        case let .combo(code, mod):
            Button {
                Haptics.tap()
                typist.send = hid.sendKeyboard
                typist.enqueue(HIDInput.keyReports(for: code, modifiers: mod))
            } label: {
                keyLabel(key.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(groupFill))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key.accessibility)
        case .layout:
            // SPEC §7.2 F: the concrete chord, chord sequence or typed text a user-configured
            // action sends is data from the layout document, never hard-coded. Pressing the keycap
            // sends exactly the existing HID key reports for that target through the existing
            // `KeyTypist` pacing. An unconfigured or unparseable target sends nothing and the
            // keycap is shown disabled.
            Button {
                Haptics.tap()
                guard !dataReports.isEmpty else { return }
                typist.send = hid.sendKeyboard
                typist.enqueue(dataReports)
            } label: {
                VStack(spacing: 0) {
                    keyLabel(key.label)
                    if dataReports.isEmpty {
                        Text("set in Settings").font(.caption2).foregroundColor(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 6).fill(groupFill))
                .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .disabled(dataReports.isEmpty)
            .accessibilityLabel(key.accessibility)
        case let .consumer(code):
            Button {
                Haptics.tap()
                hid.tap(consumer: code)
            } label: {
                keyLabel(key.label)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 6).fill(groupFill))
                    .foregroundColor(.primary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(key.accessibility)
        }
    }

    @ViewBuilder
    private func keyLabel(_ label: KeyCap.Label) -> some View {
        switch label {
        case let .symbol(name): Image(systemName: name).font(.body)
        case let .text(value): Text(value).font(.footnote).lineLimit(1).minimumScaleFactor(0.5)
        // SPEC §7.2 F: a user-configured label is the user's own text, shown verbatim.
        case let .verbatim(value): Text(verbatim: value).font(.footnote).lineLimit(1).minimumScaleFactor(0.5)
        case .blank: Color.clear
        }
    }

    private let fKeys: [(Keycode, String)] = [
        (.f1, "F1"), (.f2, "F2"), (.f3, "F3"), (.f4, "F4"), (.f5, "F5"), (.f6, "F6"),
        (.f7, "F7"), (.f8, "F8"), (.f9, "F9"), (.f10, "F10"), (.f11, "F11"), (.f12, "F12")
    ]

    private var fRow: [KeyCap] {
        fKeys.map { code, name in KeyCap(.text(LocalizedStringKey(name)), LocalizedStringKey(name), .key(code)) }
    }

    private var row1: [KeyCap] {
        [
            KeyCap(.symbol("escape"), L10n.Keyboard.esc, .key(.escape)),
            KeyCap(.symbol("arrow.right.to.line"), L10n.Keyboard.tab, .key(.tab)),
            KeyCap(.text(L10n.Keyboard.printScreen), L10n.Keyboard.printScreen, .key(.printScreen)),
            KeyCap(.symbol("arrow.up"), L10n.Keyboard.up, .key(.upArrow)),
            KeyCap(.symbol("delete.left"), weight: 1.5, L10n.Keyboard.backspace, .key(.backspace)),
            KeyCap(.symbol("return"), weight: 1.5, L10n.Keyboard.enter, .key(.return))
        ]
    }

    // Windows-layout labels (Win / Ctrl / Alt / Shift): the host is Windows and the
    // physical keyboard attached to the iPad is Windows-layout. HID keycodes are
    // unchanged (leftGUI = Win, leftCtrl = Ctrl, leftAlt = Alt, leftShift = Shift).
    private var row2: [KeyCap] {
        [
            KeyCap(.text(L10n.Keyboard.shift), L10n.Keyboard.shift, .modifier(.leftShift)),
            KeyCap(.text(L10n.Keyboard.win), L10n.Keyboard.win, .modifier(.leftGUI)),
            KeyCap(.symbol("arrow.left"), L10n.Keyboard.left, .key(.leftArrow)),
            KeyCap(.symbol("arrow.down"), L10n.Keyboard.down, .key(.downArrow)),
            KeyCap(.symbol("arrow.right"), L10n.Keyboard.right, .key(.rightArrow)),
            KeyCap(.text(L10n.Keyboard.win), L10n.Keyboard.win, .modifier(.rightGUI)),
            KeyCap(.text(L10n.Keyboard.shift), L10n.Keyboard.shift, .modifier(.rightShift))
        ]
    }

    private var row3: [KeyCap] {
        [
            KeyCap(.text(L10n.Keyboard.ctrl), L10n.Keyboard.ctrl, .modifier(.leftCtrl)),
            KeyCap(.text(L10n.Keyboard.alt), L10n.Keyboard.alt, .modifier(.leftAlt)),
            KeyCap(.blank, weight: 3, L10n.Keyboard.space, .key(.space)),
            KeyCap(.text(L10n.Keyboard.altGr), L10n.Keyboard.altGr, .modifier(.rightAlt)),
            KeyCap(.text(L10n.Keyboard.ctrl), L10n.Keyboard.ctrl, .modifier(.rightCtrl))
        ]
    }

    private var row4: [KeyCap] {
        [
            KeyCap(.text(L10n.Keyboard.insert), L10n.Keyboard.insert, .key(.insert)),
            KeyCap(.text(L10n.Keyboard.delete), L10n.Keyboard.delete, .key(.delete)),
            KeyCap(.text(L10n.Keyboard.home), L10n.Keyboard.home, .key(.home)),
            KeyCap(.text(L10n.Keyboard.end), L10n.Keyboard.end, .key(.end)),
            KeyCap(.text(L10n.Keyboard.pgUp), L10n.Keyboard.pgUp, .key(.pageUp)),
            KeyCap(.text(L10n.Keyboard.pgDn), L10n.Keyboard.pgDn, .key(.pageDown))
        ]
    }

    // Dedicated combined shortcuts for the §9 acceptance flow: letters have no keycaps, so
    // hold-Win + L cannot be assembled from ordinary keycaps; a dedicated keycap sends the
    // exact combined down+release regardless of sticky/held modifiers.
    private var row5: [KeyCap] {
        [
            KeyCap(.text(LocalizedStringKey("ALT+TAB")), LocalizedStringKey("ALT+TAB"), .combo(.tab, .leftAlt)),
            KeyCap(.text(LocalizedStringKey("WIN+L")), LocalizedStringKey("WIN+L"), .combo(.l, .leftGUI))
        ]
    }

    private var effectiveMods: KeyboardModifiers { mods.union(held) }

    // Key DOWN carries the effective modifiers (sticky ∪ held); key UP releases only
    // the key — physically held modifiers stay down until that finger lifts, so a
    // held ALT survives pressing/releasing other keycaps (physical keyboard semantics).
    private func press(_ key: Keycode) {
        typist.send = hid.sendKeyboard
        typist.enqueue([
            KeyboardReport(modifiers: effectiveMods, keys: [key]),
            KeyboardReport(modifiers: held, keys: []),
        ])
    }

    private func toggle(_ mod: KeyboardModifiers) {
        if mods.contains(mod) { mods.subtract(mod) } else { mods.insert(mod) }
    }

    // live typing: diff the field against what was already sent

    private func handleChange(_ new: String) {
        if resetting {
            resetting = false
            sent = new
            return
        }
        guard liveTyping else { return }
        typist.send = hid.sendKeyboard
        let prefix = new.commonPrefix(with: sent).count
        var reports: [KeyboardReport] = []
        for _ in 0 ..< (sent.count - prefix) {
            reports += HIDInput.keyReports(for: .backspace)
        }
        for character in new.dropFirst(prefix) {
            reports += HIDInput.keyReports(for: character, adding: effectiveMods)
        }
        typist.enqueue(reports)
        sent = new
    }

    private func send() {
        guard !text.isEmpty else { return }
        typist.send = hid.sendKeyboard
        var reports: [KeyboardReport] = []
        for character in text {
            reports += HIDInput.keyReports(for: character, adding: effectiveMods)
        }
        typist.enqueue(reports)
        clear()
    }

    private func clear() {
        resetting = true
        text = ""
        focused = true
    }
}

/// SPEC §7.2: the app-specific action model (AppLayouts in WindowsForeground.swift) reuses the
/// existing KeyCap dispatch below, so KeyCap must be module-visible rather than private. A
/// data-configured action carries the decoded `LayoutAction` (SPEC §7.2 F); its label is the user's
/// own text, rendered verbatim.
struct KeyCap {
    enum Label {
        case symbol(String)
        case text(LocalizedStringKey)
        /// SPEC §7.2 F: a label that comes from the user's layout document, not from a
        /// localization table, so it is displayed verbatim (and `String` keeps the struct free of
        /// non-Sendable stored properties).
        case verbatim(String)
        case blank
    }

    enum Action {
        case key(Keycode)
        case modifier(KeyboardModifiers)
        case combo(Keycode, KeyboardModifiers)
        case consumer(ConsumerKey)
        /// SPEC §7.2 F: a user-configured action from the layout document. It carries the decoded
        /// target (one chord, an ordered chord sequence, typed text/path, or the app-settings key
        /// holding the user's chord for one of the six project/folder targets); no keystroke
        /// sequence is hard-coded and every report reuses the existing `HIDInput`/`KeyTypist`
        /// keyboard path, so no new keycode or HID report type is introduced.
        case layout(LayoutAction)
    }

    let label: Label
    let weight: CGFloat
    let accessibility: LocalizedStringKey
    let action: Action

    init(_ label: Label, weight: CGFloat = 1, _ accessibility: LocalizedStringKey, _ action: Action) {
        self.label = label
        self.weight = weight
        self.accessibility = accessibility
        self.action = action
    }
}

private struct ArrowPad: View {
    let onArrow: (Keycode) -> Void

    @StateObject private var repeater = ArrowRepeater()
    #if os(iOS)
        @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        ZStack {
            glyph("↑", .upArrow, dx: 0, dy: -8)
            glyph("↓", .downArrow, dx: 0, dy: 8)
            glyph("←", .leftArrow, dx: -10, dy: 0)
            glyph("→", .rightArrow, dx: 10, dy: 0)
        }
        .frame(width: 46, height: 34)
        .contentShape(Rectangle())
        .accessibilityLabel(L10n.Keyboard.arrows)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged {
                    repeater.fire = onArrow
                    if let key = _direction($0.translation) {
                        repeater.start(key)
                    } else {
                        repeater.stop()
                    }
                }
                .onEnded { _ in repeater.stop() }
        )
        #if os(iOS)
            // SPEC §7.3 C: a held/repeating arrow must not survive app inactivity or
            // view exit and must never resume on return; a later drag rebinds `fire`
            // in `onChanged` before `start`.
            .onChange(of: scenePhase) { phase in
                if phase != .active {
                    repeater.stop()
                }
            }
            .onDisappear {
                repeater.stop()
            }
        #endif
    }

    private func glyph(_ char: String, _ key: Keycode, dx: CGFloat, dy: CGFloat) -> some View {
        Text(char)
            .font(.system(size: 15))
            .foregroundStyle(Color.primary)
            .opacity(repeater.active == nil || repeater.active == key ? 1 : 0.25)
            .offset(x: dx, y: dy)
    }

    private func _direction(_ d: CGSize) -> Keycode? {
        guard hypot(d.width, d.height) >= 20 else { return nil }
        if abs(d.width) > abs(d.height) { return d.width > 0 ? .rightArrow : .leftArrow }
        return d.height > 0 ? .downArrow : .upArrow
    }
}

@MainActor
private final class ArrowRepeater: ObservableObject {
    var fire: ((Keycode) -> Void)?
    @Published private(set) var active: Keycode?

    private var task: Task<Void, Never>?

    func start(_ key: Keycode) {
        guard key != active else { return }
        // SPEC §7.3 C: `stop()` clears the callback; capture the currently configured
        // callback across it so a normal re-start (after inactivity or a reconnect)
        // still sends the first key press and the repeats.
        let fire = self.fire
        stop()
        active = key
        fire?(key)
        task = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            while !Task.isCancelled {
                fire?(key)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// SPEC §7.3 C: stop the repeat and clear the callback (a held key never resumes
    /// after inactivity). The next drag rebinds `fire` before `start`, so the normal
    /// arrows keep working.
    func stop() {
        task?.cancel()
        task = nil
        active = nil
        fire = nil
    }
}

/// paces keyboard reports so each down/up transition is delivered;
/// without spacing, rapid identical key presses get coalesced and lost.
///
/// SPEC §7.3 C: the view cancels this on PC exit/inactive/disconnect. `cancel()` keeps
/// the in-flight paced task retained and moves the generation on, so a stale drain can
/// never consume the next session's queue or send through the next session's `send`
/// closure.
@MainActor
private final class KeyTypist: ObservableObject {
    var send: ((KeyboardReport) -> Void)?

    private var queue: [KeyboardReport] = []
    private var draining = false
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    func enqueue(_ reports: [KeyboardReport]) {
        guard !reports.isEmpty else { return }
        queue.append(contentsOf: reports)
        guard !draining else { return }
        draining = true
        let generation = self.generation
        task = Task { [weak self] in
            await self?.drain(generation: generation)
        }
    }

    /// SPEC §7.3 C: clear all pending keyboard queue and callbacks — kill the in-flight
    /// paced task, discard every queued report and the captured `send` closure, and
    /// invalidate the current generation. Every call site assigns `send` before
    /// `enqueue`, so the next session is unaffected.
    func cancel() {
        task?.cancel()
        task = nil
        queue.removeAll()
        send = nil
        draining = false
        generation &+= 1
    }

    private func drain(generation: UInt64) async {
        // A stale drain must not send through the next session's `send` closure or
        // consume the next session's queue: check generation before the first send and
        // cancellation + generation again after every sleep. It must never clear a new
        // session's task/queue/draining state, so on staleness it just returns.
        guard generation == self.generation else { return }
        while !Task.isCancelled, generation == self.generation, !queue.isEmpty {
            send?(queue.removeFirst())
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard !Task.isCancelled, generation == self.generation else { return }
        draining = false
    }
}

#if DEBUG
    #Preview {
        KeyboardView(goToSetup: {})
            .environmentObject(DirectInputController())
    }
#endif

#if os(iOS)
    /// SPEC §5.2 I: the free racing surface. Raw UIKit touches — not a SwiftUI
    /// `DragGesture`, which would fight the §7.1 CONTROL pad and the §5 keyboard —
    /// covering all of the GAME surface that is not a racing button/trigger hit
    /// region. Each touch's own `touchesBegan` point is its origin, so there is no
    /// drawn pad to aim at, and only the first touch on this surface drives RX.
    struct RacingSurfaceView: UIViewRepresentable {
        var onTouchBegan: (CGPoint) -> Void
        var onTouchMoved: (CGPoint) -> Void
        var onTouchEnded: () -> Void

        func makeUIView(context: Context) -> RacingTouchView {
            RacingTouchView(onTouchBegan: onTouchBegan, onTouchMoved: onTouchMoved, onTouchEnded: onTouchEnded)
        }

        func updateUIView(_ uiView: RacingTouchView, context: Context) {
            uiView.onTouchBegan = onTouchBegan
            uiView.onTouchMoved = onTouchMoved
            uiView.onTouchEnded = onTouchEnded
        }
    }

    /// Single-drag raw touch view, mirroring the §5 "GAME high-fidelity input"
    /// handling: `touchesBegan`/`touchesMoved(_:with:)` with
    /// `UIEvent.coalescedTouches(for:)`; predicted touches are not used. A touch that
    /// began on a racing control is never routed here (only actual control hit areas
    /// intercept), and `touchesEnded`/`touchesCancelled` releases RX.
    @MainActor
    final class RacingTouchView: UIView {
        var onTouchBegan: (CGPoint) -> Void
        var onTouchMoved: (CGPoint) -> Void
        var onTouchEnded: () -> Void

        private var tracked: UITouch?

        init(
            onTouchBegan: @escaping (CGPoint) -> Void,
            onTouchMoved: @escaping (CGPoint) -> Void,
            onTouchEnded: @escaping () -> Void
        ) {
            self.onTouchBegan = onTouchBegan
            self.onTouchMoved = onTouchMoved
            self.onTouchEnded = onTouchEnded
            super.init(frame: .zero)
            isMultipleTouchEnabled = true
            backgroundColor = .clear
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard tracked == nil, let touch = touches.first else { return }
            tracked = touch
            let location = touch.location(in: self)
            onTouchBegan(location)
        }

        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
            guard let tracked, touches.contains(tracked) else { return }
            // The newest actual sample wins; the surface maps an absolute position
            // from the touch's own origin, so only the latest point matters.
            let latest = (event?.coalescedTouches(for: tracked) ?? [tracked]).last ?? tracked
            onTouchMoved(latest.location(in: self))
        }

        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
            release(touches)
        }

        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
            release(touches)
        }

        private func release(_ touches: Set<UITouch>) {
            guard let tracked, touches.contains(tracked) else { return }
            self.tracked = nil
            onTouchEnded()
        }
    }
#endif
