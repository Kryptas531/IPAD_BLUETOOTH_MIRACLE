# TV MCP

Windows laptop control for Android TV Remote v2, exposed through local MCP stdio.
SPEC `52d93f1` §7.3 H. This optional tool does not relay iPad traffic or change PC BLE input.

## Run on this workstation

The installed environment is `.venv`. Pairing to the owner's TCL at `192.168.0.161`
is already stored separately from the iPad, encrypted for the current Windows user.
Starting the MCP server does not connect to the TV or send controls.

```powershell
& 'C:\LIFE\IPAD BLTH\companion\TVMCP\.venv\Scripts\python.exe' -m tv_mcp serve
```

Use [mcp-config.example.json](./mcp-config.example.json) to configure an MCP client.
Then call `tv_connect`, followed by an explicit control or app command. The local
catalog contains the owner-verified Lampa entry (`lampa`). Configuration has not been
added to a global MCP client automatically.

For another workstation, create `.venv` using its verified Python 3.12+ interpreter,
then install this package with `uv.exe pip install --python .venv/Scripts/python.exe -e .`.
Git and network access are needed during installation, not for local TV control.

## Tools

- `tv_pair_start(host)` starts pairing and makes the TV display a six-digit code.
- `tv_pair_finish(code)` confirms that code within the pairing window.
- `tv_connect(host="")`, `tv_disconnect`, `tv_status` manage the saved session.
- `tv_key(name)` sends up/down/left/right/ok/back/home, volumeup/volumedown/mute,
  playpause/stop/next/previous/rewind/forward/power.
- `tv_open_app(item_id)` opens a saved app or bookmark. Use `lampa` for Lampa.
- `tv_open_link(target)` opens an explicit supported link.
- `tv_save_item(kind, title, target, item_id="")`, `tv_list_items`, `tv_delete_item`
  manage the local app/bookmark catalog.
- `tv_forget_pairing(confirm=true)` explicitly deletes only laptop TV credentials.

The app catalog is user-configured; Remote v2 does not provide installed-app discovery.
Opening a film requires a link that the installed application handles. Lampa's observed
package is `top.rootu.lampa`; `lampa://top.rootu.lampa` opened it on the owner's TV.
Series/season links and automatic playback have not been verified.

## Pair another TV

Pair only after explicitly forgetting an existing laptop pairing if needed. The iPad
and Windows helper use different credentials and are unaffected.

```powershell
& 'C:\LIFE\IPAD BLTH\companion\TVMCP\.venv\Scripts\python.exe' -m tv_mcp pair --host 192.168.0.161
```

The command starts the TV prompt, then reads the code without echo in an interactive
Windows terminal. PIN entry expires after 120 seconds. Never pass PINs in command lines.

## Storage and failures

Credentials and library targets are DPAPI-encrypted under
`%LOCALAPPDATA%/BTRemote/TVMCP`. Corrupt reads do not overwrite saved data. The TV
certificate pin is saved only after successful PIN pairing; a changed pin rejects
remote controls and requires explicit re-pairing. No commands are replayed.

Transient PEM files required by the reference library use a per-session directory.
ACL restriction must succeed before writing keys. Normal disconnect, errors and MCP
shutdown remove the session files. A forcibly terminated process can leave a restricted
directory; it is not silently deleted by another live session. Never share vault/PEM files.

`command_sent` means queued on the connection. Observed device, power, current app
and volume are reported separately. The TV may ignore a key or link. Remote v2 has
no direct picture-mode or backlight setter here; Settings had no visible effect on
this TCL during testing. Brightness support and standby wake remain unverified.

## Verified on 2026-10-04

The pinned reference paired with the real TCL, connected and reconnected without a
new code. Actual MCP stdio initialize/list/call and persisted-credential connection
passed. TV feedback confirmed volume `7 → 8 → 7` and Mute `false → true → false`.
The owner confirmed Lampa launch, Play/Pause, Home and left/right navigation.
Up/down/OK/Back, other media keys, text and power/wake have not been confirmed.
The owner stopped further physical tests; series links were deferred separately.

Local checks cover encrypted storage, corruption preservation, pairing/connection
timeouts, certificate mismatch, no commands before connection, catalog validation
and MCP registration. They do not replace TV observations.

## Attribution

This project's code remains AGPL-3.0-only; see [LICENSE](../../LICENSE). Preserve
the upstream `jqssun/darwin-bt-remote` attribution. Laptop-only dependencies:
`androidtvremote2` (Apache-2.0), pinned to Git
`b09f21432ba33e42536215a8f41641d801cf6a2c`; official MCP Python SDK `mcp>=1,<2` (MIT).
These are not iPad dependencies. No ADB, custom TV APK, cloud relay or LAN listener.
