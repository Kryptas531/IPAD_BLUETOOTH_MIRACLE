# docs/MVP.md — MVP план и статус

## Цель
MVP: iPad-приложение = Bluetooth HID-over-GATT (HOGP) keyboard+mouse remote для
Windows PC (iPad — BLE HID peripheral; Windows — HID host; Windows-сервер не
нужен). Переиспользуем существующий upstream darwin-bt-remote; BLE/HOGP стек —
защищённая инфраструктура, не рефакторить без доказанной необходимости.

## Обязательные функции — проверено по коду (LEAD read-through; компиляция подтверждена CI run `35511332912`, head `0bccedc`)
| # | Требование | Где | Статус |
|---|---|---|---|
| 1 | BLE pairing с Windows | `BTRemoteApp.swift`: `onAppear { central.start(); if autoAdvertise { lowEnergy.start() } }` — iPad advertise'ит HID; Windows подключается как обычный BT-хост | есть (CI VERIFIED: run `35511332912`) |
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
| 14 | UI для большого экрана iPad | landscape layout для физической клавиатуры: доминирующий input surface (trackpad) + keyboard overlay + extended keys (`BTRemote/KeyboardView.swift`, `BTRemote/TouchpadView.swift`; канон — `docs/CANON LAYOUT.md`) | IMPLEMENTED (CI VERIFIED) |

Желательные: two-finger scroll ✓, tap=left ✓, two-finger tap=right ✓, drag ✓
(1-finger pan), keyboard show/hide ✓ (`L10n.Keyboard.done` / `focused=false`),
F1–F12 ✓ (extended keys overlay + DECK page 2 / F-keys grid). Всё есть в
current main (IMPLEMENTED, CI VERIFIED).

## Решения LEAD (минимальный diff)
1. P2/P2.5 (high-rate input: `touchesMoved` + `UIEvent.coalescedTouches(for:)`,
   PerformanceMetrics, BLE mouse backpressure `pendingMouseDX/DY/Wheel` +
   `drainPendingMouse()`, `setDesiredConnectionLatency(.low)`, DECK page 2 +
   F-keys grid, extended keys, keyboard overlay, modifier press+release) —
   IMPLEMENTED (commits `c6b1a74`, `b207c49`, `5e8f52e`, `0bccedc`;
   CI VERIFIED — green run `35511332912`).
2. Layout: Windows-first UI (GAME / TRACKPAD / TOUCH / DECK, доминирующий
   input surface, keyboard overlay) реализован в P2 (`c6b1a74` + fixes
   `b207c49`/`5e8f52e`/`0bccedc`). Канон layout — `docs/CANON LAYOUT.md`;
   `docs/LAYOT PATCH.md` — SUPERSEDED.
3. ALT+TAB single-button: UI уже позволяет alt+tab (arm-then-press,
   `HIDInput.keyReports(for: .tab, modifiers: .leftAlt)`); опциональная
   single-кнопка — будущий мелкий diff (PLANNED).
4. Ресурсы: `project.yml` ссылается на `BTRemote/Resources/company_ids.json` и
   `service_uuids.json`, которых НЕТ в git (только `Resources/.gitignore`) —
   скачивает `ci_scripts/ci_post_clone.sh` во время CI из
   `NordicSemiconductor/bluetooth-numbers-database` (проверено чтением файла).
   Блокер закрыт: CI green (run `35511332912`, head `0bccedc`).
5. Git: `.xcodeproj` не коммитится (генерируется xcodegen из `project.yml`);
   чистая история: baseline commit `95b69a1` (upstream HEAD `ad7a76ce`,
   license AGPL-3.0-only сохранена); local == remote == `0bccedc`; все коммиты
   авторизованы как `Kryptas531 <konrybas@gmail.com>`; gh авторизован
   (`C:\LIFE\gh.exe`), push через gh-токен.

## Milestones / priorities
- P0 working upstream build — локально невозможно (нет Xcode/swift); CI — путь
  (build подтверждён: **CI VERIFIED**, green run `35511332912`, head `0bccedc`)
- P1 unsigned IPA artifact через GitHub Actions — **готово** (artifact
  `btr-remote-unsigned-ipa` со green run `35511332912`; скачан в
  `.qwen/tmp/ipa-p3/BTRemote.ipa`)
- P2 trackpad — код есть (IMPLEMENTED, CI VERIFIED)
- P3 left/right click + scroll — код есть (IMPLEMENTED, CI VERIFIED)
- P4 keyboard — код есть (IMPLEMENTED, CI VERIFIED)
- P5 shortcuts (ESC/CTRL/ALT/WIN/ALT+TAB/ENTER, extended keys, F1-F12) —
  код есть (IMPLEMENTED, CI VERIFIED)
- P6 Bluetooth state — код есть (IMPLEMENTED, CI VERIFIED)
- P7 install (SideStore / free sideload) — **готово**: пользователь установил
  build (`.qwen/tmp/ipa-p3/BTRemote.ipa`) на iPad Air 11" M2 2024
- P8 Windows pairing — **готово (MEASURED)**: iPad сопряжён, BTRemote виден с
  Windows; сняты performance-замеры (negotiated BLE interval 15.0 ms,
  latency 0, timeout 2000 ms, PHY LE 2M; Windows Raw Input p50 ~14.8-14.9 ms;
  control ROG CHAKRAM X = 7.5 ms)
- P9 lock-screen acceptance — **не проверялась**: ждёт пользователя (PLANNED;
  чек-лист docs/PHYSICAL_TEST.md)
