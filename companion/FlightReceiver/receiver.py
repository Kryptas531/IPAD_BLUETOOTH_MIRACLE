"""Authenticated LAN controller -> virtual Xbox 360. SPEC §13, Python 3.10+."""
from __future__ import annotations

import argparse
import hmac
import ipaddress
import secrets
import socket
import struct
import time
from dataclasses import dataclass
from pathlib import Path

WIRE = struct.Struct("!4s16sQHbbbbBB")
TIMEOUT = 0.300
PORT = 26761


@dataclass(frozen=True)
class State:
    buttons: int = 0
    lx: int = 0
    ly: int = 0
    rx: int = 0
    ry: int = 0
    lt: int = 0
    rt: int = 0


ZERO = State()


def encode(key: bytes, session: bytes, sequence: int, state: State) -> bytes:
    """Reference encoder for tests/interoperability; iPad has its own Swift encoder."""
    body = WIRE.pack(b"IGP1", session, sequence, state.buttons, state.lx, state.ly,
                     state.rx, state.ry, state.lt, state.rt)
    return body + hmac.digest(key, body, "sha256")


def decode(packet: bytes, key: bytes):
    if len(packet) != WIRE.size + 32:
        return None
    body, signature = packet[:-32], packet[-32:]
    if not hmac.compare_digest(hmac.digest(key, body, "sha256"), signature):
        return None
    magic, session, seq, buttons, lx, ly, rx, ry, lt, rt = WIRE.unpack(body)
    if magic != b"IGP1" or not seq or buttons & ~0xff or -128 in (lx, ly, rx, ry):
        return None
    return session, seq, State(buttons, lx, ly, rx, ry, lt, rt)


class Controller:
    """Single authenticated peer, monotonic state, injected backend and monotonic clock."""

    def __init__(self, key: bytes, output):
        if len(key) != 32:
            raise ValueError("Pairing key must be 32 bytes")
        self.key, self.output = key, output
        self.owner = None
        self.sequence = 0
        self.last_seen = None
        self.retired = set()
        self.state = ZERO
        self.needs_neutral = True
        self.output(ZERO)

    def expire(self, now: float):
        if self.last_seen is not None and now - self.last_seen >= TIMEOUT:
            self.output(ZERO)
            self.state = ZERO
            # Keep ownership/sequence across timeout: same-session recovery can only
            # advance sequence; a new session may replace it after the timeout.
            self.last_seen = None
            self.needs_neutral = True
            return True
        return False

    def receive(self, packet: bytes, peer, now: float) -> bool:
        self.expire(now)
        parsed = decode(packet, self.key)
        if parsed is None:
            return False
        session, sequence, state = parsed
        identity = (peer, session)
        if session in self.retired:
            return False
        if self.owner != identity:
            if self.last_seen is not None:
                return False
            # A session belongs to its original source even after link silence.
            if self.owner is not None and session == self.owner[1]:
                return False
            # Bound memory without evicting replay protection. Restart/re-key to
            # admit >256 sessions in one receiver lifetime.
            if len(self.retired) >= 256:
                return False
            # Authenticate and validate the neutral handshake BEFORE changing ownership.
            if state != ZERO:
                return False
            if self.owner is not None:
                self.retired.add(self.owner[1])
            self.owner, self.sequence = identity, 0
            self.needs_neutral = True
        if sequence <= self.sequence:
            return False
        if self.needs_neutral and state != ZERO:
            return False
        self.needs_neutral = False
        self.sequence, self.last_seen, self.state = sequence, now, state
        self.output(state)
        return True

    def close(self):
        self.output(ZERO)
        self.state = ZERO
        self.last_seen = None


class Xbox:
    """Actual vgamepad API, imported only for Windows execution, never needed by tests."""

    def __init__(self):
        import vgamepad as vg
        self.vg = vg
        self.pad = vg.VX360Gamepad()
        # ViGEmBus starts with a captured USB report containing nonzero sticks,
        # but its comparison cache starts at zero: an initial zero is discarded.
        # Prime a one-count axis change (no buttons), then publish true neutral.
        # This is 1/32767 of travel, below the standard XInput stick deadzones.
        # Device creation returns before Windows has posted USB interrupt reads.
        # Settle only at startup, never in the controller's normal output path.
        time.sleep(0.5)
        self.pad.left_joystick_float(x_value_float=1 / 32767, y_value_float=0)
        self.pad.update()
        time.sleep(0.02)
        self.pad.reset()
        self.pad.update()
        self.bits = [
            vg.XUSB_BUTTON.XUSB_GAMEPAD_A, vg.XUSB_BUTTON.XUSB_GAMEPAD_B,
            vg.XUSB_BUTTON.XUSB_GAMEPAD_X, vg.XUSB_BUTTON.XUSB_GAMEPAD_Y,
            vg.XUSB_BUTTON.XUSB_GAMEPAD_LEFT_SHOULDER,
            vg.XUSB_BUTTON.XUSB_GAMEPAD_RIGHT_SHOULDER,
            vg.XUSB_BUTTON.XUSB_GAMEPAD_BACK, vg.XUSB_BUTTON.XUSB_GAMEPAD_START,
        ]

    def __call__(self, state: State):
        self.pad.reset()
        for i, button in enumerate(self.bits):
            if state.buttons & (1 << i):
                self.pad.press_button(button=button)
        # Native XInput Y is positive UP; Swift sends flight pitch in that convention.
        self.pad.left_joystick_float(x_value_float=state.lx / 127,
                                     y_value_float=state.ly / 127)
        self.pad.right_joystick_float(x_value_float=state.rx / 127,
                                      y_value_float=state.ry / 127)
        self.pad.left_trigger(value=state.lt)
        self.pad.right_trigger(value=state.rt)
        self.pad.update()


def private_bind(text: str) -> str:
    try:
        address = ipaddress.IPv4Address(text)
    except ipaddress.AddressValueError as exc:
        raise argparse.ArgumentTypeError("Use the Windows LAN IPv4") from exc
    if not any(address in net for net in (
        ipaddress.IPv4Network("10.0.0.0/8"), ipaddress.IPv4Network("172.16.0.0/12"),
        ipaddress.IPv4Network("192.168.0.0/16"), ipaddress.IPv4Network("127.0.0.0/8")
    )):
        raise argparse.ArgumentTypeError("Bind only a LAN/loopback IPv4, never 0.0.0.0")
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", type=private_bind, required=True)
    parser.add_argument("--key-file", type=Path, required=True,
                        help="Local file containing exactly 64 hex digits; never printed")
    parser.add_argument("--create-key", action="store_true",
                        help="Create a new key file, refusing to overwrite existing keys")
    parser.add_argument("--dry-run", action="store_true",
                        help="Validate receiver without a driver; does NOT create a gamepad")
    args = parser.parse_args()
    if args.create_key:
        with args.key_file.open("x") as out:
            out.write(secrets.token_hex(32) + "\n")
        print("Created pairing key file; enter its contents in iPad FLIGHT Settings.")
    try:
        key = bytes.fromhex(args.key_file.read_text().strip())
        if len(key) != 32:
            raise ValueError()
    except (OSError, ValueError):
        parser.error("Key file must contain 64 hex digits")
    backend = (lambda state: None) if args.dry_run else Xbox()
    controller = Controller(key, backend)
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.bind((args.bind, PORT))
        sock.settimeout(0.05)
        print(f"FLIGHT listening on {args.bind}:{PORT}; "
              + ("DRY RUN (no virtual controller)" if args.dry_run else "virtual Xbox 360"))
        try:
            while True:
                try:
                    packet, peer = sock.recvfrom(1024)
                    controller.receive(packet, peer, time.monotonic())
                except socket.timeout:
                    pass
                controller.expire(time.monotonic())
        except KeyboardInterrupt:
            pass
        finally:
            controller.close()


if __name__ == "__main__":
    main()
