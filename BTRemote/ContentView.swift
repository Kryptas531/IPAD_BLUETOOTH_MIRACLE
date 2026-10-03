import SwiftUI

@MainActor
struct ContentView: View {
    @State private var tab = Tab.setup

    @Environment(\.hid) private var hid
    @StateObject private var directInput = DirectInputController()
    @Environment(\.openURL) private var openURL
    @AppStorage(AppSettings.hasSeenWelcomeKey) private var hasSeenWelcome = false
    @State private var showWelcome = false
    @State private var sheet: Sheet?
    #if os(iOS)
        @StateObject private var tv = TVRemoteClient()
        @EnvironmentObject private var lowEnergy: HIDPeripheral
        @EnvironmentObject private var central: HIDCentral
        @Environment(\.scenePhase) private var scenePhase
        @AppStorage(AppSettings.remoteTargetKey) private var targetRaw = RemoteTarget.pc.rawValue
        @State private var inputSession = RemoteTargetSession()
        @State private var sessionEpoch: UInt64 = 0
        @State private var pcRelease: (() -> Void)?
    #endif
    #if os(macOS)
        @State private var showAccessibilityPrompt = false
        @State private var showConnectPrompt = false
    #endif

    private enum Sheet: Identifiable {
        case setup, settings, guide

        var id: Self { self }
    }

    private enum Tab {
        case setup, remote, settings
    }

    var body: some View {
        Group {
            #if os(iOS)
                NavigationView {
                    VStack(spacing: 0) {
                        Picker("Control target", selection: Binding(get: { targetRaw }, set: { value in
                            if let next = RemoteTarget(rawValue: value) { selectTarget(next) }
                        })) {
                            Text("PC").tag(RemoteTarget.pc.rawValue)
                            Text("TV").tag(RemoteTarget.tv.rawValue)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal).padding(.vertical, 6)
                        if target == .pc {
                            pcView
                        } else {
                            TVRemoteView(client: tv, acceptsTarget: tvTargetGate)
                        }
                    }
                }
                .navigationViewStyle(.stack)
                .background(PointerLockHost(locked: directInput.isCapturing))
                .onChange(of: scenePhase) { phase in sceneChanged(phase) }
                .onChange(of: hid.isConnected) { _ in renewPCSession() }
                .onChange(of: hid.isActive) { _ in renewPCSession() }
            #else
                TabView(selection: $tab) {
                    SetupView()
                        .tabItem { Label(L10n.Tab.setup, systemImage: "gearshape") }
                        .tag(Tab.setup)
                    RemoteTabView(goToSetup: { tab = .setup })
                        .tabItem { Label(L10n.Tab.remote, systemImage: "keyboard") }
                        .tag(Tab.remote)
                    SettingsView()
                        .tabItem { Label(L10n.Tab.settings, systemImage: "slider.horizontal.3") }
                        .tag(Tab.settings)
                }
                .onChange(of: hid.isConnected) { connected in
                    guard connected else { return }
                    if !directInput.isCapturing { showConnectPrompt = true }
                }
                .frame(minWidth: 480, idealWidth: 560, minHeight: 640, idealHeight: 800)
                .onChange(of: directInput.needsAccessibility) { needs in
                    guard needs else { return }
                    showAccessibilityPrompt = true
                    directInput.clearAccessibilityRequest()
                }
                .alert(L10n.DirectInput.permissionTitle, isPresented: $showAccessibilityPrompt) {
                    Button(L10n.DirectInput.openSettings) { AccessibilityPermission.request() }
                    Button(L10n.Action.notNow, role: .cancel) {}
                } message: {
                    Text(L10n.DirectInput.permissionMessage)
                }
                .alert(L10n.DirectInput.connectedPromptTitle, isPresented: $showConnectPrompt) {
                    Button(L10n.DirectInput.enable) { directInput.start(hid) }
                    Button(L10n.Action.notNow, role: .cancel) { tab = .remote }
                } message: {
                    Text(L10n.DirectInput.connectedPromptMessage)
                        + Text(verbatim: "\n\n")
                        + Text(L10n.DirectInput.releaseHint)
                }
            #endif
        }
        .onAppear(perform: _onAppear)
        .alert(L10n.Welcome.title, isPresented: $showWelcome) {
            Button(L10n.Welcome.viewGuide) {
                hasSeenWelcome = true
                sheet = .guide
            }
            .keyboardShortcut(.defaultAction)
            Button(L10n.Setup.videoInstructions) { openURL(AppSettings.instructionsURL) }
        } message: {
            Text(L10n.Welcome.message)
        }
        .sheet(item: $sheet) { which in
            Group {
                switch which {
                case .setup:
                    SetupView()
                case .settings:
                    SettingsView()
                case .guide:
                    guideSheet
                }
            }
            #if os(iOS)
            .environment(\.hid, target == .pc ? gatedPCInput : .unavailable)
            #endif
        }
        .environmentObject(directInput)
        #if os(iOS)
        .environment(\.hid, target == .pc ? gatedPCInput : .unavailable)
        #endif
    }

    private func _onAppear() {
        #if os(iOS)
            inputSession.transition(to: target)
            sessionEpoch = inputSession.generation
            tv.setActive(target == .tv && scenePhase == .active)
        #endif
        if !hasSeenWelcome {
            showWelcome = true
        }
        #if os(macOS)
            if hasSeenWelcome, !AccessibilityPermission.isTrusted { showAccessibilityPrompt = true }
        #endif
    }

    #if os(iOS)
        private var target: RemoteTarget { RemoteTarget(rawValue: targetRaw) ?? .pc }

        private var pcView: some View {
            let token = inputSession.token
            return KeyboardView(goToSetup: { sheet = .setup }, openSettings: { sheet = .settings }, registerPCRelease: { callback in
                guard inputSession.accepts(token), token.target == .pc else { return }
                pcRelease = callback
            })
            .environment(\.hid, gatedPCInput)
            .id(sessionEpoch)
        }

        private var tvTargetGate: () -> Bool {
            let token = inputSession.token
            return { inputSession.accepts(token) && token.target == .tv }
        }

        private var gatedPCInput: HIDInput {
            let token = inputSession.token
            let raw = hid
            let allowed = {
                inputSession.accepts(token) && token.target == .pc && lowEnergy.isHIDServiceAdded
                    && (lowEnergy.connectedCentrals.contains { !lowEnergy.inactiveCentrals.contains($0) } || !central.connected.isEmpty)
            }
            return HIDInput(
                sendMouse: { if allowed() { raw.sendMouse($0) } },
                sendKeyboard: { if allowed() { raw.sendKeyboard($0) } },
                sendConsumer: { if allowed() { raw.sendConsumer($0) } },
                sendGamepad: { if allowed() { raw.sendGamepad($0) } },
                updateBattery: { raw.updateBattery($0) },
                isActive: raw.isActive, isConnected: raw.isConnected,
                activeError: raw.activeError, batteryLevel: raw.batteryLevel
            )
        }

        private func releasePC() {
            pcRelease?(); pcRelease = nil
            directInput.stop()
            lowEnergy.releaseInputSession()
        }

        private func selectTarget(_ next: RemoteTarget) {
            guard next != target else { return }
            if target == .pc { releasePC() } else { tv.setActive(false) }
            inputSession.transition(to: next)
            targetRaw = next.rawValue; sessionEpoch = inputSession.generation
            tv.setActive(next == .tv && scenePhase == .active)
        }

        private func sceneChanged(_ phase: ScenePhase) {
            if phase != .active {
                if target == .pc { releasePC() }
                tv.setActive(false); inputSession.suspend()
            } else {
                inputSession.resume()
                tv.setActive(target == .tv)
            }
            sessionEpoch = inputSession.generation
        }

        private func renewPCSession() {
            guard target == .pc else { return }
            releasePC(); inputSession.transition(to: .pc)
            sessionEpoch = inputSession.generation
        }
    #endif

    private var guideSheet: some View {
        #if os(macOS)
            NavigationStack { guideSheetContent }
                .frame(minWidth: 420, minHeight: 520)
        #else
            NavigationView { guideSheetContent }
                .navigationViewStyle(.stack)
        #endif
    }

    private var guideSheetContent: some View {
        GuideView(transport: .lowEnergy)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.Action.done) { sheet = nil }
                }
            }
    }
}

#if DEBUG
    #Preview {
        #if os(iOS)
            ContentView()
                .environmentObject(HIDPeripheral())
                .environmentObject(HIDCentral())
                .environmentObject(DeviceNameStore())
        #else
            ContentView()
                .environmentObject(HIDPeripheral())
                .environmentObject(HIDCentral())
                .environmentObject(DeviceNameStore())
                .environmentObject(HIDClassicDevice())
        #endif
    }
#endif
