"""Dependency-free tests for the TV MCP laptop reference (SPEC 7.3 H).

Stdlib + fakes only: androidtvremote2 and mcp are NOT required (the
controller's store and remote class are injected; lazy imports stay
unresolved). These tests verify behavior, not code shape: wrong/changed PIN,
timeouts, no-command-before-connect, stale pairing discard, corrupt-vault
preservation, URL validation, library CRUD bounds, encrypted-at-rest
storage, and MCP tool registration.

Run from companion/TVMCP with the venv python:
    python -m unittest discover -s tests -t .
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import shutil
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

from tv_mcp import library
from tv_mcp.controller import KEY_CODES, TVController
from tv_mcp.store import CredentialStore, StoreCorruptError, StoreError

try:
    from tv_mcp import server as tv_server
    HAS_SERVER = tv_server.FastMCP is not None
except Exception:
    tv_server = None
    HAS_SERVER = False

FAKE_CERT_PEM = "FAKE-CERT-PEM"
FAKE_KEY_PEM = "FAKE-KEY-PEM"
FAKE_DER = b"FAKE-TV-CERT-DER"


class _FakeSSL:
    def __init__(self, der: bytes) -> None:
        self._der = der

    def getpeercert(self, binary_form: bool = False) -> bytes:
        return self._der


class _FakeTransport:
    def __init__(self, der: bytes) -> None:
        self.ssl = _FakeSSL(der)

    def get_extra_info(self, name: str, default=None):
        return self.ssl if name == "ssl_object" else default

    def is_closing(self) -> bool:
        return False


class FakeRemote:
    """Mimics the actual androidtvremote2.AndroidTVRemote API surface the
    controller uses (verified against the pinned reference source)."""

    instances: list = []

    def __init__(self, client_name: str, certfile: str, keyfile: str, host: str) -> None:
        self.calls: list[tuple] = []
        self.client_name = client_name
        self.host = host
        self.certfile = certfile
        self.keyfile = keyfile
        self.fail_generate = False
        self.fail_start = False
        self.finish_raises: BaseException | None = None
        self.finish_sleep = 0.0
        self.next_peer_der: bytes | None = None
        self._pairing_message_protocol = None
        self._remote_message_protocol = None
        self._transport = None
        FakeRemote.instances.append(self)

    async def async_generate_cert_if_missing(self) -> bool:
        self.calls.append(("generate_cert",))
        if self.fail_generate:
            raise RuntimeError("simulated missing crypto backend")
        Path(self.certfile).write_text(FAKE_CERT_PEM, encoding="ascii")
        Path(self.keyfile).write_text(FAKE_KEY_PEM, encoding="ascii")
        return True

    async def async_start_pairing(self) -> None:
        self.calls.append(("start_pairing",))
        if self.fail_start:
            raise OSError("simulated: no route to TV")
        self._pairing_message_protocol = SimpleNamespace(transport=_FakeTransport(FAKE_DER))

    async def async_finish_pairing(self, code: str) -> None:
        self.calls.append(("finish_pairing", code))
        if self.finish_sleep:
            await asyncio.sleep(self.finish_sleep)
        if self.finish_raises is not None:
            raise self.finish_raises
        # The pinned reference disconnects its pairing transport after secret_ack.
        self.disconnect()

    async def async_connect(self) -> None:
        self.calls.append(("connect",))
        self._transport = _FakeTransport(self.next_peer_der or FAKE_DER)
        self._remote_message_protocol = SimpleNamespace(
            _active_features=615,
            device_info={"manufacturer": "TCL", "model": "SmartTVPro", "sw_version": "7.00.956317615"},
            is_on=True,
            current_app="",
        )

    def send_key_command(self, key_code, direction="SHORT") -> None:
        self.calls.append(("key", key_code, direction))

    def send_launch_app_command(self, app_link: str) -> None:
        self.calls.append(("launch", app_link))

    def disconnect(self) -> None:
        self.calls.append(("disconnect",))


class FakeRemoteCls:
    """Factory handing the controller one preconfigured fake client class."""

    def __init__(self, **flags) -> None:
        self.flags = flags
        self.created: list[FakeRemote] = []

    def __call__(self, client_name: str, certfile: str, keyfile: str, host: str) -> FakeRemote:
        r = FakeRemote(client_name, certfile, keyfile, host)
        for k, v in self.flags.items():
            setattr(r, k, v)
        self.created.append(r)
        return r


class LibraryModelTests(unittest.TestCase):
    """§7.3G/H model bounds (mirrors the Swift TVLibrary.swift tests)."""

    def test_bare_package_converts_to_market_link(self):
        self.assertEqual(
            library.app_launch_target("top.rootu.lampa"),
            "market://launch?id=top.rootu.lampa",
        )

    def test_owner_validated_lampa_link_validates_for_apps(self):
        library.validate_target("app", "lampa://top.rootu.lampa")  # must not raise

    def test_bare_package_target_validates_for_apps(self):
        library.validate_target("app", "top.rootu.lampa")  # must not raise

    def test_bare_target_requires_package_shape(self):
        with self.assertRaises(library.ValidationError):
            library.validate_target("app", "top")
        with self.assertRaises(library.ValidationError):
            library.validate_target("app", "not.a-valid$package")

    def test_bookmark_requires_full_http_url(self):
        with self.assertRaises(library.ValidationError):
            library.validate_target("bookmark", "top.rootu.lampa")
        with self.assertRaises(library.ValidationError):
            library.validate_target("bookmark", "lampa://top.rootu.lampa")
        library.validate_target("bookmark", "https://example.com/x")  # must not raise

    def test_invented_or_dangerous_schemes_rejected(self):
        for target in ("javascript:alert(1)", "data:text/html,x", "file:///c:/x",
                       "intent:#Intent", "mailto:a@b.c", "tel:123", "sms:123",
                       "blob:x", "vbscript:x"):
            with self.assertRaises(library.ValidationError, msg=target):
                library.validate_target("app", target)

    def test_target_limits_and_control_chars(self):
        with self.assertRaises(library.ValidationError):
            library.validate_target("app", "https://example.com/" + "x" * 8200)
        with self.assertRaises(library.ValidationError):
            library.validate_target("app", "https://example.com/\x00evil")
        with self.assertRaises(library.ValidationError):
            library.validate_title("x" * 81)
        with self.assertRaises(library.ValidationError):
            library.validate_title("")

    def test_empty_target_rejected(self):
        with self.assertRaises(library.ValidationError):
            library.validate_target("app", "")

    def test_duplicate_ids_invalid(self):
        lib = library.TVLibrary()
        lib.items.append(library.TVItem(id="id1", kind="app", title="T", target="https://example.com/x"))
        with self.assertRaises(library.ValidationError):
            lib.validate_new("app", "T2", "https://example.com/y", "id1")

    def test_max_items_enforced(self):
        lib = library.TVLibrary()
        for i in range(64):
            lib.items.append(library.TVItem(id=f"id{i}", kind="app", title=f"t{i}", target="https://example.com/f"))
        with self.assertRaises(library.ValidationError):
            lib.validate_new("app", "too many", "https://example.com/z", "")

    def test_library_serialization_roundtrip(self):
        lib = library.TVLibrary(items=[library.TVItem(id="a", kind="app", title="Lampa", target="lampa://top.rootu.lampa")], recent_ids=["a"])
        restored = library.TVLibrary.from_dict(json.loads(json.dumps(lib.to_dict())))
        self.assertEqual(restored.items[0].target, "lampa://top.rootu.lampa")
        self.assertEqual(restored.recent_ids, ["a"])
        self.assertEqual(restored.schema, library.SCHEMA_VERSION)


@unittest.skipIf(os.name != "nt", "DPAPI storage requires Windows")
class StoreTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="tvmcp-test-"))
        self.store = CredentialStore(base_dir=self.base)

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def test_credentials_roundtrip_encrypted_at_rest(self):
        self.store.save_credentials({"host": "192.168.0.161", "pin": "deadbeef", "cert": FAKE_CERT_PEM})
        raw = (self.base / "tv-credentials.bin").read_bytes()
        self.assertNotIn(FAKE_CERT_PEM.encode(), raw)  # never plaintext at rest
        data = self.store.load_credentials()
        self.assertEqual(data["host"], "192.168.0.161")
        self.assertEqual(data["cert"], FAKE_CERT_PEM)

    def test_load_when_nothing_stored_returns_none(self):
        self.assertIsNone(self.store.load_credentials())
        self.assertIsNone(self.store.load_library())

    def test_corrupt_read_never_overwrites(self):
        path = self.base / "tv-credentials.bin"
        path.write_bytes(b"garbage-not-dpapi")
        with self.assertRaises(StoreCorruptError):
            self.store.load_credentials()
        self.assertEqual(path.read_bytes(), b"garbage-not-dpapi")  # preserved untouched

    def test_library_target_not_plaintext(self):
        self.store.save_library({
            "schema": 1,
            "items": [{"id": "1", "kind": "app", "title": "Lampa", "target": "lampa://top.rootu.lampa"}],
            "recent_ids": [],
        })
        raw = (self.base / "tv-library.bin").read_bytes()
        self.assertNotIn(b"top.rootu.lampa", raw)
        data = self.store.load_library()
        self.assertEqual(data["items"][0]["target"], "lampa://top.rootu.lampa")


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="tvmcp-ctl-"))
        self.store = CredentialStore(base_dir=self.base)

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def _controller(self, remote_cls=None, **timeouts):
        return TVController(
            store=self.store,
            remote_cls=remote_cls if remote_cls is not None else FakeRemoteCls(),
            **timeouts,
        )

    def test_startup_constructs_and_status_without_any_network(self):
        FakeRemote.instances = []
        c = self._controller()
        self.assertEqual(FakeRemote.instances, [])  # construction touched nothing
        res = asyncio.run(c.status())
        self.assertTrue(res["ok"])
        self.assertFalse(res["has_stored_pairing"])
        self.assertFalse(res["connected"])
        self.assertEqual(FakeRemote.instances, [])  # status also sent nothing

    def test_pair_finish_without_start_is_discarded(self):
        c = self._controller()
        res = asyncio.run(c.pair_finish("ABCDEF"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        self.assertIsNone(self.store.load_credentials())

    def test_pair_start_requires_numeric_private_host(self):
        c = self._controller()
        for bad in ("tv.local", "8.8.8.8", ""):
            res = asyncio.run(c.pair_start(bad))
            self.assertFalse(res["ok"], bad)
            self.assertEqual(res["stage"], "validate")

    def test_pair_flow_saves_envelope_then_connect_needs_no_new_pin(self):
        FakeRemote.instances = []
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        res = asyncio.run(c.pair_start("192.168.0.161"))
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["stage"], "pair_start")
        res = asyncio.run(c.pair_finish("ABCDEF"))  # 6 hex digits, human-entered form
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["stage"], "pair_confirmed")
        creds = self.store.load_credentials()
        self.assertIsNotNone(creds)
        self.assertEqual(creds["host"], "192.168.0.161")
        self.assertEqual(creds["pin"], hashlib.sha256(FAKE_DER).hexdigest())
        self.assertEqual(creds["cert"], FAKE_CERT_PEM)
        self.assertEqual(creds["key"], FAKE_KEY_PEM)
        # transient PEMs cleaned up; nothing plaintext left in work dir
        self.assertEqual(FakeRemote.instances[0].calls,
                         [("generate_cert",), ("start_pairing",), ("finish_pairing", "ABCDEF"), ("disconnect",)])
        # second pair_start must not silently re-pair over saved credentials
        res = asyncio.run(c.pair_start("192.168.0.161"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        # reconnect uses saved credentials, no new PIN, reports observed state
        res = asyncio.run(c.connect())
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["stage"], "connected")
        self.assertEqual(res["features"], 615)
        self.assertEqual(res["power"], True)
        self.assertEqual(res["device"]["model"], "SmartTVPro")
        self.assertEqual(res["host"], "192.168.0.161")

    def test_invalid_code_format_rejected_before_finish(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        res = asyncio.run(c.pair_finish("12345"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        self.assertNotIn(("finish_pairing", "12345"), factory.created[0].calls)
        self.assertIsNone(self.store.load_credentials())

    def test_timeout_during_finish_saves_nothing(self):
        factory = FakeRemoteCls(finish_sleep=1.0)
        c = self._controller(remote_cls=factory, finish_timeout=0.05)
        asyncio.run(c.pair_start("192.168.0.161"))
        res = asyncio.run(c.pair_finish("ABCDEF"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "pair_finish")
        self.assertIsNone(self.store.load_credentials())
        self.assertIn(("disconnect",), factory.created[0].calls)  # connection disposed on error

    def test_stale_pairing_window_discards_session(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory, pin_wait_timeout=0.0)
        asyncio.run(c.pair_start("192.168.0.161"))
        res = asyncio.run(c.pair_finish("ABCDEF"))  # late human input after expiry
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "pair_finish")
        self.assertIn("expired", res["error"])
        self.assertIsNone(self.store.load_credentials())
        self.assertIn(("disconnect",), factory.created[0].calls)
        # and a second stale finish with no pending session is also discarded
        res = asyncio.run(c.pair_finish("ABCDEF"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")

    def test_no_command_before_connect(self):
        FakeRemote.instances = []
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        res = asyncio.run(c.send_key("ok"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "connect")
        res = asyncio.run(c.open_link("lampa://top.rootu.lampa"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "connect")
        self.assertEqual(FakeRemote.instances, [])  # not even a client was created

    def test_unknown_key_name_rejected_without_echo_or_send(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        asyncio.run(c.connect())
        res = asyncio.run(c.send_key("KEYCODE_DELETE"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        self.assertNotIn("DELETE", json.dumps(res))  # no user-input echo
        self.assertNotIn(("key", "KEYCODE_DELETE", "SHORT"), factory.created[-1].calls)

    def test_cert_pin_mismatch_rejects_commands_and_keeps_credentials(self):
        factory = FakeRemoteCls(next_peer_der=b"CHANGED-CERT-DER")
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        res = asyncio.run(c.connect())
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "cert_pin")
        self.assertIn(("disconnect",), factory.created[-1].calls)  # mismatched connection dropped
        res = asyncio.run(c.send_key("ok"))
        self.assertFalse(res["ok"])  # no commands after a rejected pin
        self.assertIsNotNone(self.store.load_credentials())  # kept, never auto-forgotten

    def test_connect_rejects_host_mismatch(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        res = asyncio.run(c.connect("10.0.0.5"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")

    def test_connect_timeout_disposes_transport_and_transient_keys(self):
        class TimeoutRemote(FakeRemote):
            async def async_connect(self):
                await super().async_connect()
                raise asyncio.TimeoutError()
        c = self._controller(remote_cls=TimeoutRemote)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        saved = self.store.credentials_path.read_bytes()
        result = asyncio.run(c.connect())
        self.assertFalse(result["ok"])
        self.assertEqual(result["waiting_for"], "remote_activation_or_start")
        self.assertIn(("disconnect",), FakeRemote.instances[-1].calls)
        self.assertIsNone(c._work_dir)
        self.assertEqual(self.store.credentials_path.read_bytes(), saved)

    def test_pairing_persistence_failure_removes_transient_keys(self):
        class FailingStore(CredentialStore):
            def save_credentials(self, data):
                raise OSError("synthetic storage failure")
        c = TVController(store=FailingStore(base_dir=self.base), remote_cls=FakeRemoteCls())
        self.assertTrue(asyncio.run(c.pair_start("192.168.0.161"))["ok"])
        result = asyncio.run(c.pair_finish("ABCDEF"))
        self.assertFalse(result["ok"])
        self.assertEqual(result["stage"], "storage")
        self.assertIsNone(c._work_dir)
        self.assertEqual(list(self.base.glob("pem-*")), [])

    def test_corrupt_vault_surfaces_and_is_preserved(self):
        path = self.base / "tv-credentials.bin"
        self.base.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"garbage-not-dpapi")
        c = self._controller()
        res = asyncio.run(c.connect())
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "vault")
        self.assertEqual(path.read_bytes(), b"garbage-not-dpapi")

    def test_key_launch_and_bookmark_flow_after_connect(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        asyncio.run(c.connect())
        res = asyncio.run(c.send_key("ok"))
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["stage"], "command_sent")
        self.assertEqual(res["key"], "ok")
        res = asyncio.run(c.open_link("lampa://top.rootu.lampa"))
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["target_kind"], "uri:lampa")
        res = asyncio.run(c.save_item("app", "Lampa", "lampa://top.rootu.lampa"))
        self.assertTrue(res["ok"], res)
        item_id = res["item"]["id"]
        res = asyncio.run(c.open_app(item_id))
        self.assertTrue(res["ok"], res)
        calls = factory.created[-1].calls
        self.assertIn(("key", "KEYCODE_DPAD_CENTER", "SHORT"), calls)
        self.assertIn(("launch", "lampa://top.rootu.lampa"), calls)

    def test_open_link_rejects_unvalidated_schemes(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        asyncio.run(c.connect())
        res = asyncio.run(c.open_link("javascript:alert(1)"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        self.assertNotIn("alert", json.dumps(res))  # no private/injected content echoed
        self.assertNotIn(("launch", "javascript:alert(1)"), factory.created[-1].calls)

    def test_library_crud_roundtrip_and_encrypted_at_rest(self):
        c = self._controller()
        res = asyncio.run(c.save_item("app", "Lampa", "lampa://top.rootu.lampa"))
        self.assertTrue(res["ok"], res)
        item_id = res["item"]["id"]
        res = asyncio.run(c.list_items())
        self.assertEqual(len(res["items"]), 1)
        self.assertEqual(res["items"][0]["target_kind"], "uri:lampa")
        res = asyncio.run(c.save_item("app", "Some TV app", "com.example.app"))
        self.assertTrue(res["ok"], res)
        self.assertEqual(res["item"]["id"] != item_id, True)
        # bookmarks cannot hold bare packages or non-http schemes
        res = asyncio.run(c.save_item("bookmark", "bad", "lampa://top.rootu.lampa"))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        # update existing id
        res = asyncio.run(c.save_item("app", "Lampa v2", "lampa://top.rootu.lampa", item_id))
        self.assertTrue(res["ok"], res)
        # save_item cannot change an item's kind
        res = asyncio.run(c.save_item("bookmark", "X", "https://example.com/x", item_id))
        self.assertFalse(res["ok"])
        res = asyncio.run(c.save_item("bookmark", "Watch later", "https://example.com/show"))
        self.assertTrue(res["ok"], res)
        res = asyncio.run(c.delete_item(item_id))
        self.assertTrue(res["ok"], res)
        res = asyncio.run(c.list_items())
        self.assertEqual(len(res["items"]), 2)  # Another app + the remaining bookmark.
        raw = (self.base / "tv-library.bin").read_bytes()
        self.assertNotIn(b"lampa://", raw)  # encrypted at rest, not plaintext

    def test_forget_requires_explicit_confirm_and_removes_only_laptop_creds(self):
        factory = FakeRemoteCls()
        c = self._controller(remote_cls=factory)
        res = asyncio.run(c.forget_pairing(False))
        self.assertFalse(res["ok"])
        self.assertEqual(res["stage"], "validate")
        asyncio.run(c.pair_start("192.168.0.161"))
        asyncio.run(c.pair_finish("ABCDEF"))
        self.assertIsNotNone(self.store.load_credentials())
        res = asyncio.run(c.forget_pairing(True))
        self.assertTrue(res["ok"], res)
        self.assertTrue(res["removed_stored_credentials"])
        self.assertIsNone(self.store.load_credentials())

    def test_main_module_importable_without_third_party_deps(self):
        import importlib
        importlib.reload(importlib.import_module("tv_mcp.__main__"))


@unittest.skipUnless(HAS_SERVER, "mcp SDK not installed in this environment")
class McpRegistrationTests(unittest.TestCase):
    def test_expected_tools_are_registered(self):
        c = self._controller_with_fakes()
        app = tv_server.build_server(controller=c)
        manager = getattr(app, "_tool_manager", None)
        if manager is None:
            self.skipTest("unexpected mcp SDK layout (no _tool_manager)")
        tools = manager.list_tools()
        self.assertEqual({t.name for t in tools}, set(tv_server.TOOL_NAMES))
        self.assertEqual(len(tools), 12)
        by_name = {t.name: t for t in tools}
        self.assertIsNotNone(by_name["tv_save_item"].parameters)
        self.assertIn("properties", by_name["tv_save_item"].parameters)

    def _controller_with_fakes(self):
        base = Path(tempfile.mkdtemp(prefix="tvmcp-srv-"))
        self.addCleanup(shutil.rmtree, base, True)
        return TVController(store=CredentialStore(base_dir=base), remote_cls=FakeRemoteCls())


if __name__ == "__main__":
    unittest.main()
