# docs/MVP.md — MVP план и статус

## Цель
MVP: iPad-приложение = Bluetooth HID-over-GATT (HOGP) keyboard+mouse remote для
Windows PC (iPad — BLE HID peripheral; Windows — HID host; Windows-сервер не
нужен). Переиспользуем существующий upstream darwin-bt-remote; BLE/HOGP стек —
защищённая инфраструктура, не рефакторить без доказанной необходимости.

## Обязательные функции — проверено по коду (LEAD read-through)
| # | Требование | Где | Статус |
|---|---|---|---|
| 1 | BLE pairing с Windows | `BTRemoteApp.swift`: `onAppear { central.start(); if autoAdvertise { lowEnergy.start() } }` — iPad advertise'ит HID; Windows подключается как обычный BT-хост | есть (не компилировался) |
| 2 | Relative mouse move | `HIDInput.move(dx:dy:)` → `MouseReport(dX:dY:)`; жест: `TouchpadView` 1-finger pan | есть |
| 3 | Left click | `HIDInput.click(.left)`; tap в `TouchpadView` | есть |
| 4 | Right click | `HIDInput.click(.right)`; two-finger tap; кнопка `.right` | есть |
| 5 | Vertical scroll | `HIDInput.scroll(wheel)`; 2-finger pan в `TouchpadView` | есть |
| 6 | Keyboard input | `KeyboardView` TextField + `KeyTypist`/`HIDInput.type(char)` + ASCII→keycode map (`mapASCII`, `_symbolKeys`) | есть |
| 7 | ESC | `KeyCap(.symbol("escape"), L10n.Keyboard.esc, .key(.escape))` в `KeyboardView.row1` | есть |
| 8 | ENTER | `KeyCap(.symbol("return"), ..., .key(.return))` row1 | есть |
| 9 | CTRL | `.modifier(.leftCtrl)` row3 | есть |
| 10 | ALT | `.modifier(.leftAlt)` row3 | есть |
| 11 | WIN | `.modifier(.leftGUI)` (HID GUI key = Windows key) | есть |
| 12 | ALT+TAB | chord через существующий API: `HIDInput.keyReports(for: .tab, modifiers: .leftAlt)` (в `HIDInput.swift`); в UI: arm ALT → press TAB. Отдельная 1-tap кнопка не добавлена (см. решения) | функционально есть |
| 13 | Bluetooth connection state | `SetupView` (status rows: BT state/advertising/devices); `NotConnectedView` на Remote-экране | есть |
| 14 | UI для большого экрана iPad | landscape layout `KeyboardView.editor` (keyboard слева, trackpad справа) | есть |

Желательные: two-finger scroll ✓, tap=left ✓, two-finger tap=right ✓, drag ✓
(1-finger pan), keyboard show/hide ✓ (`L10n.Keyboard.done` / `focused=false`),
F1–F12 ✓ (`KeyboardView.fRow`). Всё уже есть в upstream.

## Решения LEAD (минимальный diff)
1. P2–P6 (trackpad/click+scroll/keyboard/shortcuts/BT state) — НЕ требуют
   написания Swift: всё реализовано upstream и проверено чтением файлов.
2. Единственный cosmetic gap vs спецификации (mockup): layout spec
   (trackpad слева) = зеркало существующего. Функции идентичны → не менять
   (нельзя компилировать локально; risk > benefit). Если позже потребуется
   буквально — переставить subviews в `KeyboardView.editor` (мелкий diff).
3. ALT+TAB single-button: UI уже позволяет alt+tab (arm-then-press); опциональная
   кнопка — будущий мелкий diff (добавить `KeyCap` + новый `Action.combo` +
   строки в L10n/`Localizable.xcstrings`); НЕ сделано ради WORKING MVP.
4. Ресурсы: `project.yml` ссылается на `BTRemote/Resources/company_ids.json` и
   `service_uuids.json`, которых НЕТ в git (только `Resources/.gitignore`) —
   потенциальный blocker сборки; назначение UNKNOWN.см. docs/BUILD.md
   (ci-worker исследует, генерирует ли их `ci_scripts/`).
5. Git: `.xcodeproj` не коммитится (генерируется xcodegen из `project.yml`);
   чистая история: baseline commit `95b69a1` (upstream HEAD `ad7a76ce`,
   license AGPL-3.0-only сохранена).

## Milestones / priorities
- P0 working upstream build — локально невозможно (нет Xcode/swift); CI = путь
- P1 unsigned IPA artifact через GitHub Actions — ждёт push (нужны GitHub
  credentials пользователя)
- P2 trackpad — код есть (сверх-доп.: layout swap не требуется)
- P3 left/right click + scroll — код есть
- P4 keyboard — код есть
- P5 shortcuts (ESC/CTRL/ALT/WIN/ALT+TAB/ENTER) — код есть (ALT+TAB chord)
- P6 Bluetooth state — код есть
- P7 install (SideStore / free sideload) — ждёт пользователя
- P8 Windows pairing — ждёт physical test
- P9 lock-screen acceptance — ждёт physical test (см. docs/PHYSICAL_TEST.md)
