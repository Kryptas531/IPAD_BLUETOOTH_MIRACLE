"""Entry points for the TV laptop reference (SPEC 52d93f1 section 7.3 H).

Default command (``python -m tv_mcp`` / ``tv-mcp``) runs the stdio MCP
server; startup performs NO network connection, pairing or command.

Interactive CLI commands mirror the MCP tools; the TV pairing code is always
entered by a human at a prompt (never passed on the command line) and the
human is given up to the remaining PIN window. One-shot ``connect``/``key``/
``open-link``/``open-app`` commands establish a bounded, cert-pin-verified
connection from saved credentials first (never a new pairing); a failed
connect is reported and no command is sent.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import sys

from .controller import TVController


def _out(payload: object) -> None:
    print(json.dumps(payload, ensure_ascii=False, default=str), flush=True)


def _rc(res: dict) -> int:
    return 0 if res.get("ok") else 1


async def _read_pin(seconds: float) -> str:
    # A cancelled to_thread(input/getpass) leaves a blocked executor and prevents
    # asyncio.run from exiting. Poll the Windows console without echo instead.
    if os.name != "nt" or not sys.stdin.isatty():
        raise EOFError("Interactive Windows terminal required for PIN entry")
    import msvcrt
    print("Enter the 6-digit code shown on the TV: ", end="", flush=True)
    deadline = asyncio.get_running_loop().time() + seconds
    code = ""
    while asyncio.get_running_loop().time() < deadline:
        if msvcrt.kbhit():
            char = msvcrt.getwch()
            if char in ("\x03", "\x1a"):
                raise EOFError("PIN entry cancelled")
            if char in ("\r", "\n"):
                print()
                return code
            if char == "\b":
                code = code[:-1]
            elif char in "0123456789abcdefABCDEF" and len(code) < 6:
                code += char
        await asyncio.sleep(0.05)
    raise asyncio.TimeoutError()


async def _cmd_pair(args: argparse.Namespace) -> int:
    c = TVController()
    res = await c.pair_start(args.host)
    _out(res)
    if not res.get("ok"):
        return 1
    try:
        code = await _read_pin(c.pin_wait_timeout)
    except (asyncio.TimeoutError, EOFError):
        # Stale callback: discard the pending pairing instead of finishing it.
        await c.disconnect()
        _out({
            "ok": False,
            "stage": "pair_finish",
            "error": "no pairing code entered within the pairing window; session discarded; saved credentials unchanged",
        })
        return 1
    res = await c.pair_finish(code.strip())
    _out(res)
    if not res.get("ok"):
        return 1
    # Same flow the reference proved on real hardware: after pairing,
    # reconnect with the saved credentials and report observed state.
    res = await c.connect()
    _out(res)
    if not res.get("ok"):
        return 1
    _out(await c.status())
    return 0


async def _cmd_connect(args: argparse.Namespace) -> int:
    return _rc(await TVController().connect(args.host if args.host else None))


async def _cmd_status(args: argparse.Namespace) -> int:
    return _rc(await TVController().status())


async def _cmd_key(args: argparse.Namespace) -> int:
    c = TVController()
    conn = await c.connect()
    _out(conn)
    if not conn.get("ok"):
        return 1
    return _rc(await c.send_key(args.name))


async def _cmd_open_link(args: argparse.Namespace) -> int:
    c = TVController()
    conn = await c.connect()
    _out(conn)
    if not conn.get("ok"):
        return 1
    return _rc(await c.open_link(args.target))


async def _cmd_open_app(args: argparse.Namespace) -> int:
    c = TVController()
    conn = await c.connect()
    _out(conn)
    if not conn.get("ok"):
        return 1
    return _rc(await c.open_app(args.item_id))


async def _cmd_save_item(args: argparse.Namespace) -> int:
    return _rc(await TVController().save_item(args.kind, args.title, args.target, args.id))


async def _cmd_list_items(args: argparse.Namespace) -> int:
    return _rc(await TVController().list_items())


async def _cmd_delete_item(args: argparse.Namespace) -> int:
    return _rc(await TVController().delete_item(args.item_id))


async def _cmd_disconnect(args: argparse.Namespace) -> int:
    return _rc(await TVController().disconnect())


async def _cmd_forget(args: argparse.Namespace) -> int:
    return _rc(await TVController().forget_pairing(args.yes))


def _cmd_serve(args: argparse.Namespace) -> int:
    try:
        from .server import build_server
    except Exception as exc:
        _out({"ok": False, "stage": "deps", "error": f"{type(exc).__name__}: {exc}"})
        return 1
    try:
        build_server().run()
    except KeyboardInterrupt:
        return 130
    except Exception as exc:
        _out({"ok": False, "stage": "serve", "error": f"{type(exc).__name__}: {exc}"})
        return 1
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        prog="tv-mcp",
        description=(
            "Windows laptop reference remote + local stdio MCP server for "
            "Android TV Remote v2 (SPEC 52d93f1 7.3 H). Default: serve "
            "(no automatic TV traffic; PC/BLE input untouched)."
        ),
    )
    sub = parser.add_subparsers(dest="cmd")
    sub.add_parser("serve", help="run the stdio MCP server (default; never connects automatically)")
    p = sub.add_parser("pair", help="pair with the TV; enter the 6-digit code at the prompt when the TV shows it")
    p.add_argument("--host", default="192.168.0.161")
    p = sub.add_parser("connect", help="reconnect to the saved TV using saved credentials (no new PIN)")
    p.add_argument("--host", default="")
    sub.add_parser("status", help="report local stage/observed state without sending anything")
    sub.add_parser("disconnect", help="disconnect and dispose transient PEM files")
    p = sub.add_parser("key", help="send an allowlisted key (connects from saved credentials first)")
    p.add_argument("name")
    p = sub.add_parser("open-link", help="launch a validated URI/package (connects from saved credentials first)")
    p.add_argument("target")
    p = sub.add_parser("open-app", help="launch a saved library item by id (connects from saved credentials first)")
    p.add_argument("item_id")
    p = sub.add_parser("save-item", help="add/update a local app/bookmark entry")
    p.add_argument("--kind", default="app")
    p.add_argument("--title", default="")
    p.add_argument("--target", default="")
    p.add_argument("--id", default="")
    p = sub.add_parser("delete-item", help="delete a local library item by id")
    p.add_argument("item_id")
    p = sub.add_parser("forget", help="explicitly delete the laptop's saved TV pairing credentials")
    p.add_argument("--yes", action="store_true")
    args = parser.parse_args()

    handlers = {
        "serve": _cmd_serve,
        "pair": _cmd_pair,
        "connect": _cmd_connect,
        "status": _cmd_status,
        "disconnect": _cmd_disconnect,
        "key": _cmd_key,
        "open-link": _cmd_open_link,
        "open-app": _cmd_open_app,
        "save-item": _cmd_save_item,
        "list-items": _cmd_list_items,
        "delete-item": _cmd_delete_item,
        "forget": _cmd_forget,
    }
    cmd = args.cmd if args.cmd in handlers else "serve"
    try:
        if cmd == "serve":
            return _cmd_serve(args)
        return asyncio.run(handlers[cmd](args))
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main())
