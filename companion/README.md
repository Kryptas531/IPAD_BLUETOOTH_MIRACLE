# Windows companion helper (`WindowsForeground`)

.NET 8 console helper that tells the paired iPad which Windows application is
in the foreground, so the iPad can switch to the matching CONTROL layout
(SPEC §7.1/§7.2, spec commit `b751488`). It is the Windows side of the
iPad → BLE HID → Windows controller project; it never sends HID input itself.

## Build and run

```powershell
cd 'C:\LIFE\IPAD BLTH'
dotnet build companion\WindowsForeground\WindowsForeground.csproj -c Release
dotnet run --project companion\WindowsForeground\WindowsForeground.csproj -c Release   # optional [port], default 8443
dotnet run --project companion\WindowsForeground.Tests\WindowsForeground.Tests.csproj -c Release
```

No NuGet packages: only the .NET 8 base class library (`System.Net`,
`System.Net.WebSockets`, `System.Security.Cryptography`) plus two `crypt32`
P/Invoke entry points. Tests are dependency-free (`ALL TESTS PASSED`, exit 0).

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
* **Application tracking.** `ForegroundWatcher` polls the foreground window's
  process every 350 ms; `ForegroundMapping` maps the executable *file name*
  only (`Code.exe` → `vscode`, `chrome.exe` → `chrome`, `explorer.exe` →
  `explorer`, anything else including unknown/unavailable → `generic`). Window
  titles are never consulted. After authentication the only message the helper
  ever sends is `{"type":"foreground-changed","identity":"<token>"}`.
* **Single device.** One iPad per helper run; a second socket is closed
  without data while a client is already connected.

## Limitations / not yet done

* **No iOS/iPadOS client exists yet.** The Windows side is implemented, but the
  iPad side must still (a) trust or pin the printed certificate fingerprint,
  (b) store the secret returned by `{"type":"paired",...}` and (c) send
  `{"type":"reconnect","secret":...}` after a disconnect. Until that work is
  done, secure reconnect cannot be exercised end-to-end and the channel is not
  MITM-proof. Do not report §7.2 as complete on the strength of this helper.
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
  keychain/Secure Enclave, which is outside this bounded step (no iOS edits).
* **Single-homed bind.** Only the first private IPv4 address is used; on a
  multi-homed Windows host the reachable address must be that one, or the port
  argument must be changed.
* The `paired` / `reconnected` messages and the long-lived device credential
  are **not yet described in `SPEC.md`** (§7.2 still describes only the
  one-time code); the spec needs a follow-up commit.
