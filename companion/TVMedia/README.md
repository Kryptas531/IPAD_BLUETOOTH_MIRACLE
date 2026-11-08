> Windows-only legacy companion, not the TV-actions solution. The primary iPad TV
> surface no longer connects here. Do not install this or its CA/token to control
> Lampa, TorrServer or VLC on Android TV. Existing runtime is preserved unchanged.

# TV media companion

Standard-library Python 3.12+, Windows personal PC. Implements SPEC `3c33ef5`.
Run `python bridge.py --config C:\LOCAL\tv-media.local.json`. No installation,
service, firewall, VPN or driver changes are performed. Test with
`python3 -m unittest discover -s companion/TVMedia -v` from the repository root.

## Runtime configuration

Copy config.example.json **outside Git**, replace the placeholder token with
`secrets.token_urlsafe(32)`, and restrict config/key file access to the local user.
Use one concrete PC private IPv4 (example binds loopback for safe initial setup).
An unassigned address fails OS bind. Configure a certificate with the chosen LAN
hostname/IP in its SAN, trusted by both iPad and Python for adapter calls. Install
and explicitly trust your local CA on iPad or use an already trusted certificate.
No plaintext LAN or TLS trust override exists; existing ATS settings stay unchanged.
Enter the HTTPS origin and token in iPad TV Apps → TV Actions → Save/check.
Token goes into a separate Keychain record; endpoint is in app preferences.
Redirects are refused so credentials never follow a redirected media request.

TorrServer API is fixed to `http://127.0.0.1:8090`, consumed on Windows only.
Binary: `C:\WORK\ARSENAL\scripts\torrserver-lan\runtime\TorrServer-windows-amd64.exe`.
Database directory: same runtime's `data`, with existing `config.db` mandatory.
VLC: `C:\Program Files\VideoLAN\VLC\vlc.exe`. Nothing accepts executable overrides.
`restart_enabled: true` permits starting the stopped server or terminating only the
child this bridge created. Unknown existing port owners are never killed. Restart
uses `--path <existing data> --port 8090 --ip 127.0.0.1`, never removes DB files,
and waits for a valid list response. Verify installed version supports these flags
before runtime deployment. CLI flags reference: YouROK/TorrServer
`server/cmd/main.go`; list/get `/torrents`, stream `/stream?link=...&index=...&play=`.
The iPad explicitly chooses a returned `file_stats[].id`; no first-file autoplay.
VLC launch acceptance is not proof of playback. Check the local VLC screen.

Set `web_url` to a separately existing **trusted HTTPS** TorrServer UI URL if one
is available. This action opens Safari on iPad, never VLC and never a loopback URL
assumed to point at Windows. Starting TorrServer loopback-only does not create a
LAN web UI. Browsing/selecting/play through the authenticated bridge remains usable.

Set `authoritative_added_field` only after verifying a field in the installed API
means torrent **addition time**, as positive numeric epoch units. Leave empty if
unavailable; no ordering or filename inference. Missing/tied timestamps return an
explicit error and manual torrent selection remains available.

## Lampa adapter contract

There is no universal documented Lampa chooser/history deeplink implemented here.
A generic themoviedb.org HTTPS URL can open a browser or another handler and is NOT
represented as a Lampa action. Configure `lampa_adapter` only to an operator-verified
HTTPS adapter, not a TMDB site. No private Lampa sources are read or copied.
The adapter receives GET `action=card&kind=movie|tv&tmdb=<positive ID>` or
`action=resume`, returns JSON `{"url":"lampa://..."}` (or verified HTTPS URL).
Card must open that card's torrent chooser on the installed TV app. Resume must
use authoritative viewing history including last file/episode and playback position;
with no history return no URL / non-success, never infer history from bridge requests.
Empty/unconfigured adapter disables both actions; configured adapters can still
report unavailable at request time. TV command acceptance does not prove playback.

## Verification boundaries

HTTP handler tests use loopback without TLS solely as an in-process test fixture;
production main always wraps its socket with TLS. Python mocks cover auth, IDs,
no history, newest ambiguity, file selection/escaping, fixed argv, process ownership
and readiness failure. Linux has no Swift compiler: unsigned macOS workflow compiles
the full iOS app under Swift 6 strict concurrency and runs Python tests. Parent
handles CI/deployment. Hardware/TLS trust/installed API version acceptance is separate.
