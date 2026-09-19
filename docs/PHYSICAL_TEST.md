# docs/PHYSICAL_TEST.md — acceptance procedure (требует physical devices)

НЕ проверено на physical iPad + Windows. acceptance test НЕ PASSED, пока
пользователь не пройдёт шаги ниже.

## Пред-чек
1. iPad (iOS 15+) — BLE HID поддерживается (upstream README).
2. Windows PC с Bluetooth (Windows 10/11; Bluetooth LE HID host поддерживается;
   physical Wi-Fi/Bluetooth-адаптер PC должен быть BLE-совместим).
3. iPad + Windows — на расстоянии, без помех; Bluetooth на обоих включён.
4. (Опционально) `swift`/Xcode НЕ требуется; если CI собрал `.ipa` — установить
   через SideStore (см. docs/BUILD.md).

## Steps
1. **Build**: получить unsigned `.ipa` из GitHub Actions artifact (после push;
   см. docs/BUILD.md) и установить на iPad через SideStore. (Если artifact
   ещё не собран — step 1 не пройден.)
2. **Launch** iPad app: приложение появляется на Setup-экране; проверить:
   «Bluetooth powered on»/«advertising: yes» (Bluetooth state visible) —
   приложение автоматически start'ит advertising.
3. **Pairing с Windows**: Windows Settings → Bluetooth & devices → Add device;
   найти устройство (advertised name из `BTRemote/Resources/` или по умолчанию;
   в `SetupView` — start/stop advertising, scan устройств); выполнить
   Bluetooth pairing; при успехе iPad-приложение показывает connected state.
4. **Mouse** (iPad Remote screen): 1-finger drag по trackpad → cursor Windows
   двигается; 1-finger tap → left click; 2-finger tap → right click;
   2-finger pan → vertical scroll; кнопки L/M/R и scroll up/down на
   TrackpadPanel работают.
5. **Keyboard**: на Remote/Keyboard — набрать текст (или typed → send) →
   символы появляются в Windows; кнопка ESC/ENTER работают.
6. **Shortcuts**: WIN → Start menu открывается; ALT+TAB — chord: arm ALT
   (button) → press TAB → переключение окон (или alt+tab через клавиши);
   CTRL+комбо через arm-then-press.
7. **Lock-screen acceptance (главный proof)**: на Windows `Win+L` → lock
   screen; НЕ используя физическую клавиатуру/мышь, с iPad: разбудить экран
   (click/drag), двигать cursor, click, ввести PIN/password (keyboard input),
   выполнить login. После login: Win (Start) → Alt+Tab → печатать → scroll →
   left/right click.

## Критерий готовности MVP
Все mandatory 1–14 работают (см. docs/MVP.md таблица) И lock-screen acceptance
пройден → MVP доказан.

## Статус
- automated/build verification: ВЕРИФИЦИРОВАНО через CI — run #6
  (id=35475333345, head=13a94f8) completed/success (P2-код); unsigned `.ipa`
  скачан в `.qwen/tmp/ipa-p2/BTRemote.ipa`
- physical verification: НЕ проводилась (нужен physical iPad + Windows)
- **acceptance test: NOT PASSED** (не проверялся)
