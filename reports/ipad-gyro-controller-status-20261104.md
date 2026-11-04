# iPad gyro controller — 2026-11-04

## Repository and existing IPA

Repository: https://github.com/Kryptas531/IPAD_BLUETOOTH_MIRACLE

The latest pushed source is **`feat/tv-wifi-remote` at
`caf3d5a7639e5bef9c51cd2268bafce5da6c6e42`**, not main
(`34bfea8006c875ff140aa02d21937e57c7d50593`). Its 18 newer commits are preserved
as this work's base. Worktree was a clean, new clone; no existing dirty work was
overwritten.

Existing downloadable IPA (verified/downloaded by the parent):
**0.0.4 / build 4, iOS 15+, commit `a4649685`**, successful
[Actions run 37165143215](https://github.com/Kryptas531/IPAD_BLUETOOTH_MIRACLE/actions/runs/37165143215),
artifact ID `11288837923` (`btr-remote-unsigned-ipa`).
Artifact URL:
https://github.com/Kryptas531/IPAD_BLUETOOTH_MIRACLE/actions/runs/37165143215/artifacts/11288837923

Parent's direct extracted copy:
`/home/agent/.openclaw/workspace/downloads/BTRemote-a4649685.ipa`.
It is unsigned: install via SideStore/Sideloadly and re-sign with a free Apple ID.
The old IPA **does not contain FLIGHT** or the final two TV-branch commits.
There are no GitHub Releases. Do not describe the artifact as the latest source build.

## Implemented

Branch: `feat/ace-combat-controller` in
`/home/agent/repos/ipad-bluetooth-miracle`.

- Spec-first commit **`0a34be7`** defines SPEC §13.
- Implementation commit **`ea5fe21`** adds FLIGHT and receiver.
- Version for the next app build: **0.0.5 / build 5**.
- GAME → FLIGHT: fixed recentered gyro baseline, clockwise roll → LX, landscape
  pitch → LY; 2° deadzone, roll full-scale 32°, pitch 25°, exponent 1.4.
- RECENTER clears both flight axes while preserving held camera/buttons/triggers.
  Existing free-touch UIKit surface drives RX/RY and releases independently.
- Momentary A/B/X/Y, LB/RB, BACK/START, LT/RT; simultaneous axes and buttons.
  Controls remain available after GAME chrome hides. Wi-Fi entry works without BLE.
- Separate **real LAN UDP transport**, not an assumed native iPad Bluetooth Xbox
  device. Existing BLE descriptor/transport, RACING and TV source are preserved.
- Fixed 68-byte full-state packets with session UUID, monotonic sequence and
  HMAC-SHA256; private IPv4 only, UDP 26761; iOS pairing key stored in Keychain.
- Sender retains latest state and emits at 50 Hz with at most one outstanding
  send, plus startup neutral packets. Stale CoreMotion callbacks cannot cross
  session generations. Inactivity/mode/view exit/motion errors tear down input.
- Windows Python receiver authenticates packets, rejects malformed/old/replayed
  states, pins one active peer/session, neutralizes after **300 ms** silence
  (including malformed-traffic floods), and neutralizes on Ctrl+C.
- Actual virtual Xbox backend calls **vgamepad / ViGEmBus**. ViGEmBus is archived/EOL;
  driver installation is a separate owner choice on the available gaming PC.
  No driver or PC installation was performed here.
- Receiver requires a neutral packet after timeout/new session; release all
  controls/recenter before resuming. Retired sessions cannot retake ownership.
- Existing unsigned macOS IPA workflow now also runs the flight tests and is
  eligible for pull requests into main or the current TV branch.

## Verification performed on the server

Official Swift **6.2.1** Linux toolchain installed user-locally under
`/home/agent/.cache/ipad-gyro-swift` (no global configuration changes).

1. **32 production Swift checks PASS**: actual `FlightMapper`,
   `FlightConfiguration`, `FlightState`, existing `RacingMapper` and
   `GamepadReport` compiled and executed with Swift 6 mode:
   roll signs, pitch/orientation sign, deadzone, unrelated-axis rejection,
   arbitrary held baseline, exact return, q/-q equivalence, nonfinite input,
   recenter preserving independent controls, button release, neutral payload,
   private-host/key validation and a byte-exact cross-language packet fixture.
2. **15 production Python tests PASS**, including real kernel UDP datagrams,
   HMAC/tamper/range/length rejection, sequence ordering, ownership/replay,
   independent release, timeout/recovery/shutdown and all Xbox backend output
   calls through an injected vgamepad API.
3. Changed Swift files **parse successfully for arm64-apple-ios15.0**.
   Syntax parsing is **not** iOS typechecking/linking or an IPA build.
4. `git diff --check` PASS. Protected BLE/HOGP files remain unchanged.

Commands:

```sh
mkdir -p .build
/home/agent/.cache/ipad-gyro-swift/usr/bin/swiftc -swift-version 6 \
  BTRemote/LowEnergy/HIDReports.swift BTRemote/GyroAim.swift \
  BTRemote/FlightGamepad.swift BTRemoteTests/FlightTests.swift \
  -o .build/flight-tests
.build/flight-tests
python3 -m unittest discover -s companion/FlightReceiver -p 'test_*.py' -v
/home/agent/.cache/ipad-gyro-swift/usr/bin/swiftc -frontend -parse \
  -target arm64-apple-ios15.0 BTRemote/FlightGamepad.swift \
  BTRemote/GyroAim.swift BTRemote/KeyboardView.swift BTRemote/SettingsView.swift
```

## Delivery gates and exact limitations

**No new FLIGHT IPA has been built.** Linux has no iOS SDK/Xcode.
GitHub's effective credential status is unavailable on the server; a non-mutating
`GIT_TERMINAL_PROMPT=0 git push --dry-run origin HEAD:refs/heads/feat/ace-combat-controller`
failed with “could not read Username … terminal prompts disabled”. Thus the branch
is committed locally, not published, and no exact-HEAD Actions result exists.

Parent next steps: independently review implementation commit `ea5fe21`, provide
an authorized server-side GitHub publication route, push the feature branch
(no force/main push), open a PR based on `feat/tv-wifi-remote` or dispatch the
unsigned workflow on the exact branch, then verify exact-HEAD tests/build and
download its new 0.0.5 IPA. Keep independent review / new CI separate from these
already executed Linux checks.

Hardware gates: Windows virtual-driver installation and enumeration, iPad install
and Local Network permission, physical roll/pitch direction/feel and landscape
orientation, multi-touch/gesture cancellation, sender lifecycle and receiver
timeout on real Wi-Fi, Steam/XInput/Ace Combat 7 recognition and simultaneous
in-game roll/pitch/throttle/weapons. Hard receiver termination depends on virtual
device removal by the driver/process and requires physical acceptance.

[Receiver installation, protocol and Steam/Ace Combat setup](../companion/FlightReceiver/README.md)
contains exact Windows commands and dependency prerequisites.
The ASUS computer was explicitly unavailable and was not accessed; all work ran
on the server. Huawei and the other person's Mac were not used.
