import contextlib
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from urllib.error import HTTPError, URLError

from tools.cron_push import onesignal_push


class SendPushTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config_path = Path(self.temp.name) / "config.json"
        self.config = {"appid": "example-app", "subscription_id": "example-device", "api_key": "example-key"}
        self.write_config(self.config)
        patcher = patch.object(onesignal_push, "urlopen")
        self.urlopen = patcher.start()
        self.addCleanup(patcher.stop)
        self.response = MagicMock()
        self.response.status = 200
        self.response.read.return_value = b'{"id":"example-notification"}'
        self.urlopen.return_value.__enter__.return_value = self.response

    def write_config(self, config):
        self.config_path.write_text(json.dumps(config), encoding="utf-8")

    def send(self, title="Title", message="Message"):
        return onesignal_push.send_push(self.config_path, title, message)

    def test_request_targets_one_subscription(self):
        self.assertTrue(self.send())
        self.urlopen.assert_called_once()
        request = self.urlopen.call_args.args[0]
        self.assertEqual(self.urlopen.call_args.kwargs, {"timeout": 10})
        self.assertEqual(request.full_url, "https://api.onesignal.com/notifications")
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.get_header("Authorization"), "Key example-key")
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertEqual(json.loads(request.data), {
            "app_id": "example-app", "include_subscription_ids": ["example-device"],
            "target_channel": "push", "headings": {"en": "Title"},
            "contents": {"en": "Message"},
        })
        self.response.read.assert_called_once_with(65537)

    def test_invalid_config_never_sends(self):
        for config in ({}, [], None, {**self.config, "appid": ""},
                       {**self.config, "subscription_id": "  "},
                       {**self.config, "subscription_id": ["one", "two"]},
                       {**self.config, "api_key": "key\r\nheader"}):
            with self.subTest(config=config):
                self.write_config(config)
                self.assertFalse(self.send())
        self.config_path.write_text("{", encoding="utf-8")
        self.assertFalse(self.send())
        self.config_path.unlink()
        self.assertFalse(self.send())
        self.urlopen.assert_not_called()

    def test_empty_content_never_sends(self):
        for title, message in (("", "message"), ("title", " \n\t"), (None, "message"), ("title", None)):
            with self.subTest(title=title, message=message):
                self.assertFalse(self.send(title, message))
        self.urlopen.assert_not_called()

    def test_content_is_bounded_and_controls_are_removed(self):
        self.assertTrue(self.send("H\n" + "a" * 200, "M\x00" + "b" * 1300))
        payload = json.loads(self.urlopen.call_args.args[0].data)
        self.assertEqual(payload["headings"]["en"], ("H " + "a" * 200)[:120])
        self.assertEqual(payload["contents"]["en"], ("M " + "b" * 1300)[:1200])

    def test_failures_return_false_without_retry_or_secret_output(self):
        errors = [TimeoutError("example-key"), URLError("example-key"),
                  HTTPError("https://example.invalid", 401, "example-key", {}, None)]
        for error in errors:
            with self.subTest(error=type(error).__name__):
                self.urlopen.reset_mock()
                self.urlopen.side_effect = error
                output = io.StringIO()
                with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
                    self.assertIs(self.send(), False)
                self.assertEqual(output.getvalue(), "")
                self.urlopen.assert_called_once()

    def test_invalid_responses_fail_closed(self):
        for status, body in ((401, b'{"id":"x"}'), (500, b'{"id":"x"}'),
                             (200, b'{}'), (200, b'{"id":""}'),
                             (200, b'{"id":"  "}'), (200, b'{"id":123}'),
                             (200, b'{"id":"x","errors":["example-key"]}'),
                             (200, b'{"id":"x","errors":null}'),
                             (200, b'invalid'), (200, b'[]'), (200, b'x' * 65537)):
            with self.subTest(status=status, body=body[:100]):
                self.response.status = status
                self.response.read.return_value = body
                self.urlopen.reset_mock()
                self.assertIs(self.send(), False)
                self.urlopen.assert_called_once()

    def test_response_with_secret_is_not_exposed(self):
        self.response.read.return_value = b'{"id":"", "errors":["example-key"]}'
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(output):
            self.assertIs(self.send(), False)
        self.assertEqual(output.getvalue(), "")
        self.urlopen.assert_called_once()

    def test_empty_errors_are_accepted(self):
        self.response.read.return_value = b'{"id":"x","errors":[]}'
        self.assertTrue(self.send())

    def test_only_the_bound_profile_can_send_cron_push(self):
        self.config["profile_home"] = self.temp.name
        self.write_config(self.config)
        with patch.object(onesignal_push, "send_push", return_value=True) as send:
            self.assertIsNone(onesignal_push.notify_cron(self.config_path, self.config_path, "result"))
            self.assertIsNone(onesignal_push.notify_cron(self.config_path, "", "result"))
            send.assert_not_called()
            self.assertTrue(onesignal_push.notify_cron(self.config_path, Path(self.temp.name), "result"))
            send.assert_called_once_with(self.config_path, "Hermes", "result")

    def test_unbound_profile_cannot_send_cron_push(self):
        with patch.object(onesignal_push, "send_push") as send:
            self.assertIsNone(onesignal_push.notify_cron(self.config_path, self.temp.name, "result"))
            send.assert_not_called()

    def test_redirects_are_not_followed(self):
        self.assertIsNone(onesignal_push._NoRedirect().redirect_request(None, None, 302, None, None, "https://example.invalid"))


if __name__ == "__main__":
    unittest.main()
