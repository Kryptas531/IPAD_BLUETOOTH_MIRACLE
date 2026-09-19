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
- M1 (готово): MVP UI P2–P6 — фактически УЖЕ готов в upstream (проверено
  чтением кода, см. docs/MVP.md; компиляция подтверждена CI — см. ниже).
- P0/P1 (готово на стороне GitHub): репозиторий пользователя создан
  (`Kryptas531/IPAD_BLUETOOTH_MIRACLE`), всё запушено (local == remote ==
  `13a94f8`, автор коммитов `Kryptas531 <konrybas@gmail.com>`; gh авторизован,
  push через gh-токен). CI-сборка unsigned IPA: run #5 (head=4583929) build
  FAILED (6 swiftc-ошибок в TouchpadView.swift); run #6 (id=35475333345,
  head=13a94f8) **completed/success** (фикс всех 6 ошибок = коммит 13a94f8).
  Артефакт `btr-remote-unsigned-ipa` скачан через gh в
  `.qwen/tmp/ipa-p2/BTRemote.ipa` (550 KB).
- P2 (код + CI-сборка готовы, физический тест не проводился): WINDOWS NATIVE
  INPUT SURFACE — метки Win/Ctrl/Alt/Shift/AltGr (HID-коды не менялись),
  Direct Input с release-chord Ctrl+Alt+Backspace (клавиши chord перехватываются
  приложением, в хост не уходят; страховочная кнопка Release Direct Input),
  trackpad (1-палец move/tap=LMB/2-пальца scroll/2-finger tap=RMB/double-tap-hold
  =drag), GAME (сырой относительный мышиный ввод), компактный switcher
  GAME|TRACKPAD|TOUCH|DECK (TOUCH/DECK = «в разработке»), статус «BT ● KB ●»,
  feedback нажатий. Отложено (кода нет): TOUCH-дигитайзер (риск дескрипторов),
  диктовка, гиро.
- P7–P9 (physical tests) — ждут: установить .ipa (`.qwen/tmp/ipa-p2/BTRemote.ipa`
  — P2-сборка с зелёного CI run #6; P1 IPA = артефакт run #3) через SideStore на
  physical iPad + тесты на Windows per docs/PHYSICAL_TEST.md.

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

## Verification commands (Windows; Xcode/swift нет; gh установлен: `C:\Program Files\GitHub CLI\gh.exe`, авторизован — токен с write-доступом к репо)
- `git status`, `git log --oneline -3`
- чтение файлов (read_file/grep) — компиляция Swift на Windows недоступна
- CI-статус удалённо: `curl -s "https://api.github.com/repos/Kryptas531/IPAD_BLUETOOTH_MIRACLE/actions/runs?per_page=5"` (репо публичное)

## Definition of Done (сессии)
- [x] repo существует; upstream imported; LICENSE/attribution сохранены
- [x] QWEN.md + .qwen/agents/ (upstream-researcher, ios-ui-worker, ci-worker,
  verifier) созданы, `model: inherit`
- [x] архитектура изучена; защищённая BLE-граница определена (docs)
- [x] MVP UI (P2–P6) — уже присутствует в upstream; diff 0, правки Swift не
  требуются (решение LEAD: не менять неизмеримо проверенное вслепую)
- [x] git: local == remote == `13a94f8`; все коммиты авторизованы как
  `Kryptas531 <konrybas@gmail.com>` (почта пользователя для подписи); gh
  авторизован, push через gh-токен (права: contents:read&write)
- [x] CI собирает unsigned `.ipa` artifact: run #3 (head=0e2f8f4)
  completed/success — P1; P2: run #5 (4583929) FAILED (6 swiftc-ошибок),
  run #6 (35475333345, head=13a94f8) completed/success
- [x] artifact `btr-remote-unsigned-ipa` скачан через gh с успешного run #6
  в `.qwen/tmp/ipa-p2/BTRemote.ipa` (550 KB)
- [ ] путь до физического теста пройден (docs/BUILD.md + docs/PHYSICAL_TEST.md;
  проверку проходит пользователь на physical iPad + Windows; P2-сборка ждёт
  в `.qwen/tmp/ipa-p2/BTRemote.ipa`)

## NEVER claim as verified
- «build passes» — ВЕРИФИЦИРОВАНО: CI run #6 (id=35475333345, head=13a94f8)
  conclusion=success — P2-код компилируется. (run #5 с head=4583929 был
  FAILED: 6 swiftc-ошибок в TouchpadView, исправлены в 13a94f8)
- «IPA получен локально» — ВЕРИФИЦИРОВАНО: скачан через gh с run #6 в
  `.qwen/tmp/ipa-p2/BTRemote.ipa`; P2-фичи на устройстве НЕ проверялись
- physical test (pairing/HID/keyboard/mouse) — только на physical iPad+Windows
- acceptance test (Win+L → login → Alt+Tab → typing) — НЕ PASSED, пока не
  проверен пользователем
