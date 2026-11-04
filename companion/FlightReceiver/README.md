# FLIGHT → Windows Xbox 360 controller

FLIGHT is an explicit **Wi-Fi/LAN** path, not a Bluetooth HID/XInput claim.
The iPad sends authenticated, complete latest-state UDP packets; this receiver
creates a virtual Xbox 360 controller using [vgamepad](https://github.com/yannbouteiller/vgamepad).
Existing BLE keyboard/mouse/RACING remain separate.

## Windows setup (on the gaming PC, when available)

Needs Python 3.10+, Windows 10/11, and ViGEmBus. **ViGEmBus is archived/EOL**:
review its original [upstream release](https://github.com/nefarius/ViGEmBus/releases)
and driver installer before choosing to install it. vgamepad's Windows install
can start its bundled driver installer; this is an administrator action, not
something this repository runs automatically. No paid product is required.
Do not install random replacement driver bundles.

```powershell
py -m venv .venv-flight
.\.venv-flight\Scripts\python.exe -m pip install -r companion\FlightReceiver\requirements.txt
.\.venv-flight\Scripts\python.exe companion\FlightReceiver\receiver.py --bind 192.168.1.25 --key-file "$env:LOCALAPPDATA\BTRemote-flight-key.txt" --create-key
```

Replace the bind address with this PC's actual private LAN IPv4 (same reachable
LAN as the iPad). The receiver binds only that interface on UDP **26761**;
allow this Python process through Windows Firewall on the **Private** network
if prompted. No public forwarding or wildcard binding is needed. The created
file contains a random 64-hex-digit key: open it locally and enter it in iPad
**Settings → Ace Combat / FLIGHT** together with the PC's LAN IPv4, then tap **Save pairing key** (stored in iOS Keychain).
The receiver
does not print the key. Keep the file private; do not put it in Git. On subsequent
starts omit `--create-key`; it deliberately refuses to overwrite existing keys.

On iPad allow Local Network, choose **PC → GAME → FLIGHT**, hold the iPad in
landscape in a comfortable neutral pose and press **RECENTER**. Without BLE,
the disconnected PC surface includes **Open FLIGHT over Wi-Fi** and Settings.
Re-enter GAME after editing connection fields. Keep the iPad app foreground.
Rotate the screen like a steering wheel for roll; tilt forwards/backwards for pitch.
The landscape pose at mode entry fixes the pitch sign; re-enter FLIGHT if changing
between landscape orientations. The pitch direction is a tunable hardware
acceptance item: if necessary invert pitch in the game's controller settings.

## Steam / Ace Combat

1. Start the receiver and check Windows `joy.cpl`: a virtual Xbox 360 pad should
   appear. Verify both sticks, LT/RT and buttons before opening the game.
2. Steam → Settings → Controller: verify the Xbox controller. Ace Combat 7 →
   Properties → Controller: first use the game's native XInput support with
   Steam Input disabled; if needed enable Steam Input and use a standard Gamepad
   template. Do not bind this source as a keyboard or a flight HOTAS.
3. Game options: use **Expert** controls if you want separate roll/pitch instead
   of novice assisted turns. Gyro → left stick (roll/pitch); free surface drag →
   right stick (camera); buttons A/B/X/Y, LB/RB, BACK/START map literally to Xbox
   buttons; LT/RT are independent triggers. Use the game's displayed bindings
   for throttle/yaw/weapon functions; do not assume one universal layout.
4. Test simultaneous roll+pitch+throttle+weapon; release controls, recenter, leave
   GAME, background the app and break Wi-Fi. Every loss must center the pad.

No Windows/Steam/Ace Combat/iPad physical acceptance has been performed by these
Linux tests; virtual driver installation and game recognition need the gaming PC.

## Neutralization and network behavior

Protocol: 68 bytes: `IGP1` + 16-byte session UUID + big-endian uint64 sequence +
big-endian uint16 buttons + LX/LY/RX/RY signed bytes + LT/RT unsigned bytes +
32-byte HMAC-SHA256 over the first 36 bytes. Axis range -127…127; buttons bits
0–7 = A,B,X,Y,LB,RB,BACK,START. The key is never transmitted. No encryption is
provided: packets reveal controller state, but cannot be modified/forged without
the key. This is a local trusted-LAN design, not an Internet remote-control server.

The sender keeps only newest state and sends at 50 Hz, at most one send pending.
Three neutral startup packets precede input. The receiver rejects bad MACs,
bad lengths/ranges, duplicate/old sequence numbers and concurrent peers.
After **300 ms** with no new authenticated packet it releases everything,
even if malformed traffic continues. After silence, release **all** held
controls (return gyro to neutral/recenter, end drag, release buttons/triggers)
to provide a fresh neutral packet before resuming; a new session likewise starts
neutral. If the UDP source port changes, re-enter FLIGHT to create a new session.
Retired session IDs cannot take over again during a receiver process lifetime.
After 256 session replacements, restart the receiver to renew bounded state.
Ctrl+C neutralizes before exit. A hard-killed receiver relies on the virtual
device being removed by its driver/process teardown (must be hardware-tested).

`--dry-run` runs the authenticated listener without vgamepad or a driver; it does
**not** create a game controller. It is useful for LAN setup only.

## Tests

```sh
python3 -m unittest discover -s companion/FlightReceiver -p 'test_*.py' -v
```

Tests run against the production parser/state machine and actual UDP sockets.
An injected vgamepad API verifies every output field and button mapping without
a driver; that is not a Windows driver integration test. The macOS unsigned IPA
workflow also compiles the production Swift gyro/packet arithmetic and runs
`BTRemoteTests/FlightTests.swift` before building the app.
