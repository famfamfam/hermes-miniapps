import abc
import importlib.util
import io
import json
import os
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch
from urllib.error import HTTPError, URLError


# Load the plugin against minimal offline Hermes interfaces, even if Hermes is installed.
def load_adapter():
    modules = {name: types.ModuleType(name) for name in (
        "gateway", "gateway.config", "gateway.platforms", "gateway.platforms._shared",
        "gateway.platforms.base", "hermes_constants",
    )}
    modules["gateway.config"].Platform = lambda name: name
    modules["gateway.platforms._shared"].get_scoped_secret = lambda name, default=None: default
    modules["hermes_constants"].get_hermes_home = lambda: Path(".")

    class Base(abc.ABC):
        def __init__(self, config, platform):
            self.config, self.platform, self.running = config, platform, False

        @abc.abstractmethod
        async def get_chat_info(self, chat_id):
            pass

        def _mark_connected(self):
            self.running = True

        def _mark_disconnected(self):
            self.running = False

    class Result:
        def __init__(self, success, message_id=None, error=None):
            self.success, self.message_id, self.error = success, message_id, error

    modules["gateway.platforms.base"].BasePlatformAdapter = Base
    modules["gateway.platforms.base"].SendResult = Result
    spec = importlib.util.spec_from_file_location("onesignal_test_adapter", Path(__file__).with_name("adapter.py"))
    adapter = importlib.util.module_from_spec(spec)
    with patch.dict(sys.modules, modules):
        spec.loader.exec_module(adapter)
    return adapter


adapter = load_adapter()
ID = "12345678-1234-1234-1234-123456789abc"


class Response:
    def __init__(self, body=None, status=200):
        self.body = json.dumps({"id": ID} if body is None else body).encode()
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass

    def read(self, limit):
        return self.body[:limit]


class PluginTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.secrets = dict(zip(adapter._NAMES, ("app-test", "key-test", "subscription-test")))
        self.home_patch = patch.object(adapter, "get_hermes_home", lambda: self.home)
        self.secret_patch = patch.object(adapter, "get_scoped_secret", lambda name, default=None: self.secrets.get(name, default))
        self.home_patch.start()
        self.secret_patch.start()
        self.addCleanup(self.home_patch.stop)
        self.addCleanup(self.secret_patch.stop)

    def test_register_and_targets(self):
        class Context:
            def register_platform(self, **kwargs):
                self.kwargs = kwargs
        ctx = Context()
        adapter.register(ctx)
        self.assertEqual(ctx.kwargs["name"], "onesignal")
        self.assertIs(ctx.kwargs["standalone_sender_fn"], adapter._standalone_send)
        self.assertEqual(ctx.kwargs["parse_target_ref_fn"]("phone"), ("phone", None))
        for target in ("PHONE", " phone", "other", "phone:thread", ""):
            self.assertIsNone(ctx.kwargs["parse_target_ref_fn"](target))
            self.assertFalse(ctx.kwargs["validate_target_ref_fn"](target))

    def test_profile_scoping_and_enablement(self):
        self.assertTrue(adapter._check())
        self.assertEqual(adapter._enablement()["home_channel"]["chat_id"], "phone")
        with patch.dict(os.environ, {name: "other-profile" for name in adapter._NAMES}):
            self.secrets.clear()
            self.assertIsNone(adapter._enablement())
            self.assertFalse(adapter._check())

    def test_profile_file_precedence_and_failure_closed(self):
        path = self.home / adapter._FILE
        data = dict(zip(adapter._NAMES, ("file-app", "file-key", "file-sub")))
        path.write_text(json.dumps(data), encoding="utf-8")
        path.chmod(0o600)
        self.assertEqual(adapter._credentials(), list(data.values()))
        self.assertTrue(adapter._enablement())
        other = self.home / "second-profile"
        other.mkdir()
        with patch.object(adapter, "get_hermes_home", lambda: other):
            self.secrets.clear()
            self.assertIsNone(adapter._credentials())
            self.assertIsNone(adapter._enablement())
        self.secrets.update(zip(adapter._NAMES, ("app-test", "key-test", "subscription-test")))
        path.write_text("not json", encoding="utf-8")
        self.assertIsNone(adapter._credentials())
        path.write_text(json.dumps(data), encoding="utf-8")
        if os.name != "nt":
            path.chmod(0o644)
            self.assertIsNone(adapter._credentials())
        path.unlink()
        self.assertEqual(adapter._credentials(), list(self.secrets.values()))

    async def test_adapter_and_standalone_payload(self):
        calls = []
        def fake_open(request, timeout):
            calls.append((request, timeout))
            return Response()
        with patch.object(adapter, "_open", fake_open):
            live = adapter.OneSignalAdapter(object())
            self.assertTrue(await live.connect())
            self.assertTrue(live.running)
            self.assertEqual(await live.get_chat_info("phone"), {"name": "Phone", "type": "dm"})
            with self.assertRaises(ValueError):
                await live.get_chat_info("other")
            result = await live.send("phone", "  " + "a" * 1250 + "  ")
            self.assertTrue(result.success)
            self.assertEqual(result.message_id, ID)
            request, timeout = calls[0]
            self.assertEqual(timeout, 10)
            self.assertEqual(request.full_url, "https://api.onesignal.com/notifications")
            self.assertEqual(request.get_method(), "POST")
            self.assertEqual(request.get_header("Authorization"), "Key key-test")
            payload = json.loads(request.data)
            self.assertEqual(payload["include_subscription_ids"], ["subscription-test"])
            self.assertEqual(payload["app_id"], "app-test")
            self.assertEqual(payload["target_channel"], "push")
            self.assertEqual(payload["contents"]["en"], "a" * 1200)
            result = await adapter._standalone_send(None, "phone", "hello\nworld")
            self.assertEqual(result, {"success": True, "message_id": ID})
            self.assertEqual(json.loads(calls[1][0].data)["contents"]["en"], "hello world")
            await live.disconnect()
            self.assertFalse(live.running)

    async def test_fail_closed_without_requests(self):
        with patch.object(adapter, "_open", side_effect=AssertionError("unexpected network")):
            live = adapter.OneSignalAdapter(None)
            self.assertFalse((await live.send("other", "hello")).success)
            for kwargs in ({"thread_id": "x"}, {"media_files": ["x"]}, {"force_document": True}):
                self.assertIn("error", await adapter._standalone_send(None, "phone", "hello", **kwargs))
            for message in ("", "  ", None):
                self.assertIn("error", await adapter._standalone_send(None, "phone", message))
            self.secrets.clear()
            self.assertFalse(await live.connect())
            self.assertIn("error", await adapter._standalone_send(None, "phone", "hello"))

    async def test_errors_no_retries_or_sensitive_details(self):
        errors = [TimeoutError("key-test"), URLError("subscription-test"),
                  HTTPError("url", 429, "message", {}, io.BytesIO(b"secret"))]
        for error in errors:
            with self.subTest(error=type(error).__name__), patch.object(adapter, "_open", side_effect=error) as opener:
                result = await adapter._standalone_send(None, "phone", "hello")
                self.assertIn("error", result)
                self.assertEqual(opener.call_count, 1)
                for secret in ("key-test", "subscription-test", "hello"):
                    self.assertNotIn(secret, str(result))
        for body in ({}, {"id": ID, "errors": ["secret"]}, {"id": ""}):
            with patch.object(adapter, "_open", return_value=Response(body)):
                self.assertIn("error", await adapter._standalone_send(None, "phone", "hello"))
        with patch.object(adapter, "_open", return_value=Response(status=302)):
            self.assertIn("error", await adapter._standalone_send(None, "phone", "hello"))
        self.assertIsNone(adapter._NoRedirect().redirect_request(None, None, 302, "", {}, "https://elsewhere.test"))


if __name__ == "__main__":
    unittest.main()
