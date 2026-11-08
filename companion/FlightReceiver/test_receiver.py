import hmac
import socket
import struct
import sys
import types
import unittest
from unittest.mock import patch

from receiver import Controller, State, ZERO, TIMEOUT, Xbox, decode, encode, private_bind

KEY = bytes(range(32))
SESSION = bytes(range(16))
PEER = ("192.168.1.12", 4444)


class ReceiverTests(unittest.TestCase):
    def setUp(self):
        self.outputs = []
        self.receiver = Controller(KEY, self.outputs.append)

    def send(self, state=ZERO, seq=1, now=0, session=SESSION, peer=PEER):
        return self.receiver.receive(encode(KEY, session, seq, state), peer, now)

    def test_wire_matches_swift_fixture(self):
        state = State(0xa5, -127, 127, -1, 1, 255, 128)
        packet = encode(KEY, SESSION, 0x0102030405060708, state)
        self.assertEqual(len(packet), 68)
        self.assertEqual(packet[:36].hex(),
                         "49475031000102030405060708090a0b0c0d0e0f"
                         "010203040506070800a5817fff01ff80")
        self.assertEqual(decode(packet, KEY), (SESSION, 0x0102030405060708, state))

    def test_wrong_key_tamper_and_bad_length_cannot_claim(self):
        valid = encode(KEY, SESSION, 1, ZERO)
        for packet in [valid[:-1], valid + b"x", valid[:30] + b"x" + valid[31:],
                       encode(b"x"*32, SESSION, 1, ZERO), b""]:
            self.assertFalse(self.receiver.receive(packet, PEER, 0))
        self.assertIsNone(self.receiver.owner)

    def test_authenticated_malformed_fields_rejected(self):
        for state, seq in [(State(buttons=256), 1), (State(lx=-128), 1), (ZERO, 0)]:
            self.assertIsNone(decode(encode(KEY, SESSION, seq, state), KEY))
        raw = bytearray(encode(KEY, SESSION, 1, ZERO)[:36])
        raw[:4] = b"BAD!"
        self.assertIsNone(decode(bytes(raw) + hmac.digest(KEY, raw, "sha256"), KEY))

    def test_initial_neutral_required(self):
        self.assertFalse(self.send(State(rt=255)))
        self.assertIsNone(self.receiver.owner)
        self.assertTrue(self.send())
        self.assertTrue(self.send(State(rt=255), 2))
        self.assertEqual(self.receiver.state.rt, 255)

    def test_simultaneous_fields_and_independent_release(self):
        self.send()
        held = State(255, -127, 127, 30, -40, 255, 255)
        self.assertTrue(self.send(held, 2, .01))
        released = State(254, -127, 127, 30, -40, 0, 255)
        self.assertTrue(self.send(released, 3, .02))
        self.assertEqual(self.outputs[-1], released)
        self.assertEqual(self.outputs[-1].rt, 255)

    def test_latest_sequence_wins_without_replay(self):
        self.send()
        self.send(State(lx=127), 5, .01)
        for seq in [1, 4, 5]:
            self.assertFalse(self.send(State(lx=-127), seq, .02))
        self.assertEqual(self.receiver.state.lx, 127)
        self.assertEqual(self.receiver.last_seen, .01)
        self.assertTrue(self.send(ZERO, 6, .03))

    def test_foreign_peer_or_session_cannot_take_active_controller(self):
        self.send()
        self.assertFalse(self.send(seq=2, peer=("192.168.1.13", 4444), now=.01))
        self.assertFalse(self.send(session=b"x"*16, now=.01))
        self.assertEqual(self.receiver.owner, (PEER, SESSION))

    def test_timeout_neutral_then_require_release_before_recovery(self):
        self.send()
        self.send(State(buttons=255, lx=127, rt=255), 2, .01)
        self.assertFalse(self.receiver.expire(.309))
        self.assertTrue(self.receiver.expire(.311))
        self.assertEqual(self.outputs[-1], ZERO)
        self.assertFalse(self.receiver.expire(2))
        self.assertFalse(self.send(State(rt=255), 3, 2))
        self.assertFalse(self.send(ZERO, 2, 2))
        self.assertTrue(self.send(ZERO, 4, 2))
        self.assertTrue(self.send(State(rt=255), 5, 2.01))

    def test_bad_packet_flood_does_not_prevent_watchdog(self):
        self.send()
        self.send(State(buttons=1), 2, .01)
        self.assertFalse(self.receiver.receive(b"bad", PEER, .4))
        self.assertEqual(self.receiver.state, ZERO)
        self.assertIsNone(self.receiver.last_seen)

    def test_new_session_takeover_retires_old_session(self):
        self.send()
        self.send(State(lx=127), 2, .01)
        # Non-neutral new session cannot mutate/retire old ownership.
        self.assertFalse(self.send(State(rt=255), 1, .4, b"x"*16))
        self.assertEqual(self.receiver.owner, (PEER, SESSION))
        self.assertTrue(self.send(ZERO, 1, .41, b"x"*16))
        self.assertFalse(self.send(ZERO, 99, .8))
        self.assertEqual(self.receiver.owner, (PEER, b"x"*16))

    def test_same_session_cannot_rebind_to_other_peer(self):
        self.send()
        self.assertFalse(self.send(seq=2, now=.4, peer=("192.168.1.13", 1234)))
        self.assertTrue(self.send(seq=2, now=.41))

    def test_shutdown_neutral(self):
        self.send()
        self.send(State(buttons=255, rt=255), 2, .01)
        self.receiver.close()
        self.assertEqual(self.outputs[-1], ZERO)

    def test_bind_is_explicit_private_only(self):
        for ip in ["10.0.0.1", "172.31.1.1", "192.168.1.1", "127.0.0.1"]:
            self.assertEqual(private_bind(ip), ip)
        for ip in ["0.0.0.0", "8.8.8.8", "::1", "192.0.2.1", "example.com"]:
            with self.assertRaises(Exception):
                private_bind(ip)

    def test_actual_udp_datagram_decodes_into_production_controller(self):
        # Real kernel UDP transport, authentic production receiver/state path.
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            server.bind(("127.0.0.1", 0))
            server.settimeout(1)
            for seq, state in [(1, ZERO), (2, State(buttons=0x33, lx=-127, ly=127, rt=255)),
                               (3, ZERO)]:
                client.sendto(encode(KEY, SESSION, seq, state), server.getsockname())
                packet, peer = server.recvfrom(1024)
                self.assertTrue(self.receiver.receive(packet, peer, seq * .01))
                self.assertEqual(self.outputs[-1], state)

    def test_real_udp_timeout_nonzero_then_explicit_fresh_session_rearm(self):
        held = State(buttons=255, lx=127, ly=-127, rx=50, ry=-50, lt=255, rt=255)
        fresh = b"r" * 16
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as server, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client, \
             socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as rearmed_client:
            server.bind(("127.0.0.1", 0))
            server.settimeout(1)

            def datagram(session, seq, state, now):
                source = rearmed_client if session == fresh else client
                source.sendto(encode(KEY, session, seq, state), server.getsockname())
                packet, peer = server.recvfrom(1024)
                return self.receiver.receive(packet, peer, now)

            self.assertTrue(datagram(SESSION, 1, ZERO, 0))
            self.assertTrue(datagram(SESSION, 2, held, .02))
            self.assertTrue(self.receiver.expire(.321))
            # Restored Wi-Fi continuously streams deflected gyro and held buttons:
            # no accidental replay, but old sender cannot recover by itself.
            for seq in range(3, 33):
                self.assertFalse(datagram(SESSION, seq, held, .4 + seq * .02))
                self.assertEqual(self.receiver.state, ZERO)
            # Explicit UI re-arm discards old sources and starts a new session.
            self.assertTrue(datagram(fresh, 1, ZERO, 1.1))
            self.assertEqual(self.receiver.state, ZERO)
            for seq in range(2, 31):
                self.assertTrue(datagram(fresh, seq, ZERO, 1.1 + seq * .02))
            self.assertFalse(datagram(SESSION, 999, held, 1.72))
            self.assertFalse(datagram(SESSION, 1000, ZERO, 1.73))
            self.assertTrue(datagram(fresh, 31, State(buttons=4, lx=-80, rt=255), 1.74))
            self.assertEqual(self.outputs[-1], State(buttons=4, lx=-80, rt=255))
            # Replayed retired owner is still rejected after the next timeout.
            self.receiver.expire(2.1)
            self.assertFalse(datagram(SESSION, 1001, ZERO, 2.11))
            self.assertEqual(self.receiver.state, ZERO)

    def test_rearm_neutral_interval_can_replace_still_active_owner(self):
        self.send()
        self.send(State(lx=127, buttons=1), 2, .02)
        fresh = b"r" * 16
        accepted = []
        for frame in range(30):
            accepted.append(self.send(ZERO, frame + 1, .04 + frame * .02, fresh))
        self.assertFalse(accepted[0])
        self.assertTrue(accepted[-1])
        self.assertEqual(self.receiver.owner, (PEER, fresh))
        self.assertTrue(self.send(State(lx=-127), 31, .64, fresh))
        self.assertFalse(self.send(ZERO, 999, 1.0))

    def test_xinput_backend_all_fields_and_button_order(self):
        calls = []
        class Pad:
            def __getattr__(self, name):
                return lambda **kwargs: calls.append((name, kwargs))
        names = ["A", "B", "X", "Y", "LEFT_SHOULDER", "RIGHT_SHOULDER", "BACK", "START"]
        buttons = types.SimpleNamespace(**{"XUSB_GAMEPAD_" + n: n for n in names})
        fake = types.SimpleNamespace(VX360Gamepad=Pad, XUSB_BUTTON=buttons)
        with patch.dict(sys.modules, {"vgamepad": fake}):
            backend = Xbox()
            self.assertEqual(calls, [
                ("left_joystick_float", {"x_value_float": 1 / 32767, "y_value_float": 0}),
                ("update", {}), ("reset", {}), ("update", {})])
            calls.clear()
            backend(State(255, -127, 127, 127, -127, 255, 128))
            self.assertEqual([kwargs["button"] for name, kwargs in calls
                              if name == "press_button"], names)
            self.assertIn(("left_joystick_float", {"x_value_float": -1, "y_value_float": 1}), calls)
            self.assertIn(("right_joystick_float", {"x_value_float": 1, "y_value_float": -1}), calls)
            self.assertIn(("left_trigger", {"value": 255}), calls)
            self.assertIn(("right_trigger", {"value": 128}), calls)
            self.assertEqual(calls[-1], ("update", {}))
            calls.clear()
            backend(ZERO)
            self.assertEqual(calls[0], ("reset", {}))
            self.assertFalse(any(name == "press_button" for name, _ in calls))


if __name__ == "__main__":
    unittest.main()
