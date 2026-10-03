#if os(iOS)
import SwiftUI
import UIKit

/// SPEC 784bad0 §7.3 C: an independent TV surface, usable without a paired PC.
@MainActor
struct TVRemoteView: View {
    @ObservedObject var client: TVRemoteClient
    let acceptsTarget: () -> Bool
    @AppStorage(AppSettings.tvHostKey) private var address = ""
    @AppStorage(AppSettings.tvLabelKey) private var label = "TCL TV"
    @State private var showConnection = true
    @State private var code = ""
    @State private var showForget = false
    @State private var showText = false
    @State private var text = ""
    @State private var textGeneration: UInt64 = 0
    @State private var textField: Int32?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let generation = client.sessionGeneration
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 16) {
                    status
                    if geometry.size.width > geometry.size.height {
                        HStack(alignment: .center, spacing: 24) {
                            navigationPad.frame(maxWidth: .infinity)
                            actions.frame(maxWidth: .infinity)
                        }
                    } else {
                        navigationPad
                        actions
                    }
                    connectionControls
                }
                .padding().frame(maxWidth: 1000).frame(maxWidth: .infinity)
            }
        }
        .navigationTitle(client.deviceLabel)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if address.isEmpty { address = client.host }
            showConnection = !client.isPaired
        }
        .onChange(of: client.sessionGeneration) { _ in clearText(); code = "" }
        .onChange(of: client.textEntryAvailable) { available in if !available { clearText() } }
        .onChange(of: client.textFieldCounter) { field in if field != textField { clearText() } }
        .onChange(of: scenePhase) { phase in
            if phase != .active { clearText(); code = "" }
        }
        .onDisappear {
            if acceptsTarget(), client.sessionGeneration == generation { client.releaseAllKeys() }
            clearText(); code = ""
        }
        .alert("Forget TV pairing?", isPresented: $showForget) {
            Button("Forget and re-pair", role: .destructive) {
                guard acceptsTarget() else { return }
                client.forgetPairing(); code = ""; showConnection = true
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes this app's saved TV identity and pairing. Pair again using the code displayed on the TV.")
        }
        .sheet(isPresented: $showText, onDismiss: { text = "" }) { textSheet }
    }

    private var status: some View {
        VStack(spacing: 4) {
            Text("TV · \(client.deviceLabel)").font(.headline)
            Text(connectionLabel).font(.subheadline)
            Text(client.powerPending ? "Power request pending — waiting for the TV" : powerLabel)
                .font(.caption).foregroundColor(.secondary)
            if let error = client.lastError {
                Text(error).font(.caption).foregroundColor(.orange).multilineTextAlignment(.center)
            }
        }.accessibilityElement(children: .combine)
    }

    private var connectionLabel: String {
        switch client.state {
        case .fresh: return client.isPaired ? "Paired · Connect to TV" : "Unpaired · Enter the TV address"
        case .pairing: return client.isAwaitingCode ? "Pairing · Enter the code displayed on TV" : "Pairing with TV…"
        case .connecting: return "Connecting…"
        case .connected: return "Connected · \(client.host)"
        case .reconnecting: return "Reconnecting…"
        case .localNetworkDenied: return "Local network access denied"
        case .unavailable: return "TV unavailable · Retry or re-pair"
        }
    }
    private var powerLabel: String {
        switch client.power {
        case .unknown: return "Power state unknown · Standby wake requires testing on this TV"
        case .on: return "TV reports power on"
        case .off: return "TV reports standby"
        }
    }

    private var navigationPad: some View {
        let generation = client.sessionGeneration
        let allowed = { acceptsTarget() && client.sessionGeneration == generation }
        return VStack(spacing: 8) {
            key("Up", symbol: "chevron.up", code: .dpadUp, allowed: allowed).frame(width: 100)
            HStack(spacing: 8) {
                key("Left", symbol: "chevron.left", code: .dpadLeft, allowed: allowed)
                TVHoldKey(label: "OK", symbol: nil, enabled: client.canSendKeys,
                          press: { if allowed() { client.press(.ok) } },
                          release: { if allowed() { client.release(.ok) } })
                key("Right", symbol: "chevron.right", code: .dpadRight, allowed: allowed)
            }.frame(maxWidth: 340)
            key("Down", symbol: "chevron.down", code: .dpadDown, allowed: allowed).frame(width: 100)
        }.id(generation)
    }

    private func key(_ label: String, symbol: String, code: TVKeycode, allowed: @escaping () -> Bool) -> some View {
        TVHoldKey(label: label, symbol: symbol, enabled: client.canSendKeys,
                  press: { if allowed() { client.press(code) } },
                  release: { if allowed() { client.release(code) } })
    }

    private var actions: some View {
        let generation = client.sessionGeneration
        let allowed = { acceptsTarget() && client.sessionGeneration == generation }
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                action("Back", symbol: "arrow.uturn.backward", code: .back, allowed: allowed)
                action("Home", symbol: "house", code: .home, allowed: allowed)
            }
            HStack(spacing: 10) {
                key("Volume down", symbol: "speaker.minus", code: .volumeDown, allowed: allowed)
                key("Volume up", symbol: "speaker.plus", code: .volumeUp, allowed: allowed)
            }
            HStack(spacing: 10) {
                action("Mute", symbol: "speaker.slash", code: .volumeMute, allowed: allowed)
                action("Play / Pause", symbol: "playpause", code: .mediaPlayPause, allowed: allowed)
            }
            Button {
                if allowed() { client.requestPowerToggle() }
            } label: {
                Label(client.powerPending ? "Power pending" : "Power / Wake", systemImage: "power")
                    .frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.bordered).disabled(!client.canRequestPower)
            Button {
                guard allowed(), client.textEntryAvailable else { return }
                textGeneration = generation; textField = client.textFieldCounter; text = ""; showText = true
            } label: {
                Label("Enter text", systemImage: "keyboard").frame(maxWidth: .infinity, minHeight: 48)
            }.buttonStyle(.bordered).disabled(!client.textEntryAvailable)
            if !client.textEntryAvailable {
                Text("Text is available only in a supported active TV input field.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }.id(generation)
    }

    private func action(_ label: String, symbol: String, code: TVKeycode, allowed: @escaping () -> Bool) -> some View {
        Button { if allowed() { client.tap(code) } } label: {
            Label(label, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 48)
        }.buttonStyle(.bordered).disabled(!client.canSendKeys)
    }

    private var connectionControls: some View {
        DisclosureGroup("TV connection", isExpanded: $showConnection) {
            VStack(alignment: .leading, spacing: 12) {
                TextField("Private TV IP address", text: $address)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
                TextField("Device label", text: $label).textFieldStyle(.roundedBorder)
                HStack {
                    Button(client.isPaired ? "Connect" : "Pair with TV") {
                        guard acceptsTarget() else { return }
                        if client.isPaired { client.connect(host: address) }
                        else { client.beginPairing(host: address, label: label) }
                    }.buttonStyle(.borderedProminent).disabled(address.isEmpty)
                    Button("Retry") { if acceptsTarget() { client.retry() } }.buttonStyle(.bordered)
                    Button("Disconnect") { if acceptsTarget() { client.disconnect() } }.buttonStyle(.bordered)
                }
                if client.isAwaitingCode {
                    HStack {
                        TextField("Six-character TV code", text: $code)
                            .textInputAutocapitalization(.characters).disableAutocorrection(true)
                            .textFieldStyle(.roundedBorder)
                        Button("Confirm") {
                            guard acceptsTarget() else { return }
                            client.submitPairingCode(code.trimmingCharacters(in: .whitespacesAndNewlines)); code = ""
                        }.disabled(code.count != 6)
                    }
                }
                HStack {
                    Button("iPad Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Spacer()
                    Button("Forget / re-pair", role: .destructive) { showForget = true }
                }
                Text("Use the TV's LAN address. Pairing and control use its existing Android TV Remote Service. No PC is required.")
                    .font(.caption).foregroundColor(.secondary)
            }.padding(.top, 8)
        }
    }

    private var textSheet: some View {
        NavigationView {
            VStack(spacing: 12) {
                Text("Send Unicode text to the active TV field").font(.headline)
                TextEditor(text: $text).padding(6).background(groupFill).cornerRadius(8)
                Text("Field and app support vary. Password fields and clipboard synchronization are not guaranteed.")
                    .font(.caption).foregroundColor(.secondary)
                Button("Send text") {
                    guard acceptsTarget(), client.sessionGeneration == textGeneration,
                          client.textFieldCounter == textField, client.textEntryAvailable else { clearText(); return }
                    client.sendText(text); clearText()
                }.buttonStyle(.borderedProminent).disabled(text.isEmpty || !client.textEntryAvailable)
            }.padding().navigationTitle("TV text")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: clearText) } }
        }.navigationViewStyle(.stack)
    }
    private func clearText() { text = ""; showText = false; textField = nil }
}

/// GestureState resets on both touch end and cancellation, unlike onEnded alone.
@MainActor
private struct TVHoldKey: View {
    let label: String
    let symbol: String?
    let enabled: Bool
    let press: () -> Void
    let release: () -> Void
    @GestureState private var touching = false
    @State private var held = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if let symbol { Image(systemName: symbol).font(.title2) }
            else { Text(label).font(.title2.bold()) }
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(held ? Color.accentColor.opacity(0.4) : groupFill)
        .cornerRadius(12).contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0).updating($touching) { _, state, _ in state = true })
        .onChange(of: touching) { down in
            if down, enabled, scenePhase == .active, !held { held = true; Haptics.tap(); press() }
            else if !down { endHold() }
        }
        .onChange(of: enabled) { value in if !value { endHold() } }
        .onChange(of: scenePhase) { phase in if phase != .active { endHold() } }
        .onDisappear(perform: endHold)
        .accessibilityLabel(label)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { if enabled { press(); release() } }
    }
    private func endHold() { if held { held = false; release() } }
}
#endif
