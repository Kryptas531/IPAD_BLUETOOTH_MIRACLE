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
}
