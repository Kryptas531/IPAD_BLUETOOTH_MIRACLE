"""Pure model + validation for the local TV app/bookmark library (SPEC 7.3H,
mirrors the §7.3G Swift model in BTRemote/TVLibrary.swift — no network, no
third-party imports, no UI).

Rules:
- kinds: "app" | "bookmark"
- max 64 items, unique item IDs (assigned UUID4 strings), title <= 80 chars,
  target <= 8192 UTF-8 bytes, at most 10 recent item IDs
- app target: bare Android package id OR an allowed-scheme URI
- bookmark target: allowed-scheme URI only (http/https for user content)
- bare Android package IDs convert to "market://launch?id=<pkg>" exactly as in
  the pinned reference (tronikos commit c5d7292 / androidtv_remote.py
  send_launch_app_command). Do NOT invent Lampa or other deeplinks: unknown
  URI schemes are rejected until the owner supplies a validated link.
"""

from __future__ import annotations

import re
from dataclasses import asdict, dataclass, field
from typing import Any
from urllib.parse import urlparse

SCHEMA_VERSION = 1
MAX_ITEMS = 64
MAX_TITLE_CHARS = 80
MAX_TARGET_BYTES = 8192
MAX_RECENT_IDS = 10

# Explicit allow-lists. Everything else (javascript/data/file/content/intent/
# mailto/tel/sms/blob/vbscript and any invented scheme) is rejected.
# "lampa" added 2026-10-04: the owner supplied and verified the link form
# lampa://top.rootu.lampa on the real TCL TV (hardware evidence 00:21 UTC);
# it is the only non-generic deeplink scheme allowed. Do not invent others.
APP_URI_SCHEMES = frozenset({"http", "https", "market", "lampa"})
BOOKMARK_URI_SCHEMES = frozenset({"http", "https"})

KINDS = ("app", "bookmark")

_PACKAGE_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)+$")
_CONTROL_CHAR_RE = re.compile(r"[\x00-\x1f\x7f]")

VALIDATION_ERROR = "validation_error"


def invalid(msg: str) -> dict[str, Any]:
    return {"ok": False, "stage": "validate", "error": msg}


class ValidationError(ValueError):
    pass


def _check_no_control(value: str, label: str) -> None:
    if _CONTROL_CHAR_RE.search(value):
        raise ValidationError(f"{label} contains control characters")


def validate_title(title: str) -> None:
    if not isinstance(title, str) or not title or len(title) > MAX_TITLE_CHARS:
        raise ValidationError(f"title must be a non-empty string of at most {MAX_TITLE_CHARS} characters")


def validate_target(kind: str, target: str) -> None:
    """Validate a library item target for the given kind. Raises ValidationError."""
    if not isinstance(target, str) or not target:
        raise ValidationError("target must be a non-empty string")
    _check_no_control(target, "target")
    if len(target.encode("utf-8")) > MAX_TARGET_BYTES:
        raise ValidationError(f"target exceeds {MAX_TARGET_BYTES} UTF-8 bytes")
    scheme = urlparse(target).scheme.lower()
    if scheme:
        allowed = APP_URI_SCHEMES if kind == "app" else BOOKMARK_URI_SCHEMES
        if scheme not in allowed:
            # Message intentionally does not echo the target (private URLs must
            # not end up in logs/results) and names the rejected scheme only.
            raise ValidationError(
                f"target scheme {scheme!r} is not supported for kind {kind!r}; "
                f"allowed schemes: {', '.join(sorted(allowed))}"
            )
    elif kind == "app":
        if not _PACKAGE_RE.match(target):
            raise ValidationError("bare app target must be an Android package id like com.example.app")
    else:
        raise ValidationError("bookmark target must be a full URL (e.g. https://...)")


def app_launch_target(target: str) -> str:
    """Mirror reference send_launch_app_command: bare package ids are
    converted to market://launch?id=<package>; URIs pass through unchanged."""
    if urlparse(target).scheme:
        return target
    return f"market://launch?id={target}"


@dataclass
class TVItem:
    id: str
    kind: str
    title: str
    target: str


@dataclass
class TVLibrary:
    """User-configured catalog (NOT discovered installed apps) + recent ids."""

    items: list[TVItem] = field(default_factory=list)
    recent_ids: list[str] = field(default_factory=list)
    schema: int = SCHEMA_VERSION

    def to_dict(self) -> dict[str, Any]:
        return {
            "schema": self.schema,
            "items": [asdict(i) for i in self.items],
            "recent_ids": list(self.recent_ids),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any] | None) -> "TVLibrary":
        lib = cls()
        if not data:
            return lib
        for raw in data.get("items", []):
            if not isinstance(raw, dict):
                continue
            lib.items.append(
                TVItem(
                    id=str(raw.get("id", "")),
                    kind=str(raw.get("kind", "")),
                    title=str(raw.get("title", "")),
                    target=str(raw.get("target", "")),
                )
            )
        lib.recent_ids = [str(r) for r in data.get("recent_ids", [])]
        if data.get("schema") is not None:
            lib.schema = int(data.get("schema", SCHEMA_VERSION))
        return lib

    def find(self, item_id: str) -> TVItem | None:
        for item in self.items:
            if item.id == item_id:
                return item
        return None

    def validate_new(self, kind: str, title: str, target: str, item_id: str = "") -> None:
        """Validate an item without mutating state. Raises ValidationError."""
        if kind not in KINDS:
            raise ValidationError(f"kind must be one of: {', '.join(KINDS)}")
        validate_title(title)
        validate_target(kind, target)
        if item_id and any(i.id == item_id for i in self.items):
            raise ValidationError(f"item id {item_id!r} already exists (duplicate ids are invalid)")
        if item_id == "" and len(self.items) >= MAX_ITEMS:
            raise ValidationError(f"library is full ({MAX_ITEMS} items max; new items need a free id)")
        if item_id and len(self.items) >= MAX_ITEMS and not any(i.id == item_id for i in self.items):
            raise ValidationError(f"library is full ({MAX_ITEMS} items max)")
