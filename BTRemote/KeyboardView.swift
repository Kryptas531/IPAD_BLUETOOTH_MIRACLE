import SwiftUI

private let keyHeight: CGFloat = 44

/// Touch-to-mouse surface mode on the Windows input screen.
enum PadMode: String {
    case game
    case trackpad
    case touch
    case deck
}

struct KeyboardView: View {
    let goToSetup: () -> Void
    var openSettings: () -> Void = {}

    @Environment(\.hid) private var hid
    @AppStorage(AppSettings.developerModeKey) private var developerMode = false
    @AppStorage(AppSettings.liveTypingKey) private var liveTyping = true
    @AppStorage(AppSettings.padModeKey) private var padMode = PadMode.trackpad
    @AppStorage(AppSettings.touchpadSensitivityKey) private var touchpadSensitivity = AppSettings.defaultPointerSensitivity
    @AppStorage(AppSettings.gameInputModeKey) private var gameInputMode = GameInputMode.touch
    @AppStorage(AppSettings.gyroSensitivityKey) private var gyroSensitivity = AppSettings.defaultGyroSensitivity
    @EnvironmentObject private var directInput: DirectInputController
    @EnvironmentObject private var lowEnergy: HIDPeripheral
    #if os(iOS)
        @StateObject private var gyro = GyroAimController()
        @Environment(\.scenePhase) private var scenePhase
    #endif
    @State private var text = ""
    @State private var sent = ""
    @State private var resetting = false
    @State private var gameChromeVisible = true
    @State private var showKeyboard = false
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
            if geo.size.width > geo.size.height {
            if padMode == .game {
                ZStack(alignment: .top) {
                    TrackpadPanel(
                        hid: hid, mode: padMode, metrics: lowEnergy.performanceMetrics,
                        touchMovementEnabled: gameInputMode != .gyro
                    )
                    if gameChromeVisible {
                        VStack(spacing: 4) {
                            controlBar
                            Spacer()
                            bottomStrip
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
                                    Picker(L10n.Input.source, selection: $gameInputMode) {
                                        Text(L10n.Input.touch).tag(GameInputMode.touch)
                                        Text(L10n.Input.gyro).tag(GameInputMode.gyro)
                                        Text(L10n.Input.hybrid).tag(GameInputMode.hybrid)
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .frame(maxWidth: 200)
                                    Text(L10n.Settings.gyroSensitivity).font(.caption2)
                                    Slider(value: $gyroSensitivity, in: AppSettings.gyroSensitivityRange)
                                        .frame(maxWidth: 180)
                                    Button(L10n.Action.recenter) {
                                        Haptics.tap()
                                        gyro.recenter()
                                    }
                                    .buttonStyle(.bordered)
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
                        .background(.thinMaterial.opacity(0.88))
                    } else {
                        Button("•••") {
                            gameChromeVisible = true
                        }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .onChange(of: scenePhase) { phase in
                if phase == .active { configureGyro() }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) { accessoryBar }
            }
        #endif
    }

    #if os(iOS)
        /// Apply the slider value to the running source only. Changing sensitivity must
        /// not restart CoreMotion or clear the attitude baseline, otherwise moving the
        /// slider re-baselines the gyro mid-use and loses deltas (SPEC §5.1 C/G).
        @MainActor private func applyGyroSensitivity() {
            gyro.sensitivity = gyroSensitivity
        }

        /// Wire the gyro source to the existing relative-mouse report path and start or stop
        /// it according to the selected GAME input source (SPEC §5.1 B/G).
        @MainActor private func configureGyro() {
            gyro.sensitivity = gyroSensitivity
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
                statusDot("dot.radiowaves.left.and.right", on: hid.isConnected)
                #if os(iOS)
                    // SPEC §7: Direct Input = compact status icon; long-press the
                    // keyboard indicator to reveal capture/release controls.
                    statusDot("keyboard", on: hid.isActive)
                        .padding(4)
                        .contentShape(Rectangle())
                        .onLongPressGesture {
                            Haptics.tap()
                            showDirectInputControls = true
                        }
                        .confirmationDialog(L10n.DirectInput.section, isPresented: $showDirectInputControls, titleVisibility: .visible) {
                            Button(L10n.DirectInput.enable) {
                                Haptics.tap()
                                directInput.start(hid)
                            }
                            .disabled(!directInput.hasInputDevice)
                            Button(L10n.DirectInput.release) {
                                Haptics.tap()
                                directInput.stop()
                            }
                            Button(L10n.Action.notNow, role: .cancel) {}
                        }
                #else
                    statusDot("keyboard", on: hid.isActive)
                #endif
                statusDot("rectangle.and.hand.point.up.left", on: directInput.isCapturing)
            }
            #if os(iOS)
                Button {
                    Haptics.tap()
                    openSettings()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(L10n.Tab.settings)
            #endif
        }
    }

    private var modeSwitcher: some View {
        HStack(spacing: 4) {
            modeButton(L10n.Input.game, tag: .game)
            modeButton(L10n.Input.trackpad, tag: .trackpad)
            modeButton(L10n.Input.touch, tag: .touch, disabled: true)
            modeButton(L10n.Input.deck, tag: .deck)
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
                showKeyboard.toggle()
                if showKeyboard { focused = true }
            } label: {
                Image(systemName: "keyboard")
                    .font(.caption)
                    .padding(.horizontal, 6)
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
        }
    }

    @ViewBuilder
    private func keyLabel(_ label: KeyCap.Label) -> some View {
        switch label {
        case let .symbol(name): Image(systemName: name).font(.body)
        case let .text(value): Text(value).font(.footnote)
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

private struct KeyCap {
    enum Label {
        case symbol(String)
        case text(LocalizedStringKey)
        case blank
    }

    enum Action {
        case key(Keycode)
        case modifier(KeyboardModifiers)
        case combo(Keycode, KeyboardModifiers)
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
        stop()
        active = key
        fire?(key)
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            while !Task.isCancelled {
                self?.fire?(key)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        active = nil
    }
}

/// paces keyboard reports so each down/up transition is delivered;
/// without spacing, rapid identical key presses get coalesced and lost.
@MainActor
private final class KeyTypist: ObservableObject {
    var send: ((KeyboardReport) -> Void)?

    private var queue: [KeyboardReport] = []
    private var draining = false

    func enqueue(_ reports: [KeyboardReport]) {
        guard !reports.isEmpty else { return }
        queue.append(contentsOf: reports)
        guard !draining else { return }
        draining = true
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            send?(queue.removeFirst())
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        draining = false
    }
}

#if DEBUG
    #Preview {
        KeyboardView(goToSetup: {})
            .environmentObject(DirectInputController())
    }
#endif
