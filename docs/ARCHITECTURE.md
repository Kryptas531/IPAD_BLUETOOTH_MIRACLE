# docs/ARCHITECTURE.md — карта upstream + защищённая граница

## Карта (проверено чтением файлов)
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
- `BTRemote/TouchpadView.swift` — только iOS; жесты: 1-finger pan = move,
  1-finger tap = left click, 2-finger tap = right click, 2-finger pan = scroll
  (via `HIDInput.move/scroll/click` + `HIDInput.clamp`).
- `BTRemote/TrackpadPanel.swift` — поверхность + mouse L/M/R кнопки + scroll
  up/down (вызывает `hid.move/scroll/click`).
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
- `BTRemote/DirectInputController.swift` (macOS-only, Accessibility capture) —
  Phase 2, не трогать. `BTRemote/Controls.swift` — `HoldButton`/`PressGesture`.
  `BTRemote/DPadView.swift` — TV remote controls (не MVP).
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
- `BTRemote/BluetoothNumbers.swift`, `BTRemote/Resources/` (json) — см. P0
  warning ниже.
- Причина: README upstream — «changes to this stack are highly discouraged /
  likely to break SDP negotiation, GATT layout, bonding handshake, no clear
  error logs».

## Build/CI (факты прочитаны)
- `project.yml` — XcodeGen: target `BTRemote` supportedDestinations [iOS,
  macOS], SWIFT_VERSION 6.0 strict concurrency, iOS target 15.0,
  `GENERATE_INFOPLIST_FILE: NO` + `BTRemote/Info.plist`; ресурсы:
  `BTRemote/Resources/company_ids.json`, `service_uuids.json` (**файлов нет в
  git — только `Resources/.gitignore`**; потенциальный build blocker; источник
  UNKNOWN — вероятно генерирует `ci_scripts/ci_post_clone.sh`).
- `build.sh` — `ci_scripts/ci_post_clone.sh`; swiftformat/swiftlint;
  xcodebuild macOS + `-sdk iphoneos generic/platform=iOS`
  `CODE_SIGNING_ALLOWED=NO`; package: `Payload/<app>.app` → zip →
  `BTRemote.ipa` (t.u. unsigned IPA build путь УЖЕ прописан, но требует
  macOS-runner; `.xcodeproj` генерируется, не коммитится).
- `.github/workflows/build.yml` — существует (детали читает ci-worker).
- Среда разработки (Windows): `swift`/`xcodebuild`/`gh` — НЕТ; `git`/`node`
  — есть. Build-верификация возможна только через GitHub Actions macOS runner.

## P0 warning
`project.yml` ссылается на отсутствующие ресурсы (`BTRemote/Resources/*.json`);
локальная сборка/генерация проекта на Windows невозможна в принципе. До push +
CI-прогона нельзя утверждать «build passes».
