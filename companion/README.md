# Windows companion helper (`WindowsForeground`)

.NET 8 console helper that tells the paired iPad which Windows application is
in the foreground, so the iPad can switch to the matching CONTROL layout
(SPEC §7.1/§7.2; spec commits `b751488` and `fb77782`). It is the Windows side of
the iPad → BLE HID → Windows controller project; it never sends HID input itself.

## Build and run

```powershell
cd 'C:\LIFE\IPAD BLTH'
dotnet build companion\WindowsForeground\WindowsForeground.csproj -c Release
dotnet run --project companion\WindowsForeground\WindowsForeground.csproj -c Release   # optional [port], default 8443
dotnet run --project companion\WindowsForeground.Tests\WindowsForeground.Tests.csproj -c Release
```

No NuGet packages: only the .NET 8 base class library (`System.Net`,
`System.Net.WebSockets`, `System.Security.Cryptography`, `System.Text.Json`)
plus two `crypt32` P/Invoke entry points. Tests are dependency-free
(`ALL TESTS PASSED`, exit 0); they cover parsing the shipped layout document,
executable → layout-token resolution, chord / chord-sequence / typed-text target
validation, and the exact pair/reconnect/notification wire strings.

## Actual behavior (what the code really does today)

* **Local-only bind.** The helper never binds a wildcard address. It walks the
  operational, non-tunnel network interfaces and binds the *first* IPv4
  unicast address that is loopback or RFC 1918 / link-local
  (`ForegroundServer.IsLocalPrivateAddress`). If the machine has no such
  address, the helper prints a message and exits with code 1 rather than
  listening on a public interface.
* **TLS is mandatory.** The listener wraps every accepted socket in
  `SslStream` and only then performs the RFC 6455 WebSocket handshake (the
  helper implements the server-side handshake itself because .NET ships only a
  client-side `ClientWebSocket`). There is no plaintext code path: the pairing
  exchange happens inside TLS, and before authentication the helper sends no
  application data at all.
* **Certificate is durable and printable for pinning.** The RSA-2048
  self-signed certificate (`CN=ipad-foreground-helper`, 30 days) is generated
  once and its PFX is stored DPAPI-protected (current user) at
  `%LOCALAPPDATA%\iPadForegroundHelper\tls-cert.pfx`. On restart the same key
  pair is re-imported, so the printed
  `TLS certificate SHA-256 fingerprint (pin this on the iPad): ...`
  stays valid across restarts. If that file is deleted or unreadable, a new
  certificate is generated and the iPad must re-pin.
* **Pairing.** At start the helper prints a one-time six-digit code. The device
  must send exactly `{"type":"pair","code":"<code>"}`. A correct exchange
  consumes the code and the server then generates a 256-bit device secret,
  persists it DPAPI-protected at
  `%LOCALAPPDATA%\iPadForegroundHelper\device-secret.bin`, and sends it to the
  device exactly once, over TLS, as `{"type":"paired","secret":"<base64>"}`.
* **Reconnect.** A device that loses the link (Wi-Fi drop, iPad reboot, helper
  restart) reconnects with `{"type":"reconnect","secret":"<base64>"}` and is
  authenticated by a fixed-time comparison against the stored secret; no new
  pairing code is needed. Server-side client authentication is therefore
  verified (possession of the one-time code, then of the durable secret), not
  assumed.
* **Application tracking is data-driven.** `ForegroundWatcher` polls the
  foreground window's process every 350 ms and hands only the executable *file
  name* to `ForegroundMapping`, which resolves it through the user's layout
  document (`Code.exe` → `vscode`, `chrome.exe` → `chrome`, `explorer.exe` →
  `explorer`, anything else including unknown/unavailable → `generic`). Window
  titles are never consulted. After authentication the only message the helper
  ever sends is `{"type":"foreground-changed","identity":"<token>"}`.
* **Single device.** One iPad per helper run; a second socket is closed
  without data while a client is already connected.

## Configuring apps and layouts (SPEC §7.2 F)

Nothing about the supported apps is compiled in. On first run the helper writes
the shipped document to
`%LOCALAPPDATA%\iPadForegroundHelper\profiles.json` and uses it; edit that file
to add an app or change a layout, then copy the same JSON into the iPad's
**Settings → App layouts (JSON)** field (the iPad keeps its own copy, so the
helper and the app must stay in sync — the helper only ever reports executables
it has configured, which is what keeps §7.2 G's privacy rule intact).

Schema — top level `{ "profiles": [ ... ] }`; each profile is
`{ "id", "title", "executables": ["Some.exe"], "actions": [ ... ] }` and each
action is `{ "label", ... }` with exactly one target:

* `"chord"` — one chord, e.g. `"Ctrl+Shift+P"` or `"F5"`;
* `"sequence"` — ordered chords, e.g. `["Ctrl+K", "Ctrl+O"]` (VS Code
  `Open Folder`); everything is typed through the existing HID keyboard path, so
  no new keycode or report type exists;
* `"text"` — a literal string or path to type into the focused Windows app;
* `"settings"` — the iPad app-settings key that holds the user's own chord, used
  by the six shipped project/folder targets (`Frost Pi`, `SideChatAI`,
  `Quick Open Browser Tab`, `This PC`, `Documents`, `Downloads`), which the user
  fills in in the iPad's Settings form.

A target left empty is legal but stays disabled and sends nothing. Chord and
text targets are validated against the existing HID key/modifier tables at
helper start (the helper prints a "layout configuration notice" instead of
leaving the user to discover it on the iPad), and an unparseable document falls
back to the shipped defaults.

## Limitations / not yet done

* **The iPad side exists in source but has never been compiled.**
  `BTRemote/WindowsForeground.swift` implements the matching client: it reads the
  host/port/fingerprint from Settings, opens `wss://<private-IPv4>:<port>`, pins
  the helper's self-signed certificate by SHA-256 fingerprint, sends
  `{"type":"pair","code":...}` first, stores the returned 32-byte secret in the
  iOS Keychain, reconnects later with `{"type":"reconnect","secret":...}`, and
  falls back to the generic §7.1 layout on any disconnect, error or unknown
  identity. There is no Xcode/swift on this Windows machine, so that code is
  unbuilt and untested; the iOS build must be confirmed by the macOS GitHub
  Actions job and the behaviour by the owner's §9 item 10 hardware session.
  Do not report §7.2 as complete on the strength of this helper alone.
* **Trust model is TOFU + shared secret**, not a CA: the certificate is
  self-signed precisely so it can be pinned; nothing verifies it in the field.
* **At-rest protection scope.** DPAPI protects the persisted certificate and
  device secret against other Windows users, not against the same user account
  (and therefore not against malware running as that user).
* **Durable pairing is one-device-per-helper.** Once the code is spent and the
  secret stored, a *different* iPad cannot pair without restarting the helper
  to get a fresh code.
* **True mutual TLS is not implemented.** Reconnection proves possession of the
  shared secret; the server does not issue/verify a client X.509 identity.
  Doing that properly needs an issued client certificate held in the iPad
  keychain/Secure Enclave, which is outside this bounded step.
* **Single-homed bind.** Only the first private IPv4 address is used; on a
  multi-homed Windows host the reachable address must be that one, or the port
  argument must be changed.
