#if os(iOS)
    import CryptoKit
    import Foundation
    import Security
    import SwiftUI

    // MARK: - SPEC §7.2 — Windows foreground helper (iPad side)

    /// The application tokens the Windows helper reports. The iPad consumes only
    /// `foreground-changed` messages; `generic` is the fallback used before the helper is paired,
    /// after a link error, and for any token it cannot map, so CONTROL always has a usable set.
    enum ForegroundToken: String {
        case vscode
        case chrome
        case explorer
        case generic
    }

    /// One user-configurable per-app CONTROL action: a label plus one of the HID sends the CONTROL
    /// surface already knows how to emit (SPEC §7.2). Actions are data, not view code, so a user's
    /// own VS Code target or key bindings are configured in `AppLayouts` instead of being
    /// hardcoded in the view. Every entry reuses an existing keycap action; no new keycodes and no
    /// new HID reports are introduced.
    struct AppActionSet {
        let title: LocalizedStringKey
        let keys: [KeyCap]
    }

    enum AppLayouts {
        /// VS Code target (user-editable).
        ///
        /// SPEC §7.2 F: the eleven required VS Code labels are listed verbatim and must appear
        /// exactly as written. `Frost Pi`, `SideChatAI` and `Quick Open Browser Tab` are the
        /// project-specific user-defined targets: each keycap carries the **app-settings key** that
        /// stores the user's own chord, so no path, command or keystroke sequence is hard-coded
        /// here and a different project's targets need no code change. Every entry reuses an
        /// existing keycap action; no new keycodes and no new HID reports are introduced.
        static let vscode = AppActionSet(title: "VS Code", keys: [
            KeyCap(.text("New Window"), "New Window", .combo(.n, [.leftCtrl, .leftShift])),
            // VS Code `Open Folder` is the two-chord sequence `Ctrl+K` then `Ctrl+O`, not a single
            // `Ctrl+O` chord (`Ctrl+O` alone is "Open File", which is not the specified action).
            KeyCap(.text("Open Folder"), "Open Folder",
                   .sequence([(.k, .leftCtrl), (.o, .leftCtrl)])),
            KeyCap(.text("Frost Pi"), "Frost Pi", .userTarget(AppSettings.frostPiShortcutKey)),
            KeyCap(.text("SideChatAI"), "SideChatAI", .userTarget(AppSettings.sideChatAIShortcutKey)),
            KeyCap(.text("Explorer"), "Explorer", .combo(.e, [.leftCtrl, .leftShift])),
            KeyCap(.text("Source Control"), "Source Control", .combo(.g, [.leftCtrl, .leftShift])),
            KeyCap(.text("New Terminal"), "New Terminal", .combo(.grave, .leftCtrl)),
            KeyCap(.text("Close Saved"), "Close Saved", .combo(.w, .leftCtrl)),
            KeyCap(.text("Split Editor Right"), "Split Editor Right", .combo(.backslash, .leftCtrl)),
            KeyCap(.text("Move to the editor"), "Move to the editor", .combo(.digit1, .leftCtrl)),
            KeyCap(.text("Quick Open Browser Tab"), "Quick Open Browser Tab",
                   .userTarget(AppSettings.quickOpenBrowserTabShortcutKey)),
        ])

        /// Chrome / Edge target (user-editable).
        ///
        /// SPEC §7.2 F "useful action set": nine actions, each bound to an existing keyboard
        /// shortcut sent through the existing HID path. No new keycodes or HID reports.
        static let chrome = AppActionSet(title: "Chrome", keys: [
            KeyCap(.text("New Tab"), "New Tab", .combo(.t, .leftCtrl)),
            KeyCap(.text("Close Tab"), "Close Tab", .combo(.w, .leftCtrl)),
            KeyCap(.text("Reload"), "Reload", .combo(.r, .leftCtrl)),
            KeyCap(.text("Focus Address Bar"), "Focus Address Bar", .combo(.l, .leftCtrl)),
            KeyCap(.text("Back"), "Back", .combo(.leftArrow, .leftAlt)),
            KeyCap(.text("Forward"), "Forward", .combo(.rightArrow, .leftAlt)),
            KeyCap(.text("History"), "History", .combo(.h, .leftCtrl)),
            KeyCap(.text("Show Bookmarks"), "Show Bookmarks", .combo(.b, [.leftCtrl, .leftShift])),
            KeyCap(.text("Full Screen"), "Full Screen", .key(.f11)),
        ])

        /// Windows File Explorer target (user-editable).
        ///
        /// SPEC §7.2 F "useful action set": nine actions. `This PC`, `Documents` and `Downloads`
        /// are user-configurable targets: their concrete keystroke target is NOT hard-coded (no
        /// folder path or chord is baked in); each keycap carries the app-settings key holding the
        /// chord the user entered, like the VS Code custom targets. A blank setting leaves the
        /// keycap disabled and sending nothing. No new keycodes or HID reports are introduced.
        static let explorer = AppActionSet(title: "File Explorer", keys: [
            KeyCap(.text("New Window"), "New Window", .combo(.n, .leftCtrl)),
            KeyCap(.text("New Tab"), "New Tab", .combo(.t, .leftCtrl)),
            KeyCap(.text("This PC"), "This PC", .userTarget(AppSettings.thisPCShortcutKey)),
            KeyCap(.text("Documents"), "Documents", .userTarget(AppSettings.documentsShortcutKey)),
            KeyCap(.text("Downloads"), "Downloads", .userTarget(AppSettings.downloadsShortcutKey)),
            KeyCap(.text("Search"), "Search", .combo(.e, .leftCtrl)),
            KeyCap(.text("Select All"), "Select All", .combo(.a, .leftCtrl)),
            KeyCap(.text("New Folder"), "New Folder", .combo(.n, [.leftCtrl, .leftShift])),
            KeyCap(.text("Rename"), "Rename", .key(.f2)),
        ])

        /// The set matching the reported application. `nil` for no link, an unknown token, or
        /// `generic`, i.e. "keep the generic CONTROL layout" (SPEC §7.2).
        static func set(for token: ForegroundToken?) -> AppActionSet? {
            switch token ?? .generic {
            case .vscode: return vscode
            case .chrome: return chrome
            case .explorer: return explorer
            case .generic: return nil
            }
        }
    }

    /// Link state shown on the Settings screen.
    enum WindowsLinkState {
        case disconnected
        case connecting
        case connected
    }

    /// One decoded helper notification. Before authentication the helper only sends the credential
    /// reply (`paired`, carrying `secret`); afterwards it only ever sends
    /// `{"type":"foreground-changed","identity":"<token>"}`.
    private struct HelperMessage: Decodable {
        let type: String?
        let secret: String?
        let identity: String?
    }

    /// The 32-byte shared secret issued by the helper's `paired` reply is kept in the Keychain
    /// only. Unlike the host/port/fingerprint configuration it is never written to UserDefaults.
    enum ForegroundSecretStore {
        private static let service = "io.github.jqssun.btremote.windows-foreground"
        private static let account = "device-secret"

        /// Stores the helper-issued 32-byte secret in the Keychain. Returns `false` when the item
        /// could not be written. Fail-closed: the caller must then drop the link instead of
        /// reporting a paired state whose credential cannot be read back on the next reconnect.
        @discardableResult
        static func write(base64 secret: String) -> Bool {
            guard let data = secret.data(using: .utf8) else { return false }
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
        }

        static func read() -> String? {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: kCFBooleanTrue!,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let secret = String(data: data, encoding: .utf8)
            else { return nil }
            return secret
        }

        static func clear() {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    /// iPad side of SPEC §7.2: opens a WSS connection to the Windows `WindowsForeground` helper,
    /// pins its self-signed certificate by SHA-256 fingerprint, authenticates with the one-time
    /// pairing code, stores the returned 32-byte shared secret in the Keychain and reconnects with
    /// it later. Only `foreground-changed` tokens are consumed; any disconnect, error or unknown
    /// token leaves the CONTROL surface on the generic layout.
    @MainActor
    final class WindowsForegroundClient: NSObject, ObservableObject, URLSessionDataDelegate {
        /// Single instance: the helper serves one device per run and the secret is device-scoped,
        /// so the Settings form and the CONTROL surface must share one client.
        nonisolated(unsafe) static let shared = WindowsForegroundClient()

        /// The Windows application the helper last reported; `nil` keeps the generic layout.
        @Published private(set) var token: ForegroundToken?
        @Published private(set) var state: WindowsLinkState = .disconnected
        @Published private(set) var lastError: String?

        /// Written on MainActor before the socket is opened and read from the nonisolated TLS
        /// challenge handler below; hence `nonisolated(unsafe)`. Already normalized (no spaces or
        /// colons, lower-case hex).
        nonisolated(unsafe) private var pinnedFingerprint = ""

        private var session: URLSession?
        private var task: URLSessionWebSocketTask?
        private var receiveTask: Task<Void, Never>?

        /// A stored secret means this iPad already paired with this helper, so the next connection
        /// authenticates with the secret and needs no new pairing code.
        var hasStoredSecret: Bool { ForegroundSecretStore.read() != nil }

        /// Opens the link using the host/port/fingerprint saved by the Settings form. Reconnects
        /// with the stored secret when one exists; otherwise pairs with the one-time code the user
        /// read off the Windows console.
        func connect(code: String = "") async {
            disconnect()
            let defaults = UserDefaults.standard
            let host = Self.trimming(defaults.string(forKey: AppSettings.windowsHostKey) ?? "")
            let port = Self.trimming(defaults.string(forKey: AppSettings.windowsPortKey) ?? AppSettings.defaultWindowsPort)
            pinnedFingerprint = Self.normalized(defaults.string(forKey: AppSettings.windowsFingerprintKey) ?? "")
            guard !host.isEmpty, !port.isEmpty, !pinnedFingerprint.isEmpty else {
                lastError = "Enter the private IP, port and certificate SHA-256 fingerprint printed by the Windows helper."
                return
            }
            let secret = ForegroundSecretStore.read()
            let credential: String?
            if let secret, !secret.isEmpty {
                credential = "{\"type\":\"reconnect\",\"secret\":\"\(secret)\"}"
            } else if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                credential = "{\"type\":\"pair\",\"code\":\"\(code.trimmingCharacters(in: .whitespacesAndNewlines))\"}"
            } else {
                credential = nil
            }
            guard let credential else {
                lastError = "Enter the one-time code printed by the Windows helper, then tap Connect."
                return
            }
            guard let url = URL(string: "wss://\(host):\(port)") else {
                lastError = "That Windows helper address is not valid."
                return
            }
            state = .connecting
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            self.session = session
            let task = session.webSocketTask(with: url)
            self.task = task
            task.resume()
            do {
                // The helper waits at most 5 s for the exact credential frame and sends no
                // application data before it has verified it, so the request is sent before
                // anything is received.
                try await task.send(.string(credential))
                let reply = try await task.receive()
                guard case let .string(text) = reply,
                      let data = text.data(using: .utf8),
                      let decoded = try? JSONDecoder().decode(HelperMessage.self, from: data),
                      let kind = decoded.type
                else {
                    fail("Unexpected reply from the Windows helper.")
                    return
                }
                if kind == "paired" {
                    // Provision the durable credential only when it really is the 32 bytes
                    // (256 bit) the helper's pair flow writes.
                    guard let secret = decoded.secret,
                          let raw = Data(base64Encoded: secret),
                          raw.count == 32
                    else {
                        fail("The Windows helper did not return a 32-byte secret.")
                        return
                    }
                    // Fail-closed: if the secret cannot be written to the Keychain the link is not
                    // usable later (reconnect authenticates with that secret), so report an error
                    // and leave CONTROL on the generic layout instead of claiming it is connected.
                    guard ForegroundSecretStore.write(base64: secret) else {
                        fail("Could not store the Windows helper credentials on this device. Pair again from the Windows helper.")
                        return
                    }
                } else if kind != "reconnected" {
                    fail("Unexpected reply from the Windows helper.")
                    return
                }
                state = .connected
                lastError = nil
                startReceiving(from: task)
            } catch {
                fail("Cannot reach the Windows helper at \(host):\(port).")
            }
        }

        /// Stops the link; CONTROL falls back to the generic layout (SPEC §7.2).
        func disconnect() {
            closeSocket()
            token = nil
            state = .disconnected
            lastError = nil
        }

        private func startReceiving(from task: URLSessionWebSocketTask) {
            receiveTask?.cancel()
            receiveTask = Task { [weak self] in
                guard let self else { return }
                do {
                    while !Task.isCancelled {
                        let message = try await task.receive()
                        guard case let .string(text) = message,
                              let data = text.data(using: .utf8),
                              let decoded = try? JSONDecoder().decode(HelperMessage.self, from: data),
                              decoded.type == "foreground-changed",
                              let identity = decoded.identity
                        else { continue }
                        // Consume only `foreground-changed`; an unknown token means generic.
                        self.token = ForegroundToken(rawValue: identity) ?? .generic
                    }
                } catch {
                    self.closeSocket()
                    self.token = nil
                    self.state = .disconnected
                    self.lastError = "Lost the connection to the Windows helper."
                }
            }
        }

        private func closeSocket() {
            receiveTask?.cancel()
            receiveTask = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            session?.invalidateAndCancel()
            session = nil
        }

        private func fail(_ message: String) {
            closeSocket()
            token = nil
            state = .disconnected
            lastError = message
        }

        // MARK: URLSessionDataDelegate
        // These must stay `nonisolated`: the TLS challenge has to be answered inline, and only
        // value types and `UserDefaults` are touched here, never MainActor-isolated state.

        nonisolated func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            // SPEC §7.2: the helper's certificate is self-signed precisely so it can be pinned.
            // Accept it only when the SHA-256 digest of its leaf certificate equals the
            // fingerprint the helper printed and the user entered; otherwise send no credential.
            guard challenge.protectionSpace.authenticationMethod == URLSession.AuthenticationMethod.serverTrust,
                  let trust = challenge.protectionSpace.serverTrust,
                  let certificate = SecTrustGetCertificateAtIndex(trust, 0)
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            let der = SecCertificateCopyData(certificate) as Data
            let digest = SHA256.hash(data: der)
            var hash = ""
            for byte in digest { hash += String(format: "%02x", byte) }
            guard hash == pinnedFingerprint else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        nonisolated private static func trimming(_ value: String) -> String {
            value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// Accepts the fingerprint whether the helper printed it as plain hex or colon-separated
        /// upper-case hex.
        nonisolated private static func normalized(_ raw: String) -> String {
            raw.replacingOccurrences(of: ":", with: "")
                .replacingOccurrences(of: " ", with: "")
                .lowercased()
        }
    }

    // MARK: - SPEC §7.2 G — Windows helper connection settings (iPad side)

    /// Compact settings section for the Windows `WindowsForeground` helper: the Windows PC address,
    /// port and pinned certificate fingerprint, the one-time pairing code, Connect / Reconnect and
    /// Disconnect / Unpair controls with live connected-or-error status, and the three user-defined
    /// app-layout shortcuts (three VS Code/browser targets and three optional Explorer targets). It
    /// configures `WindowsForegroundClient.shared`, the same instance the
    /// CONTROL surface renders from, so there is exactly one link and one stored secret.
    struct WindowsForegroundSettingsView: View {
        @StateObject private var windows = WindowsForegroundClient.shared
        @AppStorage(AppSettings.windowsHostKey) private var windowsHost = ""
        @AppStorage(AppSettings.windowsPortKey) private var windowsPort = AppSettings.defaultWindowsPort
        @AppStorage(AppSettings.windowsFingerprintKey) private var windowsFingerprint = ""
        @AppStorage(AppSettings.frostPiShortcutKey) private var frostPiShortcut = ""
        @AppStorage(AppSettings.sideChatAIShortcutKey) private var sideChatAIShortcut = ""
        @AppStorage(AppSettings.quickOpenBrowserTabShortcutKey) private var quickOpenBrowserTabShortcut = ""
        @AppStorage(AppSettings.thisPCShortcutKey) private var thisPCShortcut = ""
        @AppStorage(AppSettings.documentsShortcutKey) private var documentsShortcut = ""
        @AppStorage(AppSettings.downloadsShortcutKey) private var downloadsShortcut = ""
        /// The one-time code read off the Windows console. Entry only: it is never persisted, and
        /// after a successful pair the client reuses the secret held in the Keychain instead.
        @State private var pairingCode = ""

        @ViewBuilder
        var body: some View {
            Section(
                header: Text("Windows helper"),
                footer: Text("Enter the address, port and certificate fingerprint shown by the Windows helper, then the one-time code printed by it. The secret it returns is stored in the Keychain, so later connections reconnect without a new code. This is only needed for the app-specific Windows layouts; the normal Bluetooth remote does not use it.")
            ) {
                TextField("Windows PC address (private IP)", text: $windowsHost)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Port", text: $windowsPort)
                    .keyboardType(.numberPad)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Certificate SHA-256 fingerprint", text: $windowsFingerprint)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("One-time pairing code", text: $pairingCode)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                HStack {
                    Text(verbatim: statusText)
                        .foregroundColor(windows.state == .connected ? .primary : .secondary)
                    Spacer()
                    if windows.state == .connecting {
                        ProgressView()
                    } else if windows.state == .connected {
                        Button("Disconnect") {
                            pairingCode = ""
                            Task { @MainActor in WindowsForegroundClient.shared.disconnect() }
                        }
                    } else {
                        Button(windows.hasStoredSecret ? "Reconnect" : "Connect") {
                            let code = pairingCode
                            Task { @MainActor in await WindowsForegroundClient.shared.connect(code: code) }
                        }
                    }
                }
                if let lastError = windows.lastError {
                    Text(verbatim: lastError)
                        .font(.footnote)
                        .foregroundColor(.red)
                }
                if windows.hasStoredSecret {
                    Button(role: .destructive) {
                        pairingCode = ""
                        Task { @MainActor in
                            WindowsForegroundClient.shared.disconnect()
                            ForegroundSecretStore.clear()
                        }
                    } label: {
                        Label("Unpair and forget this helper", systemImage: "trash")
                    }
                }
            }
            Section(
                header: Text("User-defined shortcuts"),
                footer: Text("For the project-specific VS Code targets (Frost Pi, SideChatAI, Quick Open Browser Tab). Enter one chord per target, for example Ctrl+Shift+P or F5. A target with no chord stays disabled and sends nothing; a configured chord is sent through the existing keyboard key path to the Windows app in focus. Nothing here is fixed: change the chord for a different project without a code change. The last three targets are optional chords for the Windows helper's File Explorer actions: enter a chord or leave the field empty, no folder paths are stored or assumed here.")
            ) {
                TextField("Frost Pi (e.g. Ctrl+Shift+P)", text: $frostPiShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("SideChatAI (e.g. Alt+Shift+S)", text: $sideChatAIShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Quick Open Browser Tab (e.g. Ctrl+Shift+B)", text: $quickOpenBrowserTabShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("This PC (optional chord, no path)", text: $thisPCShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Documents (optional chord, no path)", text: $documentsShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                TextField("Downloads (optional chord, no path)", text: $downloadsShortcut)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
            }
        }

        /// Generic status line: state, plus the last Windows application the helper reported.
        /// `@MainActor` because it reads the client's `@Published` state (`WindowsForegroundClient`
        /// is a `@MainActor` class).
        @MainActor private var statusText: String {
            switch windows.state {
            case .disconnected:
                return "Windows helper: not connected"
            case .connecting:
                return "Windows helper: connecting…"
            case .connected:
                if let token = windows.token {
                    switch token {
                    case .vscode: return "Windows helper: connected — VS Code"
                    case .chrome: return "Windows helper: connected — Chrome/Edge"
                    case .explorer: return "Windows helper: connected — File Explorer"
                    case .generic: return "Windows helper: connected — no known app"
                    }
                }
                return "Windows helper: connected — waiting for the foreground app"
            }
        }
    }
#endif

// MARK: - SPEC §7.2 F — user-defined target shortcuts

/// SPEC §7.2 F: the project-specific targets (`Frost Pi`, `SideChatAI`, `Quick Open Browser Tab`
/// and any similar target) are data, not code. Each keycap carries the app-settings key holding the
/// single chord the user entered for it, so no path, command or keystroke sequence is hard-coded
/// and a different project's targets need no code change. Only chords built from existing keycodes
/// and the existing single-key HID report are accepted; a blank or unparseable chord produces no
/// reports, so the keycap is a no-op.
enum UserTargets {
    /// Chord names accepted in the Settings shortcut fields, mapped onto keycodes that already
    /// exist in the HID key tables (no new keycodes).
    private static let keyNames: [String: Keycode] = [
        "enter": .return, "return": .return,
        "esc": .escape, "escape": .escape,
        "tab": .tab, "space": .space, "backspace": .backspace,
        "delete": .delete, "insert": .insert, "home": .home, "end": .end,
        "pageup": .pageUp, "pagedown": .pageDown,
        "up": .upArrow, "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
        "f1": .f1, "f2": .f2, "f3": .f3, "f4": .f4, "f5": .f5, "f6": .f6,
        "f7": .f7, "f8": .f8, "f9": .f9, "f10": .f10, "f11": .f11, "f12": .f12,
    ]

    /// Modifier names accepted in the Settings shortcut fields (left-hand HID modifiers only — the
    /// only modifier set the shipped HID keyboard reports already use).
    private static let modifierNames: [String: KeyboardModifiers] = [
        "ctrl": .leftCtrl, "control": .leftCtrl,
        "shift": .leftShift,
        "alt": .leftAlt, "option": .leftAlt,
        "win": .leftGUI, "windows": .leftGUI, "cmd": .leftGUI, "command": .leftGUI, "meta": .leftGUI,
    ]

    /// The chord the user configured for the target whose app-settings key the keycap carries.
    /// Blank when the user has not configured that target.
    static func chord(forSettingsKey settingsKey: String) -> String {
        (UserDefaults.standard.string(forKey: settingsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parses one user-entered chord such as `Ctrl+Shift+P` into the existing HID key reports for
    /// it. Everything before the last token is a modifier name; the last token is a key name or a
    /// single ASCII character resolved by the existing `HIDInput` ASCII mapping. An empty or
    /// unparseable chord returns an empty array, i.e. the action sends nothing.
    static func keyReports(forChord chord: String) -> [KeyboardReport] {
        let tokens = chord
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard let keyName = tokens.last else { return [] }
        var modifiers: KeyboardModifiers = []
        for name in tokens.dropLast() {
            guard let modifier = modifierNames[name] else { return [] }
            modifiers.insert(modifier)
        }
        if let key = keyNames[keyName] {
            return [KeyboardReport(modifiers: modifiers, keys: [key]), .zero]
        }
        if keyName.count == 1, let character = keyName.first {
            return HIDInput.keyReports(for: character, adding: modifiers)
        }
        return []
    }
}
