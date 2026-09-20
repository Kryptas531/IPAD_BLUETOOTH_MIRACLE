# 5A. LAYOUT IS CANON

Это обязательный layout для iPad Air 11" M2 2024.

Ориентация:
LANDSCAPE-FIRST.

Не хардкодить конкретные пиксели экрана.
Использовать safe area + relative/flexible layout.

Основная идея:

- максимум площади отдаётся input surface;
- статусы почти невидимы;
- controls появляются только когда нужны;
- никаких больших CONNECTED / DIRECT INPUT banners;
- никаких постоянно открытых settings/debug panels;
- UI должен ощущаться как поверхность ввода, а не приложение с формами.

==================================================
GLOBAL LANDSCAPE STRUCTURE
==================================================

┌────────────────────────────────────────────────────────────┐
│  GAME   TRACKPAD   TOUCH   DECK                 ●BT  ⌨DI  │  ~44pt
├────────────────────────────────────────────────────────────┤
│                                                            │
│                                                            │
│                                                            │
│                    MAIN INPUT SURFACE                      │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
├────────────────────────────────────────────────────────────┤
│   contextual controls / modifiers / hidden bottom panel    │  0-56pt
└────────────────────────────────────────────────────────────┘

TOP BAR:
- height approximately 40-48pt;
- compact;
- mode selector left/center;
- tiny status indicators on right;
- must NOT look like navigation toolbar from a business app.

Status examples:

● BT
⌨ DI

No text:
"CONNECTED"
"DIRECT INPUT ACTIVE"

unless in Settings/debug.

Top bar may auto-hide in GAME mode.

==================================================
MODE SWITCHER
==================================================

Mode selector:

[ GAME | TRACKPAD | TOUCH | DECK ]

Requirements:

- compact segmented control;
- no huge tabs;
- swipe horizontally may also switch modes;
- GAME can hide whole selector after several seconds;
- edge tap/swipe restores controls.

==================================================
TRACKPAD MODE
==================================================

Canonical layout:

┌────────────────────────────────────────────────────────────┐
│ TRACKPAD                                      ●BT  ⌨DI     │
├────────────────────────────────────────────────────────────┤
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                   FULL TRACKPAD                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
├────────────────────────────────────────────────────────────┤
│ Ctrl   Win   Alt   Shift        Esc   Tab   Enter      ⌨   │
└────────────────────────────────────────────────────────────┘

Rules:

- trackpad should occupy approximately 85-90% of usable screen;
- bottom controls approximately 48-56pt;
- do NOT put permanent controls on right side consuming 20-30% width;
- modifier/key strip can auto-hide;
- keyboard button opens software keyboard/input panel;
- modifiers visually latch when active.

BOTTOM STRIP:

LEFT:
Ctrl
Win
Alt
Shift

RIGHT:
Esc
Tab
Enter
Keyboard

Optional second row/expanded panel:
Backspace
Delete
Home
End
PgUp
PgDn
Arrows
F1-F12

Expanded key panel must be hidden by default.

==================================================
TRACKPAD EDGE PANELS
==================================================

LEFT EDGE SWIPE:
open Windows Control Deck overlay.

RIGHT EDGE SWIPE:
open Windows key/navigation panel.

BOTTOM EDGE SWIPE:
open keyboard.

Tap outside:
close overlay.

Overlays float ABOVE trackpad.
They do not permanently reduce trackpad size.

==================================================
GAME MODE
==================================================

GAME is fullscreen-first.

Default:

┌────────────────────────────────────────────────────────────┐
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                       AIM AREA                             │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
└────────────────────────────────────────────────────────────┘

NO permanent top bar after controls auto-hide.

Whole screen = relative mouse aiming surface.

Optional translucent thumb zones:

┌────────────────────────────────────────────────────────────┐
│                                                            │
│                        AIM                                 │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│  LMB ZONE                                      RMB ZONE   │
└────────────────────────────────────────────────────────────┘

LMB/RMB zones:

- optional;
- configurable;
- approximately lower 15-20% of screen;
- each around 20-25% screen width;
- low visual opacity;
- can be disabled entirely.

User may use external keyboard with GAME.
Do not waste screen space on WASD keyboard by default.

GAME quick controls appear after edge swipe or 4-finger tap:

┌─────────────────────────────────────────┐
│ Touch Aim       ON                      │
│ Gyro            HYBRID                  │
│ Sensitivity     ━━━━━●━━━━              │
│ Gyro Sens       ━━━●━━━━━━              │
│ Recenter        [ RECENTER ]            │
│ Debug Overlay   OFF                     │
└─────────────────────────────────────────┘

Then auto-hide.

==================================================
GYRO UI
==================================================

Gyro state should not occupy permanent space.

When gyro activates:
- tiny temporary visual indicator;
- subtle audio/visual feedback;
- disappear automatically.

Example:

GYRO ●

for ~0.5-1 second.

No giant "GYROSCOPE ACTIVE" banner.

==================================================
TOUCH MODE
==================================================

TOUCH must be almost completely fullscreen.

┌────────────────────────────────────────────────────────────┐
│                                                            │
│                                                            │
│                                                            │
│                                                            │
│                 WINDOWS TOUCH SURFACE                      │
│                                                            │
│                                                            │
│                                                            │
│                                                            │
└────────────────────────────────────────────────────────────┘

Input coordinates map to full normalized surface:

x = touchX / surfaceWidth
y = touchY / surfaceHeight

Controls hidden.

Small edge gesture opens:

- target display selection;
- calibration;
- leave TOUCH mode.

TOUCH interaction takes precedence over decorative gestures.

==================================================
DECK MODE
==================================================

DECK replaces old useless remote-control page.

Default landscape grid:

┌───────────┬───────────┬───────────┬───────────┐
│   COPY    │   PASTE   │    CUT    │   UNDO    │
├───────────┼───────────┼───────────┼───────────┤
│ TASK MGR  │ EXPLORER  │  SEARCH   │ DESKTOP   │
├───────────┼───────────┼───────────┼───────────┤
│ TASK VIEW │ DESK ←    │  DESK →   │ SCREENSHOT│
├───────────┼───────────┼───────────┼───────────┤
│   VOL -   │   MUTE    │   VOL +   │ PLAY/PAUSE│
└───────────┴───────────┴───────────┴───────────┘

Prefer 4 columns x 4 rows initially.

Buttons:
- large touch targets;
- rounded;
- label + optional SF Symbol;
- strong pressed state;
- no tiny buttons;
- no fake skeuomorphic remote control.

Possible later:
5x4 grid on large landscape if spacing remains comfortable.

==================================================
DECK PAGE 2: WINDOWS KEYS
==================================================

Swipe horizontally inside DECK:

PAGE 1:
Windows shortcuts.

PAGE 2:
keyboard/navigation.

Example:

┌────────┬────────┬────────┬────────┐
│ ESC    │ TAB    │ ENTER  │ BACKSP │
├────────┼────────┼────────┼────────┤
│ INSERT │ DELETE │ HOME   │ END    │
├────────┼────────┼────────┼────────┤
│ PG UP  │   ↑    │ PG DN  │ PRTSC  │
├────────┼────────┼────────┼────────┤
│   ←    │   ↓    │   →    │ F-KEYS │
└────────┴────────┴────────┴────────┘

F-KEYS opens temporary F1-F12 grid.

==================================================
DIRECT INPUT
==================================================

Direct Input does NOT get its own large screen.

When enabled:
small keyboard icon changes state:

⌨ -> ⌨●

or equivalent.

Long press/tap on indicator may show:

- Capture
- Release
- current release chord
- Settings

Physical keyboard remains usable while touchscreen is in any mode.

==================================================
DICTATION
==================================================

Microphone is NOT permanent giant button.

In TRACKPAD bottom bar:

[ Ctrl ][ Win ][ Alt ][ Shift ]       [ 🎙 ][ Esc ][ ⌨ ]

Press/hold microphone:
Push-to-Dictate.

While active:
button visibly changes state.

Optional temporary floating transcript near bottom:

"открой терминал..."

Do NOT cover center of trackpad.

After recognition:
transcript disappears.

==================================================
FEEDBACK
==================================================

Every virtual button must have:

TOUCH DOWN:
- immediate visual depression;
- no delayed animation.

TOUCH UP:
- restore state.

Toggle:
- clear ON/OFF difference.

Because iPad Air does not provide general body haptics:
use:

- visual press;
- extremely short click feedback sound;
- optional device-supported feedback if available.

Input surface movement itself must remain silent.

==================================================
DEBUG UI
==================================================

Debug/performance information NEVER appears in normal UI.

Developer overlay example:

┌────────────────────────────┐
│ Touch Hz       118         │
│ HID gen Hz     118         │
│ HID TX Hz      116         │
│ Drops          0           │
│ BLE Busy       2           │
│ Avg interval   8.6 ms      │
└────────────────────────────┘

Small floating overlay in corner.

Can be dragged or hidden.

==================================================
SETTINGS
==================================================

Settings is a modal/sheet, not another permanent tab.

Open via:
small gear in temporary control overlay / long press status area.

Use standard iPad settings-style sections.

Do not consume main navigation with Settings.

==================================================
PORTRAIT
==================================================

Portrait is secondary.

Do not spend significant P2 time perfecting portrait.

It must not crash or become unusable.

Primary UX target is LANDSCAPE.

==================================================
VISUAL STYLE
==================================================

Dark-first.

Minimal.

No gradients unless extremely subtle.
No giant titles.
No large status cards.
No decorative dashboard widgets.
No excessive padding.

Input surface should visually recede.

Interactive controls should become obvious ONLY when needed.

Think:

"physical control surface"

not:

"admin dashboard".

==================================================
LAYOUT ACCEPTANCE
==================================================

P2 layout is accepted only if:

1. TRACKPAD has >= ~85% of practical working area when panels hidden.
2. GAME can become visually fullscreen.
3. no giant status labels.
4. Direct Input state is compact.
5. modifiers accessible within one touch.
6. key/navigation panel can appear without permanently shrinking trackpad.
7. DECK is useful Windows shortcut grid, not media remote.
8. TOUCH uses almost entire display.
9. controls work comfortably in landscape on iPad Air 11".
10. debug/settings UI is hidden during normal use.

Do not redesign this layout substantially without a concrete technical reason.
If implementation constraints require deviation, report the constraint before changing the core geometry.