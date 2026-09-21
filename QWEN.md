# QWEN.md — операционный контракт

Репозиторий — дериват open-source проекта [jqssun/darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote)
(upstream HEAD `ad7a76ce6132254fbd6085af87cea8d10aa8a82d`, лицензия **AGPL-3.0-only**,
файл LICENSE не менять). Подробности: `docs/MVP.md`, `docs/ARCHITECTURE.md`,
`docs/PHYSICAL_TEST.md`, `docs/BUILD.md`, `docs/P2.md`, `docs/CANON LAYOUT.md`.

## Текущее состояние (фактический current main, 2026-09-20)
- Repo: `Kryptas531/IPAD_BLUETOOTH_MIRACLE`
- Current HEAD: `0bccedc8c84148316acf370880ae6d7aeae4bb5e` (local == remote == `0bccedc`;
  все коммиты авторизованы как `Kryptas531 <konrybas@gmail.com>`; gh авторизован,
  push через gh-токен)
- Current green CI: run `35511332912` (head=`0bccedc`, job `build-unsigned` — ✓)
- Artifact: `btr-remote-unsigned-ipa` (скачан с green run `35511332912` в
  `.qwen/tmp/ipa-p3/BTRemote.ipa`; путь на диске проверен чтением каталога)
- Target: iPad Air 11" M2 2024 + Windows
- Deploy: GitHub Actions → unsigned IPA → SideStore
- История: M0 (upstream imported, baseline commit `95b69a1`); M1/P0/P1 (MVP UI уже
  был в upstream; репо пользователя создан и запушен). P2/P2.5 (performance +
  real UX build) — IMPLEMENTED в `c6b1a74`, `b207c49`, `5e8f52e`, `0bccedc`.

## Уже IMPLEMENTED (код в current main; CI VERIFIED — green run `35511332912`)
- iPad transport: **BLE HID over GATT only**; Bluetooth Classic backend существует,
  но **только macOS** (для схемы iPad→Windows не используется)
- GAME high-fidelity input: `touchesMoved` + `UIEvent.coalescedTouches(for:)`
  без predicted touches (`BTRemote/TouchpadView.swift`)
- Performance metrics overlay (`BTRemote/PerformanceMetrics.swift`; скрыт по умолчанию)
- Mouse backpressure accumulation: `pendingMouseDX/DY/Wheel`, `drainPendingMouse()`
  (`BTRemote/LowEnergy/HIDPeripheral.swift`; это защищённый стек — см. Hard constraint 1)
- `setDesiredConnectionLatency(.low, for: central)` (`HIDPeripheral.swift:542`)
- Windows-first UI: GAME / TRACKPAD / DECK
- TOUCH пока EXPERIMENTAL / in development (см. ACTIVE ROADMAP п.9)
- Windows keys: Ctrl / Win / Alt / Shift; modifier keycaps send full press+release
  (fix `0bccedc`: Win key now reaches host; было arm-only, report не уходил)
- Direct Input для физической Windows-клавиатуры через iPad
  (`BTRemote/DirectInputController.swift`: iOS-ветка `GCKeyboard.coalesced` /
  `GCMouse.current`)
- Release chord: `Ctrl + Alt + Backspace` (default `ReleaseChord.defaultChord`;
  configurable через AppSettings)
- DECK: Windows shortcuts + navigation + F1-F12 (страница 2 + F-keys grid,
  `BTRemote/RemoteView.swift`); extended keys + keyboard overlay
  (`BTRemote/KeyboardView.swift`)

## MEASURED FACTS (физический прогон: iPad Air 11" M2 2024 + Windows)
iPad:
- обычные touch events ~40-60 Hz
- raw/coalesced samples до ~120 Hz
- хороший прогон: ~120 raw samples, ~128 BLE accepted, `lost delta = 0`
- raw sample interval ~8.3 ms

Windows Raw Input для BTRemote:
- p50 ~14.8-14.9 ms
- negotiated BLE interval = **15.0 ms**
- latency = 0
- timeout = 2000 ms
- PHY = LE 2M

Control experiment, ROG CHAKRAM X over Bluetooth:
- baseline interval = **7.5 ms**
- значит Windows и текущий BT controller умеют 7.5 ms
- `ThroughputOptimized` у Windows = 15 ms и использовать его как ускорение не надо

## PARKED: SUPERLATENCY (до отдельного owner decision НЕ продолжать)
- force BLE 7.5 ms
- ETW/WPT Bluetooth tracing
- другой BT adapter
- iPad Bluetooth Classic experiments
- private iOS APIs
- ROG Omni reverse engineering
- ESP32/RP2040 bridge
- USB/Wi-Fi Turbo transport
- 500/1000 Hz experiments

Причина: текущий BLE usable, дальнейшая latency-охота пока хуже по ROI, чем UX/features.

## ACTIVE ROADMAP
1. UX polish по `docs/CANON LAYOUT.md`
2. TRACKPAD usability
3. GAME usability
4. Direct Input / Windows keyboard semantics
5. DECK
6. Gyro Aim
7. Native dictation RU/EN
8. Feedback
9. Experimental TOUCH / absolute digitizer

Позже отдельной фазой:
- Windows companion / WebSocket
- dynamic per-app panels
- OpenClaw
- clipboard / voice / state

## Язык статусов
Используй только: `IMPLEMENTED / CI VERIFIED / PHYSICAL VERIFIED / MEASURED / PLANNED / EXPERIMENTAL / PARKED`

## Hard constraints
1. BLE/HID (HOGP) стек upstream НЕ менять без доказанной необходимости:
   `BTRemote/LowEnergy/`, `BTRemote/Classic/`, `BTRemote/HIDInput.swift`,
   `BTRemote/HIDReports.swift` (граница — в docs/ARCHITECTURE.md).
2. Только текущая корпоративная Qwen-модель + встроенные средства Qwen Code.
   Не использовать Codex, Claude, внешние/платные модели и API.
   Project-local агенты (`C:\LIFE\IPAD BLTH\.qwen\agents\`): `model: inherit`.
3. Платного Apple Developer Program нет: только unsigned build, никаких Apple
   secrets/credentials в репозитории/CI.
4. Сохранять attribution и лицензию upstream (AGPL-3.0-only).
5. Минимальный diff: сначала найти и прочитать существующую реализацию,
   затем менять минимально. Не переписывать рабочий код ради стиля, не
   добавлять зависимости/абстракции без конкретной необходимости, не менять
   deployment target без причины.
6. Не продолжать superlatency research (см. PARKED) до отдельного owner decision.
7. Пункты «Позже отдельной фазой» (Windows companion / WebSocket, dynamic
   per-app panels, OpenClaw, clipboard / voice / state, макросы, telemetry,
   аккаунты, cloud, process monitoring) не добавлять, пока фаза не начата.
   Сейчас только: IPAD → BLE HID → WINDOWS.

## Verification commands (Windows; Xcode/swift нет; gh: `C:\LIFE\gh.exe`, авторизован — токен с write-доступом к репо)
- `git status`, `git log --oneline -3`
- чтение файлов (read_file/grep) — компиляция Swift на Windows недоступна
- CI-статус удалённо: `C:\LIFE\gh.exe run view 35511332912`
  (или `curl -s "https://api.github.com/repos/Kryptas531/IPAD_BLUETOOTH_MIRACLE/actions/runs?per_page=5"`, репо публичное)

## Definition of Done (сессии)
- [x] repo существует; upstream imported; LICENSE/attribution сохранены
- [x] QWEN.md + .qwen/agents/ (upstream-researcher, ios-ui-worker, ci-worker,
  verifier) созданы, `model: inherit`
- [x] архитектура изучена; защищённая BLE-граница определена (docs)
- [x] git: local == remote == `0bccedc`; все коммиты авторизованы как
  `Kryptas531 <konrybas@gmail.com>`; gh авторизован, push через gh-токен
  (права: contents:read&write)
- [x] P2/P2.5 (high-rate input, metrics, backpressure, low connection latency,
  DECK page 2, F-keys grid, extended keys, keyboard overlay, modifier
  press+release) — IMPLEMENTED (commits `c6b1a74`, `b207c49`, `5e8f52e`,
  `0bccedc`); компиляция CI VERIFIED (green run `35511332912`)
- [x] artifact `btr-remote-unsigned-ipa` скачан через gh с run `35511332912`
  в `.qwen/tmp/ipa-p3/BTRemote.ipa`; `.ipa` установлен пользователем через
  SideStore; базовый ввод (mouse/keyboard, touch→палец, Win key) на
  physical iPad+Windows подтверждён (MEASURED)
- [ ] остальное по ACTIVE ROADMAP (1. UX polish по `docs/CANON LAYOUT.md` → …)
  и полная физическая acceptance-проверка (docs/PHYSICAL_TEST.md:
  Win+L → login → Alt+Tab → typing) — НЕ проводилась, ждут пользователя

## NEVER claim as verified
- «build passes» — ВЕРИФИЦИРОВАНО только для кода на HEAD `0bccedc`
  (green CI run `35511332912`); любая новая правка — компиляция только через
  новый CI run (локально swift/xcodebuild нет)
- «IPA получен локально» — ВЕРИФИЦИРОВАНО: artifact `btr-remote-unsigned-ipa`
  скачан с green run `35511332912` в `.qwen/tmp/ipa-p3/BTRemote.ipa`
- «120 Hz достигнут», «latency fixed», «game ready» — НЕЛЬЗЯ: подтверждены
  только числа из MEASURED FACTS (один хороший прогон) + базовое прохождение
  пути палец→BLE→Windows
- всё, чего нет в «Уже IMPLEMENTED»/«MEASURED FACTS» (пункты ACTIVE ROADMAP:
  gyro, dictation, feedback, TOUCH digitizer, polish) — кода/проверки нет (PLANNED / EXPERIMENTAL)
- полная acceptance (docs/PHYSICAL_TEST.md: Win+L → login → Alt+Tab → typing) —
  НЕ PASD, пока не проверена пользователем
