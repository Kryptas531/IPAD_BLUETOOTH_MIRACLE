# docs/ARCHITECTURE.md — карта upstream + защищённая граница

## Карта (проверено чтением файлов, HEAD `0bccedc`)
- `BTRemote/BTRemoteApp.swift` — @main; iOS: `HIDPeripheral` + `HIDCentral` +
  `DeviceNameStore`, `ContentView`; `onAppear`: `central.start()` +
  `if autoAdvertise { lowEnergy.start() }` — iPad автоматически advertise'ит
  HID-сервис (Windows видит iPad как BT keyboard+mouse, Windows-сервер не нужен).
- `BTRemote/ContentView.swift` — TabView Setup/Remote/Settings; при старте —
  Setup; при `hid.isConnected` авто-переход на Remote.
- `BTRemote/RemoteTabView.swift` — переключатель keyboard/remote (menu);
  keyboard → `KeyboardView`.
- `BTRemote/KeyboardView.swift` — target screen: TextField + клавиши
  (F1–F12, ESC, TAB, arrows, BACKSPACE, ENTER, SHIFT, META/CMD(=WIN GUI),
  CTRL, ALT, SPACE) + `TrackpadPanel`.
- `BTRemote/TouchpadView.swift` — только iOS; TRACKPAD остаётся gesture-based,
  а GAME использует `touchesBegan`, `touchesMoved`, `touchesEnded` и
  `UIEvent.coalescedTouches(for:)` без predicted touches.
- `BTRemote/TrackpadPanel.swift` — доминирующая surface без постоянной
  scroll-column/L-M-R row; gestures заменяют эти controls. В developer mode
  GAME показывает rolling runtime metrics overlay.
- `BTRemote/PerformanceMetrics.swift` — rolling one-second input/BLE counters,
  sample interval/jitter и pending/coalesced/lost-delta counters.
- `BTRemote/HIDInput.swift` — UI→HID router: `tap(key:modifiers:)`, `type(char)`,
  `click(.left/.right)`, `move(dx:dy:)`, `scroll(wheel)`,
  `keyReports(for: .tab, modifiers: .leftAlt)` (ALT+TAB без правки стека);
  ASCII→keycode map (`mapASCII`/`_symbolKeys`).
- `BTRemote/LowEnergy/*` — BLE/HOGP (iOS+macOS backend): `HIDPeripheral`
  (CBPeripheralManager, HID service 0x1812, Report Map, Protocol Mode, Boot
  Keyboard I/O, report references, `*EncryptionRequired`, bootstrap report при
  subscribe; `sendMouse/sendKeyboard/sendConsumer/sendSystemControl`),
  `HIDProfile` (UUIDs + 239-byte report map), `HIDReports` (MouseReport,
  KeyboardReport 8 bytes, ConsumerReport, Keycode enum), `HIDCentral`.
- `BTRemote/Classic/*` — macOS-only backend (IOBluetooth SDP/L2CAP,
  `HIDClassicDevice`, `SDPRecord`); Windows через HIDP не поддерживается
  (README upstream) — для нашей цели (iPad→Windows) используется **LowEnergy**.
- `BTRemote/SetupView.swift`, `DeviceListView.swift`, `DeviceInfoView.swift`,
  `DeviceRow.swift`, `DeviceNameStore.swift` — pairing/setup UI + список
  устройств + статус (BT state, advertising, HID service, подписки).
- `BTRemote/DirectInputController.swift` — Direct Input для физической
  Windows-клавиатуры через iPad: iOS-ветка (`#elseif os(iOS)`) — capture через
  `GCKeyboard.coalesced` / `GCMouse.current` (GameController); release chord
  `Ctrl + Alt + Backspace` (default `ReleaseChord.defaultChord`, configurable
  через `AppSettings`); macOS-ветка — event tap + Accessibility capture.
  IMPLEMENTED (код в main, CI VERIFIED). `BTRemote/Controls.swift` —
  `HoldButton`/`PressGesture`.
  `BTRemote/DPadView.swift` — legacy TV control, больше не используется DECK.
  `BTRemote/RemoteView.swift` — Windows-first DECK grid с двумя страницами.
  `BTRemote/AppSettings.swift`, `BluetoothNumbers.swift`,
  `AccessibilityPermission.swift` — настройки/константы/доступность.
  `BTRemote/L10n.swift` + `Localizable.xcstrings` + `InfoPlist.xcstrings` —
  локализация (новые строки MVP => добавлять сюда).
  `BTRemote/Info.plist`, `BTRemote/entitlements.plist` — конфиг-кандидат
  (содержимое не читалось — зона ci-worker).

## Защищённая граница (не трогать без отдельного задания LEAD)
- `BTRemote/LowEnergy/` (весь) — CBPeripheralManager / GATT tree / HID report
  descriptors / report subscription+bootstrap / encryption+bonding.
- `BTRemote/Classic/` (весь) — IOBluetooth SDP backend (macOS).
- `BTRemote/HIDInput.swift` — UI→HID routing, ASCII map.
- `BTRemote/BluetoothNumbers.swift`, `BTRemote/Resources/` (json) — json
  нет в git, во время CI их скачивает `ci_scripts/ci_post_clone.sh` (проверено).
  Статус сборки — см. «Build verification» ниже.
- Причина: README upstream — «changes to this stack are highly discouraged /
  likely to break SDP negotiation, GATT layout, bonding handshake, no clear
  error logs».

## Build/CI (факты прочитаны)
- `project.yml` — XcodeGen: target `BTRemote` supportedDestinations [iOS,
  macOS], SWIFT_VERSION 6.0 strict concurrency, iOS target 15.0,
  `GENERATE_INFOPLIST_FILE: NO` + `BTRemote/Info.plist`; ресурсы:
  `BTRemote/Resources/company_ids.json`, `service_uuids.json` — в git НЕ
  коммитятся (в `Resources/` только `.gitignore`); во время CI их скачивает
  `ci_scripts/ci_post_clone.sh` из `NordicSemiconductor/bluetooth-numbers-database`
  (файл прочитан — подтверждено).
- `build.sh` — `ci_scripts/ci_post_clone.sh`; swiftformat/swiftlint;
  xcodebuild macOS + `-sdk iphoneos generic/platform=iOS`
  `CODE_SIGNING_ALLOWED=NO`; package: `Payload/<app>.app` → zip →
  `BTRemote.ipa` (t.u. unsigned IPA build путь УЖЕ прописан, но требует
  macOS-runner; `.xcodeproj` генерируется, не коммитится).
- `.github/workflows/build.yml` — существует (детали читает ci-worker).
- Среда разработки (Windows): `swift`/`xcodebuild` — НЕТ; `git`/`node` —
  есть; `gh` — `C:\LIFE\gh.exe` (авторизован, рабочий вызов проверен).
  Build-верификация возможна только через GitHub Actions macOS runner
  (подтверждено: green CI run `35511332912`, head `0bccedc`).

## Build verification (обновлено 2026-09-20)
P0 warning закрыт: `project.yml` ссылается на отсутствующие в git ресурсы
`BTRemote/Resources/*.json` — их скачивает `ci_scripts/ci_post_clone.sh` во
время CI (проверено чтением файла). Локальная сборка/генерация проекта на
Windows невозможна в принципе (нет Xcode/swift). Статус сборки: **CI VERIFIED**
— green CI run `35511332912` (head `0bccedc`), artifact
`btr-remote-unsigned-ipa`. Компиляцию более новых правок нельзя утверждать
без нового CI run.
