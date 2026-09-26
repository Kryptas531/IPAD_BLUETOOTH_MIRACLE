import Foundation
import SwiftUI

#if os(iOS)
    import CryptoKit
    import Security

    // MARK: - SPEC §7.2 — Windows foreground helper (iPad side)

    /// One user-configurable per-app CONTROL action: a label plus one of the HID sends the CONTROL
    /// surface already knows how to emit (SPEC §7.2). Actions are data, not view code, so a user's
    /// own VS Code target, key bindings or extra app mappings are configured in the layout
    /// document (`AppLayouts`) instead of being hard-coded in the view. Every entry reuses an
    /// existing keycap action; no new keycodes and no new HID reports are introduced.
    struct AppActionSet {
        let title: String
        let keys: [KeyCap]
    }

    /// SPEC §7.2 F: the app-specific action sets are **data**, not hard-coded view code.
    /// `defaultJSON` is the shipped document (the canonical three executable→layout mappings and
    /// their labelled action sets); `document()` returns the user's own edited or extended JSON
    /// when it parses, so adding an app/executable-to-layout mapping and editing, adding, renaming
    /// or reordering its labelled actions needs no source change. Every field is a `String` or an
    /// array of `String`, so no non-Sendable `LocalizedStringKey` is held in a stored static
    /// property (Swift 6 strict concurrency).
    enum AppLayouts {
        /// The reserved identity meaning "no app layout, keep the §7.1 generic CONTROL surface"
        /// (the Windows helper's `ForegroundMapping.GenericToken`). It is a wire fallback, never a
        /// usable profile id, so a malformed document that still contains a profile with that id
        /// cannot replace the generic layout.
        static let genericToken = "generic"

        /// The shipped default document: the canonical three mappings and their required action
        /// sets, with the exact SPEC §7.2 F labels and the six project/folder targets left
        /// unconfigured (`"settings"` points at the app-settings field the user fills in).
        /// The same JSON text is shipped by the Windows helper as `ForegroundMapping.DefaultJson`
        /// (`companion/WindowsForeground/ForegroundMapping.cs`), which writes it to
        /// `%LOCALAPPDATA%\iPadForegroundHelper\profiles.json` on first run, so the file the user
        /// edits on Windows can be copied verbatim into the iPad's "App layouts (JSON)" editor.
        /// The two copies must stay identical.
        static let defaultJSON = #"""
        {
          "profiles": [
            {
              "id": "vscode",
              "title": "VS Code",
              "executables": ["Code.exe"],
              "actions": [
                { "label": "New Window", "chord": "Ctrl+Shift+N" },
                { "label": "Open Folder", "sequence": ["Ctrl+K", "Ctrl+O"] },
                { "label": "Frost Pi", "settings": "BTRemote.shortcutFrostPi" },
                { "label": "SideChatAI", "settings": "BTRemote.shortcutSideChatAI" },
                { "label": "Explorer", "chord": "Ctrl+Shift+E" },
                { "label": "Source Control", "chord": "Ctrl+Shift+G" },
                { "label": "New Terminal", "chord": "Ctrl+`" },
                { "label": "Close Saved", "chord": "Ctrl+W" },
                { "label": "Split Editor Right", "chord": "Ctrl+\\" },
                { "label": "Move to the editor", "chord": "Ctrl+1" },
                { "label": "Quick Open Browser Tab", "settings": "BTRemote.shortcutQuickOpenBrowserTab" }
              ]
            },
            {
              "id": "chrome",
              "title": "Chrome",
              "executables": ["chrome.exe"],
              "actions": [
                { "label": "New Tab", "chord": "Ctrl+T" },
                { "label": "Close Tab", "chord": "Ctrl+W" },
                { "label": "Reload", "chord": "Ctrl+R" },
                { "label": "Focus Address Bar", "chord": "Ctrl+L" },
                { "label": "Back", "chord": "Alt+Left" },
                { "label": "Forward", "chord": "Alt+Right" },
                { "label": "History", "chord": "Ctrl+H" },
                { "label": "Show Bookmarks", "chord": "Ctrl+Shift+B" },
                { "label": "Full Screen", "chord": "F11" }
              ]
            },
            {
              "id": "explorer",
              "title": "File Explorer",
              "executables": ["explorer.exe"],
              "actions": [
                { "label": "New Window", "chord": "Ctrl+N" },
                { "label": "New Tab", "chord": "Ctrl+T" },
                { "label": "This PC", "settings": "BTRemote.shortcutThisPC" },
                { "label": "Documents", "settings": "BTRemote.shortcutDocuments" },
                { "label": "Downloads", "settings": "BTRemote.shortcutDownloads" },
                { "label": "Search", "chord": "Ctrl+E" },
                { "label": "Select All", "chord": "Ctrl+A" },
                { "label": "New Folder", "chord": "Ctrl+Shift+N" },
                { "label": "Rename", "chord": "F2" }
              ]
            }
          ]
        }
        """#

        /// The document the app actually uses: the user's edited JSON when it parses, otherwise
        /// the shipped defaults. Unparsable user JSON falls back to the shipped defaults, so
        /// CONTROL is never left without a usable action set.
        static func document() -> LayoutDocument {
            if let stored = UserDefaults.standard.string(forKey: AppSettings.layoutProfilesKey),
               let data = stored.data(using: .utf8),
               let parsed = try? JSONDecoder().decode(LayoutDocument.self, from: data) {
                return parsed
            }
            return defaultDocument
        }

        /// The set matching the identity the helper reported (`vscode` | `chrome` | `explorer`, or
        /// a user-defined profile id). `nil` for no link, an unknown identity, or `generic`, i.e.
        /// "keep the generic CONTROL layout" (SPEC §7.2 E). The reserved `generic` identity is
        /// matched before the user's document, so a user profile cannot claim it.
        static func set(for identity: String?) -> AppActionSet? {
            let wanted = (identity ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !wanted.isEmpty else { return nil }
            if wanted.caseInsensitiveCompare(genericToken) == .orderedSame { return nil }
            let document = document()
            guard let profile = document.profiles.first(where: {
                $0.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(wanted) == .orderedSame
            }) else { return nil }
            return AppActionSet(title: profile.title, keys: profile.actions.map { $0.keyCap() })
        }

        /// The shipped defaults, decoded from `defaultJSON`. If that ever failed to decode the app
        /// still works: an empty document simply means "always the generic §7.1 layout".
        static var defaultDocument: LayoutDocument {
            (try? JSONDecoder().decode(LayoutDocument.self, from: Data(defaultJSON.utf8)))
                ?? LayoutDocument()
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
    /// it later. Only `foreground-changed` identities are consumed; any disconnect, error or
    /// unknown identity leaves the CONTROL surface on the generic layout.
    @MainActor
    final class WindowsForegroundClient: NSObject, ObservableObject, URLSessionDataDelegate {
        /// Single instance: the helper serves one device per run and the secret is device-scoped,
        /// so the Settings form and the CONTROL surface must share one client.
        nonisolated(unsafe) static let shared = WindowsForegroundClient()

        /// The Windows application identity the helper last reported (`vscode` | `chrome` |
        /// `explorer` | `generic` | a user-defined profile id); `nil` keeps the generic layout.
        /// SPEC §7.2 F: this is a lookup key into the user's layout document, not an enum, so a new
        /// app mapping needs no Swift change.
        @Published private(set) var identity: String?
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
            identity = nil
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
                        // Consume only `foreground-changed`; an unknown identity means generic.
                        // The value is the profile id the user configured, matched case-insensitively
                        // by `AppLayouts.set(for:)`; `generic` (or anything unknown) has no profile,
                        // so CONTROL keeps the §7.1 layout.
                        self.identity = decoded.identity
                    }
                } catch {
                    self.closeSocket()
                    self.identity = nil
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
            identity = nil
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
        /// SPEC §7.2 F: the whole user-configurable layout document (the executable→layout
        /// mappings plus their labelled actions). Seeded with the shipped defaults, which the user
        /// edits instead of changing any Swift or Windows helper source.
        @AppStorage(AppSettings.layoutProfilesKey) private var layoutJSON = AppLayouts.defaultJSON
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
                footer: Text("For the project-specific VS Code targets (Frost Pi, SideChatAI, Quick Open Browser Tab). Enter one chord per target, for example Ctrl+Shift+P or F5. A target with no chord stays disabled and sends nothing; a configured chord is sent through the existing keyboard key path to the Windows app in focus. Nothing here is fixed: change the chord for a different project without a code change. The last three targets are optional chords for the Windows helper's File Explorer actions: enter a chord or leave the field empty, no folder paths are stored or assumed here. These six fields are the \"settings\" targets referenced by the shipped App layouts (JSON) document below; any new target you add there states its own chord, sequence or text instead.")
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
            Section(
                header: Text("App layouts (JSON)"),
                footer: Text("Everything the Windows helper can select, and every labelled action each layout offers, as one JSON document. Edit it to add an app/executable-to-layout mapping or to add, rename, reorder or retarget an action; no code change is needed. Each profile has an id (the token the helper reports: one safe token of ASCII letters, digits, '_', '-' or '.', and never the reserved id 'generic'), a title, the executable file names that select it, and an ordered actions array. Each action has a label and exactly one target: \"chord\" (one chord, e.g. Ctrl+Shift+P), \"sequence\" (ordered chords, e.g. [\"Ctrl+K\", \"Ctrl+O\"]) or \"text\" (a literal string or path to type). A target left empty stays disabled and sends nothing; the six fields above are the \"settings\" targets of the shipped document. Keep this document identical to the profiles.json the Windows helper writes (%LOCALAPPDATA%\\iPadForegroundHelper\\profiles.json), because the helper only reports executables it has configured. If the JSON cannot be parsed the app falls back to the shipped VS Code / Chrome / File Explorer document and the generic §7.1 layout.")
            ) {
                TextEditor(text: $layoutJSON)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 240)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                Button("Restore shipped layouts") {
                    layoutJSON = AppLayouts.defaultJSON
                }
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
                // The reported value is a profile id from the user's own layout document, so it is
                // shown verbatim; an empty/unknown one means the §7.1 generic layout. The reserved
                // `generic` id is never looked up in the document (SPEC §7.2 B/F).
                if let rawIdentity = windows.identity, !rawIdentity.isEmpty {
                    let identity = rawIdentity.trimmingCharacters(in: .whitespacesAndNewlines)
                    let isGeneric = identity.caseInsensitiveCompare(AppLayouts.genericToken) == .orderedSame
                    if !isGeneric,
                       let title = AppLayouts.document().profiles
                           .first(where: { $0.id.caseInsensitiveCompare(identity) == .orderedSame })?
                           .title, !title.isEmpty {
                        return "Windows helper: connected — \(title)"
                    }
                    return "Windows helper: connected — \(identity)"
                }
                return "Windows helper: connected — waiting for the foreground app"
            }
        }
    }
#endif

// MARK: - SPEC §7.2 F — user-configurable layout data (a JSON document, not code)

/// One user-configurable action of an app layout: a label plus exactly one HID-compatible target.
/// `chord` is a single chord (`"Ctrl+Shift+P"`, `"F5"`), `sequence` an ordered list of chords
/// (`["Ctrl+K", "Ctrl+O"]`), `text` a literal string/path to type, and `settings` the app-settings
/// key of one of the six user-defined project/folder target fields. Only targets that resolve to
/// existing HID key reports may be used; an unconfigured or unparseable target sends nothing.
/// The JSON shape of this struct is the documented schema shared with the Windows helper
/// (`companion/WindowsForeground/ForegroundMapping.cs`), so a new target needs no Swift change.
struct LayoutAction: Codable, Equatable, Sendable {
    var label: String = ""
    var chord: String? = nil
    var sequence: [String]? = nil
    var text: String? = nil
    var settings: String? = nil
}

/// One user-configurable executable→layout mapping: `id` is the token the Windows helper reports
/// (SPEC §7.2 B/D), `title` names the layout in the iPad UI, `executables` the executable file
/// names that resolve to it and `actions` the ordered labelled actions it offers.
struct LayoutProfile: Codable, Equatable, Sendable {
    var id: String = ""
    var title: String = ""
    var executables: [String] = []
    var actions: [LayoutAction] = []
}

/// The whole user-configurable configuration: the ordered list of app profiles.
struct LayoutDocument: Codable, Equatable, Sendable {
    var profiles: [LayoutProfile] = []
}

extension LayoutAction {
    /// The existing §7.1 B/C keycap affordance for this configured action: the user's own label
    /// plus the one HID target they chose (`chord`, `sequence`, `text`, or `settings`). The
    /// concrete keystroke target is resolved at press time by `UserTargets`, so no path, command or
    /// keystroke sequence is hard-coded and no new keycode or HID report type is introduced.
    func keyCap() -> KeyCap {
        KeyCap(.verbatim(label), 1, LocalizedStringKey(stringLiteral: label), .layout(self))
    }
}

// MARK: - SPEC §7.2 F — user-defined target shortcuts

/// SPEC §7.2 F: the project-specific targets (`Frost Pi`, `SideChatAI`, `Quick Open Browser Tab`
/// and any similar target) are data, not code. Each action either carries the app-settings key
/// holding the single chord the user entered for it, or states its own chord, chord sequence or
/// literal text. Only targets built from existing keycodes and the existing single-key HID report
/// are accepted; a blank or unparseable target produces no reports, so the action is a no-op and
/// its button stays disabled.
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

    /// The chord the user configured for the target whose app-settings key the action carries.
    /// Blank when the user has not configured that target.
    static func chord(forSettingsKey settingsKey: String) -> String {
        (UserDefaults.standard.string(forKey: settingsKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// SPEC §7.2 F: the HID key reports one user-configured action sends, resolved from whichever
    /// target the user chose in the layout document (`chord`, `sequence`, `text`, or `settings` =
    /// the app-settings key holding the chord). Every report is one the existing HID keyboard path
    /// already produces (`HIDInput.keyReports`); no new keycodes and no new report types. An
    /// unconfigured or unparseable target returns an empty array, i.e. the action sends nothing.
    /// A `sequence` is only dispatched when every listed chord parses and a `text` target only when
    /// every character is mappable; both go through the existing `KeyTypist`, so a sequence or text
    /// target keeps the existing ~20 ms report pacing.
    static func keyReports(for action: LayoutAction) -> [KeyboardReport] {
        if let chord = action.chord {
            return keyReports(forChord: chord)
        }
        if let chords = action.sequence {
            var reports: [KeyboardReport] = []
            for chord in chords {
                let part = keyReports(forChord: chord)
                if part.isEmpty { return [] }
                reports.append(contentsOf: part)
            }
            return reports
        }
        if let text = action.text {
            var reports: [KeyboardReport] = []
            for character in text {
                let part = HIDInput.keyReports(for: character)
                if part.isEmpty { return [] }
                reports.append(contentsOf: part)
            }
            return reports
        }
        if let settingsKey = action.settings {
            return keyReports(forChord: chord(forSettingsKey: settingsKey))
        }
        return []
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
