import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("onesignal_installer", Path(__file__).with_name("onesignal.py"))
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)


@unittest.skipUnless(sys.platform.startswith("linux") and hasattr(os, "O_NOFOLLOW"), "requires Linux file permissions")
class OneSignalInstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.home = root / "profile"
        self.home.mkdir(mode=0o700)
        self.source = root / "source"
        self.source.mkdir()
        (self.source / "plugin.yaml").write_text("name: onesignal\nkind: platform\n")
        (self.source / "__init__.py").write_text("def register(ctx): pass\n")
        (self.source / "adapter.py").write_text("version = 1\n")
        self.secret = self.home / "onesignal.json"
        self.target = self.home / "plugins" / "platforms" / "onesignal"
        self.values = ["app-id", "secret-key", "subscription-id"]
        self.env = patch.dict(os.environ, {"SUDO_UID": ""})
        self.env.start()
        self.addCleanup(self.env.stop)

    def apply(self):
        with patch.object(installer.getpass, "getpass", side_effect=self.values):
            return installer.install(self.home, self.source)

    def test_plan_read_only_and_install_repeat_upgrade(self):
        installer.inspect(self.home, self.source)
        self.assertEqual(list(self.home.iterdir()), [])
        self.apply()
        self.assertEqual(stat.S_IMODE(self.secret.stat().st_mode), 0o600)
        self.assertEqual(list(json.loads(self.secret.read_text()).values()), self.values)
        saved = self.secret.read_bytes()
        (self.target / "extra.txt").write_text("keep")
        with patch.object(installer.getpass, "getpass", side_effect=AssertionError("must not prompt")):
            self.assertIn("unchanged", installer.install(self.home, self.source))
            (self.source / "adapter.py").write_text("version = 2\n")
            installer.install(self.home, self.source)
        self.assertEqual((self.target / "adapter.py").read_text(), "version = 2\n")
        self.assertEqual((self.target / "extra.txt").read_text(), "keep")
        self.assertEqual(self.secret.read_bytes(), saved)
        self.assertFalse((self.target.parent / ".hermes_onesignal.previous").exists())

    def test_unmanaged_and_locally_modified_refused(self):
        self.target.mkdir(parents=True)
        (self.target / "foreign").write_text("untouched")
        with self.assertRaises(installer.Refused):
            self.apply()
        self.assertFalse(self.secret.exists())
        self.assertEqual((self.target / "foreign").read_text(), "untouched")
        (self.target / "foreign").unlink()
        self.target.rmdir()
        self.apply()
        (self.target / "adapter.py").write_text("local edit")
        with self.assertRaises(installer.Refused):
            self.apply()
        self.assertEqual((self.target / "adapter.py").read_text(), "local edit")

    def test_rejects_bad_permissions_links_and_bad_credentials(self):
        self.secret.write_text("{}")
        self.secret.chmod(0o644)
        with self.assertRaises(installer.Refused):
            self.apply()
        self.secret.chmod(0o600)
        with self.assertRaises(installer.Refused):
            self.apply()
        self.secret.unlink()
        self.secret.symlink_to(self.source / "adapter.py")
        with self.assertRaises(installer.Refused):
            self.apply()
        self.secret.unlink()
        (self.home / "plugins").symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(installer.Refused):
            self.apply()
        self.assertFalse(self.secret.exists())

    def test_invalid_input_and_existing_backup_do_not_write(self):
        self.values[1] = ""
        with self.assertRaises(installer.Refused):
            self.apply()
        self.assertEqual(list(self.home.iterdir()), [])
        backup = self.home / "plugins" / "platforms" / ".hermes_onesignal.previous"
        backup.mkdir(parents=True)
        with self.assertRaises(installer.Refused):
            self.apply()
        self.assertFalse(self.secret.exists())

    def test_failed_switch_rolls_back_and_keeps_secrets(self):
        self.apply()
        (self.source / "adapter.py").write_text("version = 2\n")
        rename = os.rename
        def fail_stage(src, dst):
            if Path(dst) == self.target and ".stage-" in str(src):
                raise OSError("simulated failure")
            return rename(src, dst)
        with patch.object(installer.os, "rename", side_effect=fail_stage):
            with self.assertRaises(OSError):
                self.apply()
        self.assertEqual((self.target / "adapter.py").read_text(), "version = 1\n")
        self.assertTrue(self.secret.exists())
        self.apply()
        self.assertEqual((self.target / "adapter.py").read_text(), "version = 2\n")

    def test_hidden_input_required(self):
        import warnings
        def fallback(_prompt):
            warnings.warn("input may be echoed", installer.getpass.GetPassWarning)
        with patch.object(installer.getpass, "getpass", side_effect=fallback):
            with self.assertRaises(installer.Refused):
                installer.install(self.home, self.source)
        self.assertEqual(list(self.home.iterdir()), [])

    def test_second_installer_refuses_concurrent_run(self):
        import fcntl
        fd = os.open(self.home, os.O_RDONLY | os.O_DIRECTORY)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaises(BlockingIOError):
                self.apply()
            self.assertEqual(list(self.home.iterdir()), [])
        finally:
            os.close(fd)

    def test_secrets_not_printed(self):
        out, err = io.StringIO(), io.StringIO()
        with patch.object(installer.getpass, "getpass", side_effect=self.values), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            installer.install(self.home, self.source)
        for value in self.values:
            self.assertNotIn(value, out.getvalue() + err.getvalue())


if __name__ == "__main__":
    unittest.main()
