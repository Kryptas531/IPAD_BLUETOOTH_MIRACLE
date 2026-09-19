# QWEN.md — операционный контракт

Репозиторий — дериват open-source проекта [jqssun/darwin-bt-remote](https://github.com/jqssun/darwin-bt-remote)
(upstream HEAD `ad7a76ce6132254fbd6085af87cea8d10aa8a82d`, лицензия **AGPL-3.0-only**,
файл LICENSE не менять). Подробности: `docs/MVP.md`, `docs/ARCHITECTURE.md`,
`docs/PHYSICAL_TEST.md`, `docs/BUILD.md` (когда CI подтверждён).

## Цель
Open-source приложение для iPad: Bluetooth HID over GATT (HOGP) keyboard+mouse
remote для Windows. Windows видит iPad как стандартные Bluetooth keyboard+mouse;
Windows companion/server для базового управления НЕ требуется. MVP = один экран:
trackpad + keyboard + shortcut-кнопки + Bluetooth state.

## Текущий milestone
- M0 (готово): upstream imported; чистая git-история; baseline commit `95b69a1`.
- M1 (в работе): MVP UI P2–P6 — фактически УЖЕ готов в upstream (проверено
  чтением кода, см. docs/MVP.md; компиляция не проверялась — Windows-машина).
- P0/P1 (CI, unsigned IPA artifact) + P7–P9 (physical tests) — ждут действий
  пользователя (создать GitHub-репозиторий + push/CI; physical iPad + Windows).

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
6. До физического BLE-теста не добавлять: Windows daemon, WebSocket,
   dynamic profiles, макросы, telemetry, аккаунты, cloud, process monitoring.
   Всё это Phase 2. Сейчас только: IPAD → BLE HID → WINDOWS.

## Verification commands (Windows; Xcode/swift/gh НЕТ)
- `git status`, `git log --oneline -3`
- чтение файлов (read_file/grep) — компиляция Swift на Windows недоступна

## Definition of Done (сессии)
- [x] repo существует; upstream imported; LICENSE/attribution сохранены
- [x] QWEN.md + .qwen/agents/ (upstream-researcher, ios-ui-worker, ci-worker,
  verifier) созданы, `model: inherit`
- [x] архитектура изучена; защищённая BLE-граница определена (docs)
- [x] MVP UI (P2–P6) — уже присутствует в upstream; diff 0, правки Swift не
  требуются (решение LEAD: не менять неизмеримо проверенное вслепую)
- [ ] CI собирает unsigned `.ipa` artifact (ждёт push пользователем)
- [ ] путь до физического теста описан (docs/BUILD.md + docs/PHYSICAL_TEST.md;
  проверку проходит пользователь на physical iPad + Windows)

## NEVER claim as verified
- «build passes» — только при фактических CI-логах
- «IPA created» — только если артефакт реально получен
- physical test (pairing/HID/keyboard/mouse) — только на physical iPad+Windows
- acceptance test (Win+L → login → Alt+Tab → typing) — НЕ PASSED, пока не
  проверен пользователем
