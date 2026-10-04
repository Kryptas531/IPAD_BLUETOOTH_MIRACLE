"""Encrypted local storage for TV laptop credentials (SPEC 7.3H).

Windows credential store under %LOCALAPPDATA%/BTRemote/TVMCP using
current-user DPAPI through ctypes stdlib (no third-party deps).

Rules implemented here:
- Combined cert/key/pairing-pin envelope encrypted at rest, atomic updates.
- Never persistent plaintext keys or plain URL bookmark data.
- Read/corruption failures never overwrite valid credentials.
- No PIN/key/private-URL content ever appears in returned strings.
"""

from __future__ import annotations

import ctypes
import json
import os
import uuid
from ctypes import wintypes
from pathlib import Path
from typing import Any

# Fixed domain-separation entropy for DPAPI. Not a secret; it only prevents
# accidental cross-decryption by other apps using raw DPAPI for other purposes.
_DPAPI_ENTROPY = b"btr.tv-mcp.v1"

# Credential file holds the combined cert/key/pin envelope; library file holds
# user-configured app/bookmark targets (may contain private content URLs).
CREDENTIALS_FILE = "tv-credentials.bin"
LIBRARY_FILE = "tv-library.bin"


class StoreError(Exception):
    """Base error for storage problems."""


class StoreCorruptError(StoreError):
    """Stored data exists but cannot be decrypted/parsed.

    On this error the store is NEVER auto-replaced; the caller must keep the
    existing bytes and surface a useful message (SPEC: persistence errors
    preserve existing user data).
    """


class _DATA_BLOB(ctypes.Structure):
    _fields_ = [
        ("cbData", wintypes.DWORD),
        ("pbData", ctypes.POINTER(ctypes.c_char)),
    ]


def _make_blob(data: bytes) -> tuple[_DATA_BLOB, ctypes.Array]:
    buf = ctypes.create_string_buffer(data, len(data))
    blob = _DATA_BLOB()
    blob.cbData = len(data)
    blob.pbData = ctypes.cast(buf, ctypes.POINTER(ctypes.c_char))
    return blob, buf  # keep buf alive alongside blob


def dpapi_protect(data: bytes) -> bytes:
    """Encrypt data for the current Windows user (DPAPI, UI forbidden)."""
    if os.name != "nt":
        raise StoreError("DPAPI storage requires Windows")
    crypt32 = ctypes.windll.crypt32
    blob_in, in_buf = _make_blob(data)
    entropy, ent_buf = _make_blob(_DPAPI_ENTROPY)
    blob_out = _DATA_BLOB()
    ok = crypt32.CryptProtectData(
        ctypes.byref(blob_in),
        None,
        ctypes.byref(entropy),
        None,
        None,
        0x00000001,  # CRYPTPROTECT_UI_FORBIDDEN
        ctypes.byref(blob_out),
    )
    if not ok:
        raise StoreError(f"CryptProtectData failed (error {ctypes.get_last_error()})")
    out = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    del in_buf, ent_buf
    return out


def dpapi_unprotect(blob: bytes) -> bytes:
    """Decrypt data previously protected for the current Windows user."""
    if os.name != "nt":
        raise StoreError("DPAPI storage requires Windows")
    crypt32 = ctypes.windll.crypt32
    blob_in, in_buf = _make_blob(blob)
    entropy, ent_buf = _make_blob(_DPAPI_ENTROPY)
    blob_out = _DATA_BLOB()
    ok = crypt32.CryptUnprotectData(
        ctypes.byref(blob_in),
        None,
        ctypes.byref(entropy),
        None,
        None,
        0x00000001,  # CRYPTPROTECT_UI_FORBIDDEN
        ctypes.byref(blob_out),
    )
    if not ok:
        raise StoreCorruptError(
            "stored data could not be decrypted for the current Windows user "
            "(DPAPI unprotect failed); existing file preserved, not overwritten"
        )
    out = ctypes.string_at(blob_out.pbData, blob_out.cbData)
    ctypes.windll.kernel32.LocalFree(blob_out.pbData)
    del in_buf, ent_buf
    return out


class CredentialStore:
    """Encrypted-at-rest, atomically-updated store for two JSON documents:
    the TV credential envelope (cert+key+pin+pin sha256+host) and the local
    app/bookmark library (targets may be private URLs).
    """

    def __init__(self, base_dir: Path | None = None) -> None:
        if base_dir is None:
            local = os.environ.get("LOCALAPPDATA", "")
            if not local:
                raise StoreError("LOCALAPPDATA is not set; cannot locate Windows app-data")
            base_dir = Path(local) / "BTRemote" / "TVMCP"
        self.base_dir = Path(base_dir)

    # -- atomic write -------------------------------------------------------

    def _atomic_write(self, path: Path, data: bytes) -> None:
        self.base_dir.mkdir(parents=True, exist_ok=True)
        tmp = self.base_dir / f"{path.name}.tmp-{uuid.uuid4().hex}"
        try:
            with open(tmp, "wb") as f:
                f.write(data)
                f.flush()
                os.fsync(f.fileno())
            os.replace(tmp, path)
        except BaseException:
            try:
                if tmp.exists():
                    tmp.unlink()
            except OSError:
                pass
            raise

    # -- credentials envelope ----------------------------------------------

    @property
    def credentials_path(self) -> Path:
        return self.base_dir / CREDENTIALS_FILE

    def save_credentials(self, data: dict[str, Any]) -> None:
        payload = json.dumps(data).encode("utf-8")
        self._atomic_write(self.credentials_path, dpapi_protect(payload))

    def load_credentials(self) -> dict[str, Any] | None:
        """Return the stored envelope, or None when nothing is stored.

        Raises StoreCorruptError when a file exists but cannot be recovered.
        Never modifies the file on any failure path.
        """
        if not self.credentials_path.is_file():
            return None
        raw = self.credentials_path.read_bytes()
        plain = dpapi_unprotect(raw)  # raises StoreCorruptError on failure
        try:
            data = json.loads(plain.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StoreCorruptError(
                f"stored credentials file is not valid JSON after decryption: {type(exc).__name__}"
            ) from exc
        if not isinstance(data, dict):
            raise StoreCorruptError("stored credentials envelope is not a JSON object")
        return data

    def delete_credentials(self) -> bool:
        removed = False
        if self.credentials_path.is_file():
            self.credentials_path.unlink()
            removed = True
        return removed

    # -- library (apps/bookmarks) -------------------------------------------

    @property
    def library_path(self) -> Path:
        return self.base_dir / LIBRARY_FILE

    def save_library(self, data: dict[str, Any]) -> None:
        payload = json.dumps(data).encode("utf-8")
        self._atomic_write(self.library_path, dpapi_protect(payload))

    def load_library(self) -> dict[str, Any] | None:
        if not self.library_path.is_file():
            return None
        raw = self.library_path.read_bytes()
        plain = dpapi_unprotect(raw)
        try:
            data = json.loads(plain.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise StoreCorruptError(
                f"stored library file is not valid JSON after decryption: {type(exc).__name__}"
            ) from exc
        if not isinstance(data, dict):
            raise StoreCorruptError("stored library envelope is not a JSON object")
        return data
