"""TV controller for SPEC 52d93f1 section 7.3 H.

Drives the pinned canonical reference client (androidtvremote2 @
b09f21432ba33e42536215a8f41641d801cf6a2c, Android TV Remote v2) for the
Windows laptop reference remote. The laptop is a reference/control surface
only; nothing here touches the PC BLE HID path.

Contract rules implemented in this module:
- androidtvremote2 is imported lazily; module import and controller
  construction never connect, pair or send anything (startup must not
  network-connect, tests stay dependency-free).
- Every network step (pair start/finish, connect) is bounded by a timeout.
- Commands (key press, launch) are accepted ONLY on a connection whose peer
  certificate SHA256 matches the pin captured from the actual pairing TLS
  transport after successful PIN entry ("cert pin before commands").
- A changed/mismatched peer certificate is rejected without deleting saved
  credentials; a timeout during command entry does not delete them either.
- Pairing code format is validated before use; a stale (expired) pairing
  session is discarded instead of being finished with late input.
- Results distinguish "command_sent" (what this process did) from observed
  TV state (power/current_app/device reported by the TV), and never echo
  PINs, key material or private target URLs.

Third-party runtime dependencies (NOT iPad dependencies, do not add more):
- androidtvremote2 @ git+https://github.com/tronikos/androidtvremote2
  @b09f21432ba33e42536215a8f41641d801cf6a2c  (Apache-2.0, canonical reference)
- mcp SDK >=1,<2  (MIT, used by server.py only)
This project's own code remains AGPL-3.0-only (see repository LICENSE).
"""

from __future__ import annotations

import asyncio
import hashlib
import ipaddress
import json
import os
import shutil
import subprocess
import time
import uuid
from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlparse

from . import library
from .store import CredentialStore, StoreCorruptError, StoreError

CLIENT_NAME = "BTRemote laptop reference"

DEFAULT_CONNECT_TIMEOUT = 15.0
DEFAULT_FINISH_TIMEOUT = 15.0
DEFAULT_PIN_WAIT_TIMEOUT = 120.0

# Allowlisted semantic key names -> RemoteKeyCode enum names (verified against
# remotemessage_pb2.py at the pinned revision). Arbitrary Android key codes are
# deliberately not accepted.
KEY_CODES: dict[str, str] = {
    "up": "KEYCODE_DPAD_UP",
    "down": "KEYCODE_DPAD_DOWN",
    "left": "KEYCODE_DPAD_LEFT",
    "right": "KEYCODE_DPAD_RIGHT",
    "ok": "KEYCODE_DPAD_CENTER",
    "back": "KEYCODE_BACK",
    "home": "KEYCODE_HOME",
    "volumeup": "KEYCODE_VOLUME_UP",
    "volumedown": "KEYCODE_VOLUME_DOWN",
    "mute": "KEYCODE_VOLUME_MUTE",
    "playpause": "KEYCODE_MEDIA_PLAY_PAUSE",
    "stop": "KEYCODE_MEDIA_STOP",
    "next": "KEYCODE_MEDIA_NEXT",
    "previous": "KEYCODE_MEDIA_PREVIOUS",
    "rewind": "KEYCODE_MEDIA_REWIND",
    "forward": "KEYCODE_MEDIA_FAST_FORWARD",
    "power": "KEYCODE_POWER",
}

LAUNCH_NOTE = (
    "launch command sent; confirm on the TV screen — sending is not proof "
    "that the app opened or playback started"
)
KEY_NOTE = "key command queued; confirm on the TV screen"
REPAIR_NOTE = "existing saved pairing kept; re-pair explicitly if needed"


def _fail(stage: str, message: str, **extra: Any) -> dict[str, Any]:
    result: dict[str, Any] = {"ok": False, "stage": stage, "error": message}
    result.update(extra)
    return result


def _connect_phase(remote: Any) -> str:
    transport = getattr(remote, "_transport", None)
    if transport is None:
        return "tcp_tls"
    protocol = getattr(remote, "_remote_message_protocol", None)
    if protocol is None or not getattr(protocol, "device_info", None):
        return "remote_configure"
    return "remote_activation_or_start"


def _peer_cert_sha256(transport: Any) -> str | None:
    """SHA256 of the peer certificate DER as seen on the live TLS transport."""
    if transport is None:
        return None
    tls = transport.get_extra_info("ssl_object")
    if tls is None:
        return None
    der = tls.getpeercert(True)
    if not der:
        return None
    return hashlib.sha256(bytes(der)).hexdigest()


def validate_numeric_host(host: Any) -> str:
    """Accept only a private, numeric, unicast IPv4/IPv6 address (SPEC 7.3 H:
    explicit manual private numeric TV address; no hostnames, no discovery).
    Raises ValueError with a message that never echoes the full input."""
    if not isinstance(host, str):
        raise ValueError("host must be a numeric private IP address")
    host = host.strip()
    if not host:
        raise ValueError("host must be a numeric private IP address")
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        raise ValueError("host must be a numeric IP address (e.g. 192.168.0.161), not a name") from None
    if addr.version == 4:
        if not addr.is_private or addr.is_multicast or addr.is_unspecified:
            raise ValueError("host must be a private numeric IPv4 address")
    else:
        # ipaddress treats unique-local as private; link-local is not usable
        # as a manual "laptop on same LAN" target without a scope id.
        if not addr.is_private or addr.is_multicast or addr.is_unspecified or addr.is_link_local:
            raise ValueError("host must be a private numeric IPv6 address (unique-local)")
    return host


class TVController:
    """Serialised, bounded TV control backed by the reference library.

    ``store`` and ``remote_cls`` are injectable so unit tests run with
    stdlib + fakes only; production wiring leaves both as None and gets the
    DPAPI-backed CredentialStore and the lazily-imported AndroidTVRemote.
    ``remote_cls`` must expose the same constructor and method names as
    androidtvremote2.AndroidTVRemote (the actual library API, including the
    private ``_pairing_message_protocol``/``_transport`` attributes used for
    certificate capture at the verified reference call sites).
    """

    def __init__(
        self,
        store: CredentialStore | None = None,
        remote_cls: Any | None = None,
        connect_timeout: float = DEFAULT_CONNECT_TIMEOUT,
        finish_timeout: float = DEFAULT_FINISH_TIMEOUT,
        pin_wait_timeout: float = DEFAULT_PIN_WAIT_TIMEOUT,
    ) -> None:
        self._store = store
        self._remote_cls = remote_cls
        self.connect_timeout = connect_timeout
        self.finish_timeout = finish_timeout
        self.pin_wait_timeout = pin_wait_timeout
        self._lock = asyncio.Lock()
        self._remote: Any | None = None      # connected AndroidTVRemote
        self._pin: str | None = None        # peer cert sha256 of saved creds
        self._connected = False             # live connection with verified pin
        self._pending: dict[str, Any] | None = None  # in-progress pair session
        self._work_dir: Path | None = None  # restricted PEM directory
        self.diagnostics: dict[str, Any] = {}

    # -- dependency wiring ---------------------------------------------------

    def _ensure_store(self) -> CredentialStore:
        if self._store is None:
            self._store = CredentialStore()
        return self._store

    def _resolve_remote_cls(self) -> Any:
        if self._remote_cls is not None:
            return self._remote_cls
        try:
            from androidtvremote2 import AndroidTVRemote  # lazy: installed by `pip install .`
        except Exception as exc:  # ImportError or broken transitive dep
            raise RuntimeError(
                "androidtvremote2 (pinned git revision) is not installed; "
                "install project dependencies first (see README)"
            ) from exc
        return AndroidTVRemote

    # -- internal helpers ----------------------------------------------------

    def _ensure_work_dir(self) -> Path:
        if self._work_dir is None:
            base = self._ensure_store().base_dir
            # Unique directory per session; leftover directories from a crashed
            # run are left untouched (no broad deletion) and are identifiable
            # by the "pem-" prefix.
            work = base / f"pem-{uuid.uuid4().hex[:8]}"
            work.mkdir(parents=True, exist_ok=True)
            self._work_dir = work
            self.diagnostics["pem_dir"] = "created"
            self.diagnostics["pem_acl"] = self._restrict_dir(work)
            if self.diagnostics["pem_acl"] != "applied":
                self._remove_work_dir()
                raise StoreError("Could not restrict transient credential access; no PEM material written")
        return self._work_dir

    @staticmethod
    def _restrict_dir(directory: Path) -> str:
        """Restrict before writing any PEM; caller fails closed on ACL failure."""
        try:
            who = subprocess.run(
                [str(Path(os.environ["SystemRoot"]) / "System32" / "whoami.exe")],
                capture_output=True, text=True, timeout=5
            )
            user = who.stdout.strip() if who.returncode == 0 else ""
            if not user:
                return "skipped:no-whoami"
            result = subprocess.run(
                [
                    str(Path(os.environ["SystemRoot"]) / "System32" / "icacls.exe"),
                    str(directory),
                    "/inheritance:r",
                    "/grant:r",
                    f"{user}:(OI)(CI)F",
                ],
                capture_output=True,
                text=True,
                timeout=10,
            )
            return "applied" if result.returncode == 0 else f"failed:exit-{result.returncode}"
        except Exception as exc:
            return f"unavailable:{type(exc).__name__}"

    def _remove_work_dir(self) -> None:
        if self._work_dir is not None:
            try:
                target = self._work_dir.resolve()
                base = self._ensure_store().base_dir.resolve()
                if target.parent != base or not target.name.startswith("pem-"):
                    raise StoreError("Refusing cleanup outside the owned transient credential directory")
                shutil.rmtree(target)
                self.diagnostics["pem_cleanup"] = "removed"
            except Exception as exc:
                self.diagnostics["pem_cleanup"] = f"failed:{type(exc).__name__}"
            self._work_dir = None

    def _drop_connection(self) -> None:
        if self._remote is not None:
            try:
                self._remote.disconnect()
            except Exception as exc:
                self.diagnostics["disconnect_error"] = type(exc).__name__
            self._remote = None
        self._connected = False

    def _require_connection(self) -> dict[str, Any] | None:
        if not (self._connected and self._remote is not None):
            return _fail(
                "connect",
                "not connected to a pin-verified TV; run tv_connect first",
                note=REPAIR_NOTE,
            )
        return None

    def _observed(self) -> dict[str, Any]:
        """Sanitized observed state from the connected remote (no secrets)."""
        if not (self._connected and self._remote is not None):
            return {}
        observed: dict[str, Any] = {}
        try:
            protocol = self._remote._remote_message_protocol
            if protocol is not None:
                observed["features"] = int(protocol._active_features)
                observed["device"] = protocol.device_info
                observed["power"] = protocol.is_on
                observed["current_app"] = protocol.current_app
                observed["volume"] = getattr(protocol, "volume_info", None)
        except Exception:
            self.diagnostics["observe_error"] = "true"
        return observed

    # -- pairing (explicit, bounded, human PIN separate) ---------------------

    async def pair_start(self, host: Any) -> dict[str, Any]:
        """Begin pairing to a private numeric TV address. Never auto-runs."""
        async with self._lock:
            if self._pending is not None:
                return _fail(
                    "validate",
                    "a pairing session is already in progress; finish it with "
                    "tv_pair_finish or call tv_disconnect first",
                )
            try:
                host = validate_numeric_host(host)
            except ValueError as exc:
                return _fail("validate", str(exc))
            try:
                store = self._ensure_store()
                creds = store.load_credentials()
            except StoreCorruptError as exc:
                return _fail("vault", f"stored credentials unreadable; file preserved, not overwritten: {exc}")
            except StoreError as exc:
                return _fail("storage", str(exc))
            if creds is not None:
                return _fail(
                    "validate",
                    "credentials already saved for TV "
                    f"{creds.get('host', '<unknown>')}; use tv_connect, or "
                    "tv_forget_pairing with explicit confirmation before re-pairing",
                    note="saved credentials were not modified",
                )
            remote_cls = self._resolve_remote_cls()
            work = self._ensure_work_dir()
            cert_path = work / "client.pem"
            key_path = work / "key.pem"
            remote = None
            try:
                remote = remote_cls(CLIENT_NAME, str(cert_path), str(key_path), host)
                await remote.async_generate_cert_if_missing()
                await asyncio.wait_for(remote.async_start_pairing(), self.connect_timeout)
                pin = _peer_cert_sha256(remote._pairing_message_protocol.transport)
                if pin is None:
                    raise RuntimeError("no peer certificate observed on the pairing transport")
            except Exception as exc:
                if remote is not None:
                    try:
                        remote.disconnect()
                    except Exception:
                        pass
                self._remove_work_dir()
                return _fail(
                    "pair_start",
                    f"pairing start failed at network/step boundary: {type(exc).__name__}: {exc}",
                    note="no credentials saved",
                )
            self._pending = {
                "remote": remote,
                "host": host,
                "pin": pin,
                "expires": time.monotonic() + self.pin_wait_timeout,
                "cert_path": cert_path,
                "key_path": key_path,
            }
            return {
                "ok": True,
                "stage": "pair_start",
                "host": host,
                "next": "read the 6-digit code shown on the TV and call tv_pair_finish with it",
                "deadline_seconds": self.pin_wait_timeout,
            }

    async def pair_finish(self, code: str) -> dict[str, Any]:
        """Complete pairing with the 6-digit code the human read off the TV.

        A pairing session whose PIN window expired is discarded (stale
        callbacks never finalize credentials)."""
        async with self._lock:
            if self._pending is None:
                return _fail(
                    "validate",
                    "no pairing session in progress (stale or expired pairing "
                    "callbacks are discarded); start again with tv_pair_start",
                )
            if time.monotonic() >= self._pending["expires"]:
                pending = self._pending
                self._pending = None
                try:
                    pending["remote"].disconnect()
                except Exception:
                    pass
                self._remove_work_dir()
                return _fail(
                    "pair_finish",
                    "pairing window expired before a code was entered; "
                    "session discarded; start again with tv_pair_start",
                )
            if not isinstance(code, str):
                return _fail("validate", "pairing code must be a string")
            code = code.strip()
            try:
                if len(code) != 6:
                    raise ValueError
                bytes.fromhex(code)
            except ValueError:
                return _fail("validate", "pairing code must be exactly 6 hexadecimal digits (as shown on the TV)")
            remote = self._pending["remote"]
            host = self._pending["host"]
            pin = self._pending["pin"]
            try:
                await asyncio.wait_for(remote.async_finish_pairing(code), self.finish_timeout)
            except Exception as exc:
                # Wrong PIN or lost session: keep nothing half-paired, but do
                # not touch any previously saved credentials.
                self._pending = None
                try:
                    remote.disconnect()
                except Exception:
                    pass
                self._remove_work_dir()
                return _fail(
                    "pair_finish",
                    f"pairing could not be completed: {type(exc).__name__}: {exc}",
                    note="no credentials saved; previously saved credentials unchanged",
                )
            try:
                cert_pem = Path(self._pending["cert_path"]).read_text(encoding="ascii")
                key_pem = Path(self._pending["key_path"]).read_text(encoding="ascii")
            except Exception as exc:
                self._pending = None
                self._remove_work_dir()
                return _fail("pair_finish", f"client certificate files missing: {type(exc).__name__}")
            self._pending = None
            try:
                self._ensure_store().save_credentials(
                    {"schema": 1, "host": host, "pin": pin, "cert": cert_pem, "key": key_pem}
                )
            except Exception as exc:
                self._remove_work_dir()
                return _fail("storage", f"pairing succeeded but credentials could not be persisted: {type(exc).__name__}")
            self._remove_work_dir()
            return {
                "ok": True,
                "stage": "pair_confirmed",
                "host": host,
                "credentials": "encrypted at rest (DPAPI, current Windows user)",
                "next": "call tv_connect (same host) to verify the pinned certificate before any command",
            }

    # -- connect / status ----------------------------------------------------

    async def connect(self, host: str | None = None) -> dict[str, Any]:
        """Reconnect using saved credentials. No new PIN is needed.

        Verifies the live peer certificate SHA256 against the pin captured at
        successful pairing BEFORE the connection is accepted for commands."""
        async with self._lock:
            if self._pending is not None:
                return _fail(
                    "validate",
                    "pairing is still in progress; finish it with tv_pair_finish or call tv_disconnect first",
                )
            if self._connected:
                result: dict[str, Any] = {"ok": True, "stage": "already_connected", "host": self._remote.host if self._remote else None}
                result.update(self._observed())
                return result
            try:
                store = self._ensure_store()
                creds = store.load_credentials()
            except (StoreCorruptError, StoreError) as exc:
                return _fail("vault", f"saved credentials unavailable: {exc}")
            if creds is None:
                return _fail("validate", "no saved laptop pairing; run tv_pair_start then tv_pair_finish")
            if isinstance(host, str) and host.strip() and host.strip() != creds.get("host"):
                return _fail(
                    "validate",
                    "requested host does not match the saved pairing host; use the saved host or re-pair explicitly",
                )
            saved_host = creds.get("host")
            try:
                validate_numeric_host(saved_host)
            except ValueError as exc:
                return _fail("validate", f"saved host is invalid: {exc}")
            cert = creds.get("cert")
            key = creds.get("key")
            pin = creds.get("pin")
            if not (isinstance(cert, str) and cert and isinstance(key, str) and key and isinstance(pin, str) and pin):
                return _fail("validate", "saved credential envelope is incomplete; re-pair explicitly")
            work = self._ensure_work_dir()
            cert_path = work / "client.pem"
            key_path = work / "key.pem"
            remote = None
            try:
                cert_path.write_text(cert, encoding="ascii")
                key_path.write_text(key, encoding="ascii")
                remote_cls = self._resolve_remote_cls()
                remote = remote_cls(CLIENT_NAME, str(cert_path), str(key_path), saved_host)
                await asyncio.wait_for(remote.async_connect(), self.connect_timeout)
                observed_pin = _peer_cert_sha256(remote._transport)
            except Exception as exc:
                phase = _connect_phase(remote)
                if remote is not None:
                    try:
                        remote.disconnect()
                    except Exception:
                        pass
                self._remove_work_dir()
                return _fail(
                    "connect",
                    f"connection to the TV failed: {type(exc).__name__}: {exc}",
                    waiting_for=phase,
                    note="saved credentials kept; no commands accepted while disconnected",
                )
            if observed_pin != pin:
                try:
                    remote.disconnect()
                except Exception:
                    pass
                self._remove_work_dir()
                return _fail(
                    "cert_pin",
                    "peer certificate does not match the saved pairing pin; "
                    "connection rejected and no commands accepted; re-pair explicitly (tv_pair_start/tv_pair_finish)",
                    note="saved credentials kept for diagnosis",
                )
            self._remote = remote
            self._pin = pin
            self._connected = True
            result = {"ok": True, "stage": "connected", "host": saved_host}
            result.update(self._observed())
            result["note"] = "commands and launches require explicit tool calls; a send is never proof of TV-side behavior"
            return result

    async def disconnect(self) -> dict[str, Any]:
        async with self._lock:
            self._drop_connection()
            if self._pending is not None:
                pending_remote = self._pending["remote"]
                self._pending = None
                try:
                    pending_remote.disconnect()
                except Exception:
                    pass
            self._remove_work_dir()
            return {"ok": True, "stage": "disconnected", "note": "connection and transient PEM files disposed"}

    async def status(self) -> dict[str, Any]:
        async with self._lock:
            result: dict[str, Any] = {
                "ok": True,
                "stage": "status",
                "has_stored_pairing": False,
                "connected": self._connected,
                "pending_pairing": self._pending is not None,
            }
            try:
                creds = self._ensure_store().load_credentials()
                if creds is not None:
                    result["has_stored_pairing"] = True
                    result["host"] = creds.get("host")
                    result["has_pin"] = bool(creds.get("pin"))
                    result["has_certificate_material"] = bool(creds.get("cert") and creds.get("key"))
            except (StoreCorruptError, StoreError) as exc:
                result["ok"] = False
                result["stage"] = "vault"
                result["error"] = f"stored credentials unavailable: {exc}"
            if self._connected:
                result.update(self._observed())
            result["note"] = "startup never connects; nothing was sent to the TV unless a command stage says command_sent"
            return result

    async def forget_pairing(self, confirm: Any) -> dict[str, Any]:
        """Explicit-only removal of the laptop's own credentials. Never
        automatic and never touches iPad or Windows-helper credentials."""
        async with self._lock:
            if confirm is not True:
                return _fail(
                    "validate",
                    "forgetting the saved laptop pairing requires explicit confirmation: call tv_forget_pairing with confirm=true",
                )
            self._drop_connection()
            if self._pending is not None:
                pending_remote = self._pending["remote"]
                self._pending = None
                try:
                    pending_remote.disconnect()
                except Exception:
                    pass
            self._remove_work_dir()
            removed = False
            try:
                removed = self._ensure_store().delete_credentials()
            except Exception as exc:
                return _fail("storage", f"could not remove stored credentials: {type(exc).__name__}")
            return {
                "ok": True,
                "stage": "forgotten",
                "removed_stored_credentials": removed,
                "note": "laptop pairing credentials removed; iPad/Windows-helper credentials are separate and untouched; re-pair explicitly when ready",
            }

    # -- commands (only on a pin-verified connection; never replayed) --------

    async def send_key(self, name: str) -> dict[str, Any]:
        async with self._lock:
            key = name.strip().lower() if isinstance(name, str) else ""
            if key not in KEY_CODES:
                # Message lists supported names only; never echoes user input.
                return _fail(
                    "validate",
                    "unsupported key name; supported keys: " + ", ".join(sorted(KEY_CODES)),
                )
            blocked = self._require_connection()
            if blocked is not None:
                return blocked
            try:
                self._remote.send_key_command(KEY_CODES[key])
            except Exception as exc:
                return _fail("key_send", f"key command could not be sent: {type(exc).__name__}: {exc}")
            return {"ok": True, "stage": "command_sent", "action": "key", "key": key, "note": KEY_NOTE}

    async def open_link(self, target: str) -> dict[str, Any]:
        async with self._lock:
            try:
                library.validate_target("app", target)
            except library.ValidationError as exc:
                # Validation message names the rejected scheme only, never the target.
                return _fail("validate", f"target rejected: {exc}")
            blocked = self._require_connection()
            if blocked is not None:
                return blocked
            try:
                # Bare package ids are converted to market://launch?id=<pkg> by
                # the reference client itself; URIs pass through unchanged.
                self._remote.send_launch_app_command(target)
            except Exception as exc:
                return _fail("launch_send", f"launch command could not be sent: {type(exc).__name__}: {exc}")
            scheme = urlparse(target).scheme.lower()
            kind = f"uri:{scheme}" if scheme else "android_package"
            return {"ok": True, "stage": "command_sent", "action": "launch", "target_kind": kind, "note": LAUNCH_NOTE}

    async def open_app(self, item_id: Any) -> dict[str, Any]:
        async with self._lock:
            try:
                data = self._ensure_store().load_library()
            except (StoreCorruptError, StoreError) as exc:
                return _fail("vault", f"stored library unavailable: {exc}")
            lib = library.TVLibrary.from_dict(data)
            item = lib.find(item_id.strip()) if isinstance(item_id, str) else None
            if item is None:
                return _fail("validate", "library item not found; check tv_list_items for item ids")
            try:
                library.validate_target(item.kind, item.target)
            except library.ValidationError as exc:
                return _fail("validate", f"stored item target is no longer valid: {exc}")
            blocked = self._require_connection()
            if blocked is not None:
                return blocked
            try:
                self._remote.send_launch_app_command(item.target)
            except Exception as exc:
                return _fail("launch_send", f"launch command could not be sent: {type(exc).__name__}: {exc}")
            return {"ok": True, "stage": "command_sent", "action": "launch", "item": item.title, "note": LAUNCH_NOTE}

    # -- local app/bookmark library (user-configured, no discovery) ----------

    async def save_item(self, kind: str, title: str, target: str, item_id: str = "") -> dict[str, Any]:
        async with self._lock:
            if not isinstance(kind, str) or kind not in library.KINDS:
                return _fail("validate", f"kind must be one of: {', '.join(library.KINDS)}")
            try:
                data = self._ensure_store().load_library()
            except (StoreCorruptError, StoreError) as exc:
                return _fail("vault", f"stored library unavailable: {exc}")
            lib = library.TVLibrary.from_dict(data)
            new_id = item_id.strip() if isinstance(item_id, str) else ""
            existing = lib.find(new_id) if new_id else None
            try:
                if existing is not None:
                    if kind != existing.kind:
                        return _fail("validate", "item kind cannot change after creation; delete it and create a new one")
                    library.validate_title(title)
                    library.validate_target(kind, target)
                    existing.title = title
                    existing.target = target
                    assigned_id = existing.id
                else:
                    lib.validate_new(kind, title, target, new_id)
                    assigned_id = new_id or str(uuid.uuid4())
                    lib.items.append(library.TVItem(id=assigned_id, kind=kind, title=title, target=target))
            except library.ValidationError as exc:
                return _fail("validate", str(exc))
            try:
                self._ensure_store().save_library(lib.to_dict())
            except Exception as exc:
                return _fail("storage", f"library could not be saved: {type(exc).__name__}")
            # Item target (may be a private content URL) is deliberately not echoed.
            return {
                "ok": True,
                "stage": "item_saved",
                "item": {"id": assigned_id, "kind": kind, "title": title},
                "note": "target stored encrypted; not repeated in results",
            }

    async def list_items(self) -> dict[str, Any]:
        async with self._lock:
            try:
                data = self._ensure_store().load_library()
            except (StoreCorruptError, StoreError) as exc:
                return _fail("vault", f"stored library unavailable: {exc}")
            lib = library.TVLibrary.from_dict(data)
            items = []
            for item in lib.items:
                scheme = urlparse(item.target).scheme.lower() if item.target else ""
                items.append(
                    {
                        "id": item.id,
                        "kind": item.kind,
                        "title": item.title,
                        "target_kind": f"uri:{scheme}" if scheme else "android_package",
                    }
                )
            return {"ok": True, "stage": "items", "items": items}

    async def delete_item(self, item_id: str) -> dict[str, Any]:
        async with self._lock:
            try:
                data = self._ensure_store().load_library()
            except (StoreCorruptError, StoreError) as exc:
                return _fail("vault", f"stored library unavailable: {exc}")
            lib = library.TVLibrary.from_dict(data)
            if not (isinstance(item_id, str) and item_id.strip()):
                return _fail("validate", "item id must be a non-empty string")
            if lib.find(item_id.strip()) is None:
                return _fail("validate", "library item not found")
            lib.items = [i for i in lib.items if i.id != item_id.strip()]
            try:
                self._ensure_store().save_library(lib.to_dict())
            except Exception as exc:
                return _fail("storage", f"library could not be saved: {type(exc).__name__}")
            return {"ok": True, "stage": "item_deleted"}
