import sys
import types
import unittest
from unittest.mock import Mock, patch

from tools.cron_push.patch_hermes import patch_delivery


SOURCE = '''def _deliver_result(job, content, targets, suppressed_targets=0):
    if not targets:
        return "local"
    delivery_errors = []
    unverified_targets = []
    cleaned_delivery_content = "redacted: " + content
    _record_delivery_verification(job, unverified_targets)
    return "; ".join(delivery_errors) if delivery_errors else None
'''


class PatchTests(unittest.TestCase):
    def test_rejects_unknown_and_already_patched_sources(self):
        with self.assertRaises(ValueError):
            patch_delivery("def unrelated(): pass\n")
        with self.assertRaises(ValueError):
            patch_delivery(patch_delivery(SOURCE))
        with self.assertRaises(ValueError):
            patch_delivery(SOURCE + SOURCE.replace("_deliver_result", "other"))

    def test_only_resolved_unsuppressed_results_are_sent(self):
        source = patch_delivery(SOURCE)
        send = Mock(return_value=True)
        module = types.ModuleType("cron.hermes_onesignal_push")
        module.notify_cron = send
        constants = types.ModuleType("hermes_constants")
        constants.get_hermes_home = lambda: "/bound"
        logger = Mock()
        scope = {"_record_delivery_verification": Mock(), "logger": logger}
        with patch.dict(sys.modules, {"cron": types.ModuleType("cron"),
                                      "cron.hermes_onesignal_push": module,
                                      "hermes_constants": constants}):
            exec(source, scope)
            deliver = scope["_deliver_result"]
            self.assertEqual(deliver({}, "local content", []), "local")
            self.assertIsNone(deliver({}, "suppressed", [1], 1))
            send.assert_not_called()
            self.assertIsNone(deliver({}, "result", [1]))
            send.assert_called_once_with("/etc/hermes-cron-push/config.json", "/bound", "redacted: result")
            send.side_effect = RuntimeError("secret")
            self.assertIsNone(deliver({}, "result", [1]))
            logger.warning.assert_called_once_with("Cron push could not be sent")


if __name__ == "__main__":
    unittest.main()
