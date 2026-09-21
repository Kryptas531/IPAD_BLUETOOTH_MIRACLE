> **SUPERSEDED BY `docs/CANON LAYOUT.md`** (2026-09-20).
> Постановка выполнена (commits `c6b1a74`, `b207c49`, `5e8f52e`, `0bccedc`;
> CI VERIFIED — green run `35511332912`). Актуальный канон layout —
> `docs/CANON LAYOUT.md`; статусы — только из «Язык статусов» в `QWEN.md`.
> Ниже — исторический текст (не выполнять заново; следующая работа —
> «ACTIVE ROADMAP» в `QWEN.md`).

Продолжаем с ТЕКУЩЕГО HEAD.

ВАЖНО:
НЕ перезапускать P2.
НЕ повторять исследования.
НЕ переделывать уже реализованные GAME/TRACKPAD/GYRO/DECK/DICTATION/etc.
НЕ трогать BLE/HOGP без реального blocker.
НЕ откатывать working implementation.

ЗАДАЧА:
сделать UI/layout pass поверх уже готового P2.

Это PATCH, а не новый milestone.

====================
CANONICAL LAYOUT
====================

Primary device:
iPad Air 11" M2 2024

Primary orientation:
LANDSCAPE.

Главная идея:
MAXIMUM INPUT SURFACE.
Минимум постоянно видимых controls.

Убрать с основной рабочей поверхности большие:
- CONNECTED
- DIRECT INPUT
- debug
- setup/status panels
- длинные подписи состояний

Connection/Direct Input показать только маленькими indicators/icons.

Например:
●BT   ⌨●

====================
GLOBAL TOP BAR
====================

Очень компактный top bar:

[ GAME | TRACKPAD | TOUCH | DECK ]                 ●BT ⌨

Высота примерно 40-48pt.

В GAME:
top bar должен уметь auto-hide.

Settings НЕ должен быть отдельной большой вкладкой.
Settings открывается modal/sheet.

====================
TRACKPAD
====================

Основной layout:

┌──────────────────────────────────────────────────────┐
│ TRACKPAD / compact mode selector            ●BT ⌨   │
├──────────────────────────────────────────────────────┤
│                                                      │
│                                                      │
│                                                      │
│                 LARGE TRACKPAD                       │
│                                                      │
│                                                      │
│                                                      │
│                                                      │
├──────────────────────────────────────────────────────┤
│ Ctrl  Win  Alt  Shift       🎙  Esc  Tab  Enter  ⌨ │
└──────────────────────────────────────────────────────┘

Trackpad должен занимать примерно 85-90% полезной площади.

НЕ делать постоянную широкую right sidebar.

Extended keys:
Backspace/Delete/Home/End/PgUp/PgDn/arrows/F1-F12

должны открываться temporary overlay/panel,
а не постоянно уменьшать trackpad.

Edge gestures:
- left edge -> Deck/controls
- right edge -> Windows keys
- bottom edge -> keyboard
- tap outside -> hide overlay

====================
GAME
====================

GAME = почти полностью fullscreen input surface.

По умолчанию:

┌──────────────────────────────────────────────────────┐
│                                                      │
│                                                      │
│                                                      │
│                    AIM AREA                          │
│                                                      │
│                                                      │
│                                                      │
│                                                      │
└──────────────────────────────────────────────────────┘

Никаких постоянных dashboard элементов.

Controls появляются temporary overlay:

- Touch/Gyro/Hybrid
- sensitivity
- gyro sensitivity
- recenter
- debug overlay toggle

и затем скрываются.

Optional LMB/RMB touch zones можно оставить,
но они:
- полупрозрачные
- configurable
- могут полностью отключаться

External physical keyboard уже используется,
поэтому НЕ рисовать WASD keyboard на основном экране.

====================
TOUCH
====================

TOUCH = практически 100% screen surface.

Controls скрыты.

Только edge gesture для:
- выхода
- выбора display
- calibration/settings

====================
DECK
====================

DECK должен быть Windows control surface,
а не старый media remote.

Основная grid:
4 columns x 4 rows.

PAGE 1:

COPY | PASTE | CUT | UNDO
TASK MGR | EXPLORER | SEARCH | DESKTOP
TASK VIEW | DESK LEFT | DESK RIGHT | SCREENSHOT
VOL- | MUTE | VOL+ | PLAY/PAUSE

PAGE 2:
Windows/navigation keys.

ESC | TAB | ENTER | BACKSPACE
INSERT | DELETE | HOME | END
PGUP | UP | PGDN | PRTSC
LEFT | DOWN | RIGHT | F-KEYS

F-KEYS -> temporary F1-F12 grid.

====================
DIRECT INPUT
====================

НЕ делать отдельный большой блок.

Только compact status icon.

Capture/release controls могут появляться:
- long press на keyboard indicator
или
- в settings

Physical Windows RGB keyboard должна продолжать работать как сейчас.

====================
DICTATION
====================

В TRACKPAD:
маленькая 🎙 кнопка в bottom strip.

Push-to-dictate.

Temporary transcript можно показывать около нижней части экрана,
но НЕ перекрывать центр trackpad.

====================
FEEDBACK
====================

Все touch buttons:
- immediate pressed visual state
- short click sound if enabled
- toggle ON/OFF visually clear

Не добавлять latency в input pipeline ради animations.

====================
DEBUG
====================

Performance overlay:
скрыт по умолчанию.

Показывать только по developer toggle.

Никаких Touch Hz/HID Hz на обычном рабочем UI.

====================
IMPORTANT
====================

Сначала INSPECT текущую реализацию.

НЕ переписывать всё UI с нуля.

Сделать минимальный layout refactor поверх текущих working views.

Сохранить:
- все уже реализованные features
- все working input paths
- Direct Input
- current CI
- current BLE behavior

После изменений:
1. git diff review
2. verifier review
3. CI
4. unsigned IPA artifact

В финале дать только:

STATUS
LAYOUT CHANGES
FEATURES PRESERVED
CI
ARTIFACT
PHYSICAL UI TEST CHECKLIST