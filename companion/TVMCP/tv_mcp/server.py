"""MCP stdio server for the TV laptop reference (SPEC 52d93f1 section 7.3 H).

Uses the official MCP Python SDK (mcp>=1,<2, MIT) with stdio transport only.
Every operation is explicit and bounded; startup performs no network I/O.
Tool results are JSON strings describing actual state ("command_sent" vs
observed TV state) and never contain PINs, key material or private target
URLs. androidtvremote2 is only imported lazily by controller.py.
"""

from __future__ import annotations

import json
from contextlib import asynccontextmanager
from typing import Any

from .controller import TVController

try:
    from mcp.server.fastmcp import FastMCP
    _MCP_IMPORT_ERROR: BaseException | None = None
except Exception as exc:  # dependency not installed yet — import must still succeed
    FastMCP = None  # type: ignore[assignment]
    _MCP_IMPORT_ERROR = exc

TOOL_NAMES = (
    "tv_pair_start",
    "tv_pair_finish",
    "tv_connect",
    "tv_disconnect",
    "tv_status",
    "tv_forget_pairing",
    "tv_key",
    "tv_open_link",
    "tv_open_app",
    "tv_save_item",
    "tv_list_items",
    "tv_delete_item",
)

SUPPORTED_KEYS = "up, down, left, right, ok, back, home, volumeup, volumedown, mute, playpause, stop, next, previous, rewind, forward, power"


def build_server(controller: TVController | None = None) -> Any:
    """Build the stdio MCP application. Does not connect or send anything."""
    if FastMCP is None:
        raise RuntimeError(
            "mcp SDK not installed — run 'pip install .' in companion/TVMCP first "
            f"(import error: {type(_MCP_IMPORT_ERROR).__name__}: {_MCP_IMPORT_ERROR})"
        )
    c = controller or TVController()
    @asynccontextmanager
    async def lifespan(server):
        try:
            yield {}
        finally:
            await c.disconnect()

    app = FastMCP(
        name="tv-remote",
        lifespan=lifespan,
        instructions=(
            "Windows laptop reference remote for Android TV Remote v2 (SPEC 7.3 H). "
            "Manual, bounded operations only: tv_pair_start -> read the 6-digit code on the TV -> "
            "tv_pair_finish -> tv_connect -> tv_key / tv_open_link / tv_open_app. "
            "Startup performs no network I/O. 'command_sent' means the command was queued to the "
            "TV, not that the TV acted on it. Laptop TV pairing is separate from the iPad and the "
            "Windows BLE/HID helper; nothing here may modify PC input."
        ),
    )

    @app.tool()
    async def tv_pair_start(host: str = "192.168.0.161") -> str:
        """Begin pairing with the TV at an explicit private numeric IP (no discovery, no hostnames). The TV must be showing its 6-digit pairing code; afterwards call tv_pair_finish with that code. Sends no remote-control commands."""
        return json.dumps(await c.pair_start(host), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_pair_finish(code: str) -> str:
        """Finish pairing using the 6-digit code the human read off the TV screen. The code must be entered by a person after the TV displays it; a session whose window expired is discarded, not finished with late input."""
        return json.dumps(await c.pair_finish(code), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_connect(host: str = "") -> str:
        """Reconnect to the saved TV using saved laptop credentials (same host, no new PIN). Verifies the live peer certificate against the pin captured at successful PIN pairing BEFORE accepting any command. Optional host argument must match the saved host."""
        return json.dumps(await c.connect(host if host else None), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_disconnect() -> str:
        """Disconnect the TV session and dispose transient PEM files."""
        return json.dumps(await c.disconnect(), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_status() -> str:
        """Local state only: stored pairing present, connected, pending pairing, and TV-observed device/power/current_app if connected. Never prints PINs, keys or private URLs."""
        return json.dumps(await c.status(), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_forget_pairing(confirm: bool = False) -> str:
        """Delete ONLY the laptop's saved TV pairing credentials. Requires confirm=true (explicit human confirmation). Never automatic, never touches iPad or Windows-helper credentials."""
        return json.dumps(await c.forget_pairing(confirm), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_key(name: str) -> str:
        """Send one allowlisted semantic key on the connected, pin-verified TV. Supported key names: up, down, left, right, ok, back, home, volumeup, volumedown, mute, playpause, stop, next, previous, rewind, forward, power. No arbitrary Android key codes, no destructive operations. Result reports what was SENT, not what the TV did."""
        return json.dumps(await c.send_key(name), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_open_link(target: str) -> str:
        """Send a launch command for a validated URI or bare Android package (e.g. 'lampa://top.rootu.lampa' or 'top.rootu.lampa'). Requires a connected, pin-verified session. Only owner-validated schemes are accepted; do not invent deeplinks. 'command_sent' is not proof the app opened or playback started."""
        return json.dumps(await c.open_link(target), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_open_app(item_id: str) -> str:
        """Send a launch command for a saved library item by id (see tv_save_item/tv_list_items). Requires a connected, pin-verified session."""
        return json.dumps(await c.open_app(item_id), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_save_item(kind: str = "app", title: str = "", target: str = "", item_id: str = "") -> str:
        """Add (or update, when item_id matches an existing item) a user-configured app/bookmark entry. kind: 'app' or 'bookmark'. title <=80 chars; target: bare Android package id or allowed-scheme URI (app: http/https/market/lampa; bookmark: http/https). Max 64 items, unique ids. Targets are stored encrypted and deliberately not echoed back."""
        return json.dumps(await c.save_item(kind, title, target, item_id), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_list_items() -> str:
        """List saved app/bookmark items: ids, titles, kinds and target scheme kinds only (private URLs are never repeated in results)."""
        return json.dumps(await c.list_items(), ensure_ascii=False, default=str)

    @app.tool()
    async def tv_delete_item(item_id: str) -> str:
        """Delete one saved app/bookmark item by id."""
        return json.dumps(await c.delete_item(item_id), ensure_ascii=False, default=str)

    return app
