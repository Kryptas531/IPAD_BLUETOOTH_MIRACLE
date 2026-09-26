import Foundation

enum AppSettings {
    static let touchpadSensitivityKey = "BTRemote.touchpadSensitivity"
    static let scrollSensitivityKey = "BTRemote.scrollSensitivity"
    static let autoAdvertiseKey = "BTRemote.autoAdvertise"
    static let developerModeKey = "BTRemote.developerMode"
    static let useServiceChangedKey = "BTRemote.useServiceChanged"
    static let deviceNamesKey = "BTRemote.deviceNames"
    static let hasSeenWelcomeKey = "BTRemote.hasSeenWelcome"
    static let liveTypingKey = "BTRemote.liveTyping"
    static let remoteModeKey = "BTRemote.remoteMode"
    static let advertisedNameKey = "BTRemote.advertisedName"
    static let padModeKey = "BTRemote.padMode"
    static let gameInputModeKey = "BTRemote.gameInputMode"
    static let gyroSensitivityKey = "BTRemote.gyroSensitivity"
    /// Direct Input release chord, stored as raw values (see ReleaseChord in DirectInputController).
    static let releaseChordKeyKey = "BTRemote.releaseChordKey"
    static let releaseChordModifiersKey = "BTRemote.releaseChordModifiers"
    // SPEC §7.2 Windows foreground helper link. The user enters the Windows host (private IP),
    // the port and the helper's self-signed certificate SHA-256 fingerprint; these are read by
    // WindowsForegroundClient. The 32-byte shared secret is NOT stored here (Keychain only).
    static let windowsHostKey = "BTRemote.windowsHost"
    static let windowsPortKey = "BTRemote.windowsPort"
    static let windowsFingerprintKey = "BTRemote.windowsFingerprint"

    // SPEC §7.2 F: the project-specific targets (`Frost Pi`, `SideChatAI`,
    // `Quick Open Browser Tab`, `This PC`, `Documents`, `Downloads`) are user-defined. Each key
    // stores one chord string the user types in Settings (e.g. "Ctrl+Shift+P"); no target path or
    // keystroke sequence is hard-coded and no default is supplied. A blank value means "not
    // configured": that keycap sends nothing.
    static let frostPiShortcutKey = "BTRemote.shortcutFrostPi"
    static let sideChatAIShortcutKey = "BTRemote.shortcutSideChatAI"
    static let quickOpenBrowserTabShortcutKey = "BTRemote.shortcutQuickOpenBrowserTab"
    static let thisPCShortcutKey = "BTRemote.shortcutThisPC"
    static let documentsShortcutKey = "BTRemote.shortcutDocuments"
    static let downloadsShortcutKey = "BTRemote.shortcutDownloads"

    static let maxAdvertisedNameLength = 26

    static let repoURL = URL(string: "https://github.com/jqssun/darwin-bt-remote")!
    static let instructionsURL = URL(string: "https://github.com/jqssun/darwin-bt-remote/blob/main/README.md")!

    static let defaultPointerSensitivity = 5.0
    static let pointerSensitivityRange = 0.5 ... 10.0
    static let defaultScrollSensitivity = 1.0
    static let scrollSensitivityRange = 0.5 ... 3.0
    /// Gyro sensitivity: HID mouse counts per radian of device rotation (SPEC §5.1 C).
    static let defaultGyroSensitivity = 180.0
    static let gyroSensitivityRange = 20.0 ... 600.0

    /// Fallback port for the Windows foreground helper WSS link (SPEC §7.2); the user normally
    /// enters the port printed by the helper. Stored/compared as a string.
    static let defaultWindowsPort = "8443"
}
