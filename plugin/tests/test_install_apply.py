"""Installer: `apply` with a recording filesystem and a fake systemctl/pip/npm.

Real systemd is never involved here: these tests prove what the installer asks the host to do and in
which order, not that systemd accepts the unit.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path, PurePosixPath

import pytest
from install_support import SECRET_PREFIX, new_world

from mobile_surfaces.install.cli import main
from mobile_surfaces.install.effects import RunResult

P = PurePosixPath
UNIT = "/etc/systemd/system/hermes-surfaces.service"


def run(world, *args):
    return main(list(args), deps=world.deps)


def event_index(world, predicate):
    for i, event in enumerate(world.events):
        if predicate(event):
            return i
    raise AssertionError("event not found")


def ran(argv_part: str):
    return lambda e: e[0] == "run" and argv_part in " ".join(e[1])


def wrote(path: str, kind: str = "write"):
    return lambda e: e[0] == "fs" and e[1] == kind and e[2] == P(path)


# -- a complete system install --------------------------------------------------------------------------


def test_system_install_creates_everything_with_the_right_permissions(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--hermes-user", "hermes") == 0, w.cap.stderr
    modes = w.fs.modes
    assert modes[P("/opt/hermes-surfaces")] == 0o755
    assert modes[P("/etc/hermes-surfaces")] == 0o711  # traversable only because a Hermes user must reach its own file
    assert modes[P("/etc/hermes-surfaces/api-token")] == 0o600
    assert modes[P("/etc/hermes-surfaces/mcp-token")] == 0o600
    assert modes[P(UNIT)] == 0o644 and modes[P("/opt/hermes-surfaces/install.json")] == 0o644
    assert w.fs.owners == {P("/etc/hermes-surfaces/mcp-token"): "hermes"}  # the phone API token stays root-only
    # systemd creates the dynamic user's state directory itself (StateDirectory=, mode 0700)
    assert not w.exists("/var/lib/hermes-surfaces") and P("/var/lib/hermes-surfaces") not in modes
    for path in (P("/opt/hermes-surfaces/skills/surfaces-author/SKILL.md"),
                 P("/opt/hermes-surfaces/skills/surfaces-connect-phone/SKILL.md")):
        assert modes[path] == 0o644


def test_secrets_directory_is_root_only_without_a_hermes_user(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    assert w.fs.modes[P("/etc/hermes-surfaces")] == 0o700
    assert w.fs.owners == {}


def test_steps_happen_in_a_safe_order(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--enable", "--start") == 0
    first_fs = [e for e in w.events if e[0] == "fs"]
    assert first_fs[0][:3] == ("fs", "mkdir", P("/opt/hermes-surfaces"))
    assert first_fs[1][:3] == ("fs", "write", P("/opt/hermes-surfaces/install.json"))
    i_venv, i_pip = event_index(w, ran("-m venv")), event_index(w, ran("-m pip install"))
    i_check = event_index(w, ran("import devserver"))
    i_api, i_mcp = event_index(w, wrote("/etc/hermes-surfaces/api-token")), event_index(w, wrote("/etc/hermes-surfaces/mcp-token"))
    i_unit, i_reload = event_index(w, wrote(UNIT)), event_index(w, ran("daemon-reload"))
    i_enable, i_restart = event_index(w, ran("enable")), event_index(w, ran("restart"))
    assert i_venv < i_pip < i_check < i_api < i_mcp < i_unit < i_reload < i_enable < i_restart
    manifests = [i for i, e in enumerate(w.events) if wrote("/opt/hermes-surfaces/install.json")(e)]
    assert len(manifests) == 2 and manifests[-1] > i_restart  # incomplete first, complete only at the very end
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is True


def test_nothing_is_started_or_enabled_by_default(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    assert w.runner.systemctl_verbs() == ["daemon-reload"]
    assert "systemctl start hermes-surfaces.service" in w.cap.stdout


def test_service_is_not_given_demo_data_or_a_seed_step(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    text = w.read(UNIT)
    assert "ExecStartPre" not in text.replace("# No ExecStartPre", "")
    for call in w.runner.calls:
        assert "demo" not in call.argv and not any(Path(a).name.startswith("seed") for a in call.argv)
        assert call.argv[0] != "ms_admin" and "ms_admin.py" not in " ".join(call.argv).replace("import devserver, ms_admin", "")


def test_dev_data_and_tests_are_never_copied_into_the_install(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring") == 0
    copied = [p for p in w.root.rglob("*") if p.is_file()]
    assert copied
    assert not any(".devhome" in p.parts or "tests" in p.parts for p in copied)
    assert not any("MUST-NOT-BE-COPIED" in p.read_text(errors="ignore") for p in copied)
    assert not w.exists("/opt/hermes-surfaces/.build")  # the build snapshot is removed again
    assert not any("leftpad" in str(p) for p in copied)  # the checkout's node_modules is not copied
    assert w.exists("/opt/hermes-surfaces/templates/starter-app/package-lock.json")
    assert w.exists("/opt/hermes-surfaces/templates/starter-app/node_modules")  # created by (fake) `npm ci` in place


def test_pip_installs_pinned_from_the_checkout_snapshot(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    [pip] = w.runner.matching("-m pip install")
    assert pip.argv[0] == "/opt/hermes-surfaces/venv/bin/python"
    assert "-c" in pip.argv and pip.argv[pip.argv.index("-c") + 1].endswith("plugin/constraints.txt")
    assert pip.argv[-1] == "/opt/hermes-surfaces/.build/plugin"
    assert "--force-reinstall" not in pip.argv and "--no-index" not in pip.argv
    assert pip.env["PYTHONNOUSERSITE"] == "1"


def test_authoring_installs_node_dependencies_without_scripts(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring") == 0
    [npm] = w.runner.matching("npm ci")
    assert "--ignore-scripts" in npm.argv and npm.cwd.replace("\\", "/").endswith("/opt/hermes-surfaces/templates/starter-app")
    assert "--offline" not in npm.argv
    assert "--template /opt/hermes-surfaces/templates/starter-app" in w.read(UNIT)


def test_data_only_install_does_not_touch_node_at_all(tmp_path):
    w = new_world(tmp_path, which={"node": None, "npm": None})
    assert run(w, "apply", "--scope", "system") == 0
    assert not w.runner.matching("npm") and not w.runner.matching("node")
    assert not w.exists("/opt/hermes-surfaces/templates")


def test_resource_dropin_is_written_only_when_asked(tmp_path):
    plain = new_world(tmp_path / "a")
    assert run(plain, "apply", "--scope", "system") == 0
    assert not plain.exists(UNIT + ".d/resources.conf")
    limited = new_world(tmp_path / "b")
    assert run(limited, "apply", "--scope", "system", "--limits", "small", "--memory-max", "300M") == 0
    text = limited.read(UNIT + ".d/resources.conf")
    assert "MemoryMax=300M" in text and "MemoryHigh=128M" in text and "CPUQuota=25%" in text


# -- permissions of the process -------------------------------------------------------------------------


def test_build_commands_run_with_umask_022_and_it_is_restored(tmp_path, monkeypatch):
    state = {"mask": 0o077}

    def fake_umask(new):
        old, state["mask"] = state["mask"], new
        return old

    monkeypatch.setattr(os, "umask", fake_umask)
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring") == 0
    for needle in ("-m venv", "-m pip install", "npm ci", "daemon-reload"):
        [call] = w.runner.matching(needle)
        assert call.umask == 0o022, needle  # a root umask of 077 must not make the venv unreadable for the service
    assert state["mask"] == 0o077


def test_umask_is_restored_when_a_step_fails(tmp_path, monkeypatch):
    state = {"mask": 0o027}
    monkeypatch.setattr(os, "umask", lambda new: (state.__setitem__("old", state["mask"]), state.__setitem__("mask", new), state["old"])[2])
    w = new_world(tmp_path, responder=lambda argv: RunResult(1, "", "boom") if "pip" in argv else None)
    assert run(w, "apply", "--scope", "system") == 1
    assert state["mask"] == 0o027


# -- secrets never leave their files --------------------------------------------------------------------


def test_tokens_are_random_distinct_and_only_in_their_files(tmp_path, caplog):
    caplog.set_level(logging.DEBUG)
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--limits", "small", "--enable", "--start") == 0
    assert len(w.tokens) == 2 and w.tokens[0] != w.tokens[1]
    assert w.read("/etc/hermes-surfaces/api-token") == w.tokens[0] + "\n"
    assert w.read("/etc/hermes-surfaces/mcp-token") == w.tokens[1] + "\n"
    for token in w.tokens:
        assert token not in w.cap.everything
        assert token not in caplog.text
        for call in w.runner.calls:
            assert token not in " ".join(call.argv) and token not in json.dumps(call.env) and token not in (call.cwd or "")
        holders = sorted(
            p.relative_to(w.root).as_posix() for p in w.root.rglob("*") if p.is_file() and token in p.read_text(errors="ignore")
        )
        assert len(holders) == 1 and holders[0].startswith("etc/hermes-surfaces/")
    assert SECRET_PREFIX not in w.read(UNIT) + w.read("/opt/hermes-surfaces/install.json")


def test_the_real_token_generator_gives_long_url_safe_values():
    from mobile_surfaces.install.effects import new_token

    first, second = new_token(), new_token()
    assert first != second and len(first) >= 43 and all(c.isalnum() or c in "-_" for c in first)


def test_a_short_token_from_a_broken_generator_is_refused(tmp_path):
    w = new_world(tmp_path)
    w.deps.token_factory = lambda: "short"
    assert run(w, "apply", "--scope", "system") == 1
    assert not w.exists("/etc/hermes-surfaces/api-token")


def test_failure_output_carries_the_tail_of_the_command_not_secrets(tmp_path):
    def fail_pip(argv):
        return RunResult(1, "", "ERROR: no matching distribution found for fastapi\n") if "pip" in argv else None

    w = new_world(tmp_path, responder=fail_pip)
    assert run(w, "apply", "--scope", "system") == 1
    assert "no matching distribution" in w.cap.stderr and "re-run with --upgrade" in w.cap.stderr


def test_a_filesystem_error_is_a_clean_message_not_a_traceback(tmp_path):
    w = new_world(tmp_path)
    original = w.fs.write_bytes

    def deny(path, data, mode):
        if path == P("/etc/hermes-surfaces/mcp-token"):
            raise PermissionError(13, "Permission denied", "/etc/hermes-surfaces/mcp-token")
        original(path, data, mode)

    w.fs.write_bytes = deny
    assert run(w, "apply", "--scope", "system") == 1
    assert w.cap.stderr.startswith("error: Permission denied (/etc/hermes-surfaces/mcp-token)")
    assert "Traceback" not in w.cap.everything and all(t not in w.cap.everything for t in w.tokens)
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is False  # resumable


def test_missing_venv_module_gets_a_hint(tmp_path):
    def no_venv(argv):
        return RunResult(1, "", "ensurepip is not available") if "venv" in argv else None

    w = new_world(tmp_path, responder=no_venv)
    assert run(w, "apply", "--scope", "system") == 1
    assert "python3-venv" in w.cap.stderr


# -- refusing to be a surprise --------------------------------------------------------------------------


def test_second_apply_is_refused_and_changes_nothing(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    before = {p: p.read_bytes() for p in w.root.rglob("*") if p.is_file()}
    w.fs.clear_ops(); w.runner.calls.clear()
    assert run(w, "apply", "--scope", "system") == 3
    assert "already installed" in w.cap.stderr and "--upgrade" in w.cap.stderr
    assert w.fs.ops == [] and w.runner.mutating() == []
    assert before == {p: p.read_bytes() for p in w.root.rglob("*") if p.is_file()}


def test_existing_foreign_unit_is_never_overwritten(tmp_path):
    w = new_world(tmp_path)
    w.put(UNIT, "# somebody else's unit\n")
    assert run(w, "apply", "--scope", "system") == 3
    assert w.read(UNIT) == "# somebody else's unit\n" and w.fs.ops == []


@pytest.mark.parametrize("kwargs,args,fragment", [
    ({"euid": 1000}, [], "needs root"),
    ({"platform": "win32", "euid": None}, [], "Linux host"),
    ({"which": {"systemctl": None}}, [], "systemctl was not found"),
    ({"python_version": (3, 10)}, [], "too old"),
    ({"responder": lambda a: RunResult(0, "systemd 245 (245.4-4ubuntu3)\n") if a[-1:] == ("--version",) and a[0] == "systemctl" else None}, [], "systemd 245 is too old"),
    ({"responder": lambda a: RunResult(1, "", "boom") if a[-1:] == ("--version",) and a[0] == "systemctl" else None}, [], "systemd version"),
    ({"realpath": {"/usr/bin/python3": "/home/alice/.pyenv/versions/3.12.1/bin/python3.12"}}, [], "Python interpreter resolves to"),
    ({"realpath": {"/root/.local/bin/python3": "/root/.local/share/uv/python/cpython-3.12/bin/python3"}}, ["--python", "/root/.local/bin/python3"], "--python /usr/bin/python3"),
    ({"which": {"node": None}}, ["--with-authoring"], "needs Node.js"),
    ({"which": {"npm": None}}, ["--with-authoring"], "needs npm"),
    ({"responder": lambda a: RunResult(0, "v18.20.0\n") if a[-1:] == ("--version",) else None}, ["--with-authoring"], "too old"),
    ({"realpath": {"/usr/bin/node": "/root/.nvm/versions/node/v22/bin/node"}}, ["--with-authoring"], "ProtectHome"),
    ({"responder": lambda a: RunResult(1, "", "no such user") if a[:2] == ("id", "-u") else None}, ["--hermes-user", "ghost"], "no such user"),
])
def test_preflight_refusals_change_nothing(tmp_path, kwargs, args, fragment):
    w = new_world(tmp_path, **kwargs)
    assert run(w, "apply", "--scope", "system", *args) == 3
    assert fragment in w.cap.stderr
    assert "nothing was changed" in w.cap.stderr
    assert w.fs.ops == [] and list(w.root.rglob("*")) == []
    assert w.runner.mutating() == []  # only read-only probes ran: git, --version, id


def test_an_interpreter_under_home_is_fine_for_a_user_service(tmp_path):
    w = new_world(tmp_path, euid=1000, home="/home/bob", realpath={"/usr/bin/python3": "/home/bob/.pyenv/versions/3.12/bin/python3.12"})
    assert run(w, "apply", "--scope", "user") == 0, w.cap.stderr


def test_user_scope_does_not_need_a_modern_systemd(tmp_path):
    w = new_world(tmp_path, euid=1000, home="/home/bob", responder=lambda a: RunResult(0, "systemd 245\n") if a[-1:] == ("--version",) else None)
    assert run(w, "apply", "--scope", "user") == 0, w.cap.stderr  # direct token files: no LoadCredential= involved
    assert not w.runner.matching("--version")


def test_busy_ports_are_refused(tmp_path):
    w = new_world(tmp_path)
    w.listening = {("127.0.0.1", 8788)}
    assert run(w, "apply", "--scope", "system") == 3
    assert "127.0.0.1:8788 already accepts connections" in w.cap.stderr and w.fs.ops == []
    w2 = new_world(tmp_path / "b")
    w2.listening = {("*", 9000)}
    assert run(w2, "apply", "--scope", "system", "--host", "0.0.0.0", "--api-port", "9000") == 3


def test_all_problems_are_reported_together(tmp_path):
    w = new_world(tmp_path, euid=1000, which={"systemctl": None})
    w.listening = {("127.0.0.1", 8787)}
    assert run(w, "apply", "--scope", "system") == 3
    assert w.cap.stderr.count("\n  - ") >= 3


def test_dry_run_apply_is_a_plan(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--dry-run") == 0
    assert w.cap.stdout.startswith("PLAN:") and w.fs.ops == [] and w.tokens == []
    assert not [c for c in w.runner.calls if c.argv[0] != "git"]


def test_dry_run_of_a_refused_apply_exits_3(tmp_path):
    w = new_world(tmp_path)
    w.put(UNIT, "x")
    assert run(w, "apply", "--scope", "system", "--dry-run") == 3


# -- idempotency, upgrades -------------------------------------------------------------------------------


def test_upgrade_without_changes_does_nothing(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--limits", "small") == 0
    tokens = (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token"))
    w.fs.clear_ops(); w.runner.calls.clear(); w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0
    assert "already up to date" in w.cap.stdout
    assert w.fs.ops == []
    assert [c.argv[0] for c in w.runner.calls if c.argv[0] != "git"] == []  # not even a daemon-reload
    assert (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token")) == tokens
    assert len(w.tokens) == 2


def test_upgrade_remembers_the_options_of_the_install(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--api-port", "9100", "--mcp-port", "9101", "--limits", "small") == 0
    unit, dropin = w.read(UNIT), w.read(UNIT + ".d/resources.conf")
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0
    assert (w.read(UNIT), w.read(UNIT + ".d/resources.conf")) == (unit, dropin) and w.fs.ops == []


def test_upgrade_with_new_sources_reinstalls_but_keeps_tokens_and_state(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    tokens = (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token"))
    w.put("/var/lib/hermes-surfaces/mobile-surfaces/registry.db", "user data")
    (tmp_path / "repo" / "plugin" / "devserver.py").write_text("print('new code')\n", encoding="utf-8")
    w.fs.clear_ops(); w.runner.calls.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0
    [pip] = w.runner.matching("-m pip install")
    assert "--force-reinstall" in pip.argv  # same version number, new code
    assert (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token")) == tokens
    assert w.read("/var/lib/hermes-surfaces/mobile-surfaces/registry.db") == "user data"
    assert P(UNIT) not in w.fs.writes()  # the unit did not change
    assert "restart" not in w.runner.systemctl_verbs()


def test_upgrade_that_changes_the_unit_says_a_restart_is_needed(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade", "--api-port", "9200") == 0
    assert "--port 9200" in w.read(UNIT)
    assert w.runner.systemctl_verbs()[-1] == "daemon-reload"  # reloaded, but not restarted behind the admin's back
    assert "restart" not in w.runner.systemctl_verbs()
    assert "restart it when convenient (systemctl restart hermes-surfaces.service)" in w.cap.stdout


def test_upgrade_can_turn_authoring_off_and_limits_off(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--limits", "small") == 0
    assert w.exists(UNIT + ".d/resources.conf")
    assert run(w, "apply", "--scope", "system", "--upgrade", "--no-authoring", "--limits", "none") == 0
    assert "--no-authoring" in w.read(UNIT) and "--template" not in w.read(UNIT)
    assert not w.exists(UNIT + ".d/resources.conf")  # our own drop-in is removed when limits are no longer wanted


def test_a_drop_in_written_by_someone_else_is_left_alone(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    w.put(UNIT + ".d/resources.conf", "[Service]\nMemoryMax=1G\n")  # an admin's file, not marked as ours
    assert run(w, "apply", "--scope", "system", "--upgrade", "--limits", "none") == 0
    assert w.read(UNIT + ".d/resources.conf") == "[Service]\nMemoryMax=1G\n"


def test_rotating_tokens_replaces_both_and_keeps_them_private(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    old = list(w.tokens)
    assert run(w, "apply", "--scope", "system", "--upgrade", "--rotate-tokens") == 0
    new = w.tokens[2:]
    assert len(new) == 2 and not set(old) & set(new)
    assert w.read("/etc/hermes-surfaces/api-token") == new[0] + "\n"
    assert w.fs.modes[P("/etc/hermes-surfaces/api-token")] == 0o600
    assert all(t not in w.cap.everything for t in old + new)


def test_failed_install_can_be_resumed_with_upgrade(tmp_path):
    failing = {"on": True}

    def responder(argv):
        return RunResult(1, "", "network down") if failing["on"] and "pip" in argv else None

    w = new_world(tmp_path, responder=responder)
    assert run(w, "apply", "--scope", "system") == 1
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is False
    assert not w.exists(UNIT) and not w.exists("/etc/hermes-surfaces/api-token")  # nothing runnable half-written
    assert run(w, "apply", "--scope", "system") == 3  # not a silent retry
    assert run(w, "status", "--scope", "system") == 5 and "INCOMPLETE" in w.cap.stdout
    failing["on"] = False
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is True
    assert w.exists(UNIT) and len(w.tokens) == 2


def test_reuse_data_keeps_existing_tokens_and_creates_only_the_missing_one(tmp_path):
    w = new_world(tmp_path)
    w.put("/etc/hermes-surfaces/api-token", "A" * 43 + "\n")
    w.put("/var/lib/hermes-surfaces/mobile-surfaces/registry.db", "old data")
    assert run(w, "apply", "--scope", "system") == 3
    assert run(w, "apply", "--scope", "system", "--reuse-data") == 0
    assert w.read("/etc/hermes-surfaces/api-token") == "A" * 43 + "\n"
    assert len(w.tokens) == 1 and w.read("/etc/hermes-surfaces/mcp-token") == w.tokens[0] + "\n"
    assert w.read("/var/lib/hermes-surfaces/mobile-surfaces/registry.db") == "old data"


def test_reused_token_with_loose_permissions_is_tightened_with_a_warning(tmp_path):
    w = new_world(tmp_path)
    w.put("/etc/hermes-surfaces/api-token", "A" * 43 + "\n")
    w.fs.modes[P("/etc/hermes-surfaces/api-token")] = 0o644
    assert run(w, "apply", "--scope", "system", "--reuse-data") == 0
    assert ("chmod", P("/etc/hermes-surfaces/api-token"), 0o600) in w.fs.ops
    assert "was readable by others" in w.cap.stderr


# -- variants ------------------------------------------------------------------------------------------


def test_user_scope_needs_no_root_and_uses_the_users_directories(tmp_path):
    w = new_world(tmp_path, euid=1000, home="/home/bob")
    assert run(w, "apply", "--scope", "user", "--enable", "--start") == 0, w.cap.stderr
    cfg, state = "/home/bob/.config/hermes-surfaces", "/home/bob/.local/state/hermes-surfaces"
    assert w.fs.modes[P(cfg)] == 0o700 and w.fs.modes[P(state)] == 0o700
    assert w.fs.modes[P(cfg + "/api-token")] == 0o600
    assert w.exists("/home/bob/.config/systemd/user/hermes-surfaces.service")
    assert w.fs.owners == {}
    assert all(c.argv[:2] == ("systemctl", "--user") for c in w.runner.calls if c.argv[0] == "systemctl")
    assert w.runner.systemctl_verbs() == ["daemon-reload", "enable", "restart"]
    assert "loginctl enable-linger" in w.cap.stdout


def test_two_installs_with_different_names_do_not_collide(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    assert run(w, "apply", "--scope", "system", "--name", "second", "--api-port", "9300", "--mcp-port", "9301") == 0
    assert w.exists("/etc/systemd/system/second.service") and w.exists("/etc/second/api-token")
    assert w.read("/etc/hermes-surfaces/api-token") != w.read("/etc/second/api-token")


def test_public_bind_is_allowed_but_warned_about_at_apply_time(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--host", "0.0.0.0") == 0
    assert "not a loopback address" in w.cap.stderr or "non-loopback" in w.cap.stderr
    text = w.read(UNIT)
    assert "--host 0.0.0.0" in text and "--mcp-host 127.0.0.1" in text


def test_copy_node_places_a_private_binary_and_points_path_at_it(tmp_path):
    node = tmp_path / "somewhere" / "node"
    node.parent.mkdir()
    node.write_bytes(b"\x7fELF-fake-node")
    w = new_world(tmp_path, realpath={"/usr/bin/node": str(node)})
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--copy-node") == 0
    assert w.fs.modes[P("/opt/hermes-surfaces/node/bin/node")] == 0o755
    assert w.fs.real(P("/opt/hermes-surfaces/node/bin/node")).read_bytes() == b"\x7fELF-fake-node"
    assert "Environment=PATH=/opt/hermes-surfaces/node/bin:" in w.read(UNIT)


def test_node_in_an_unusual_directory_goes_on_the_units_path(tmp_path):
    w = new_world(tmp_path, which={"node": "/opt/node-22/bin/node"})
    assert run(w, "apply", "--scope", "system", "--with-authoring") == 0
    assert "Environment=PATH=/opt/node-22/bin:" in w.read(UNIT)


def test_wheelhouse_install_uses_no_index_and_no_source_snapshot(tmp_path):
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    (wheels / "mobile_surfaces-0.0.1-py3-none-any.whl").write_bytes(b"wheel")
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--wheelhouse", str(wheels)) == 0
    [pip] = w.runner.matching("-m pip install")
    assert "--no-index" in pip.argv and "mobile-surfaces==0.0.1" in pip.argv
    assert pip.argv[pip.argv.index("--find-links") + 1] == str(wheels.resolve()).replace("\\", "/")
    assert not any(e[0] == "fs" and ".build" in str(e[2]) for e in w.events)
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system", "--upgrade", "--wheelhouse", str(wheels)) == 0
    assert w.fs.ops == []  # same wheel: nothing to do


def test_wheelhouse_without_the_wheel_is_refused(tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--wheelhouse", str(empty)) == 3
    assert "no mobile_surfaces-*.whl" in w.cap.stderr and w.fs.ops == []


def test_npm_cache_makes_the_node_install_offline(tmp_path):
    cache = tmp_path / "npmcache"
    cache.mkdir()
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--with-authoring", "--npm-cache", str(cache)) == 0
    [npm] = w.runner.matching("npm ci")
    assert "--offline" in npm.argv and str(cache.resolve()) in npm.argv


def test_staging_root_writes_files_but_runs_nothing_on_the_host(tmp_path):
    w = new_world(tmp_path, platform="win32", euid=None, staging=True)
    assert run(w, "apply", "--scope", "system", "--root", str(w.root), "--hermes-user", "hermes", "--enable", "--start") == 0, w.cap.stderr
    assert w.exists(UNIT) and w.exists("/etc/hermes-surfaces/api-token") and w.exists("/opt/hermes-surfaces/install.json")
    assert [c.argv[0] for c in w.runner.calls if c.argv[0] != "git"] == []
    assert w.fs.owners == {}
    assert "[skipped: staging --root]" in w.cap.stdout
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is True


def test_a_staged_install_upgrades_idempotently_although_it_has_no_virtualenv(tmp_path):
    """Live-host steps (venv, pip, npm, systemctl) are skipped in staging, so they must not count as pending changes."""
    w = new_world(tmp_path, platform="win32", euid=None, staging=True)
    assert run(w, "apply", "--scope", "system", "--root", str(w.root), "--with-authoring", "--limits", "small") == 0
    assert not w.exists("/opt/hermes-surfaces/venv")
    w.fs.clear_ops(); w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--root", str(w.root), "--upgrade") == 0
    assert "already up to date" in w.cap.stdout and w.fs.ops == []
    assert json.loads(w.read("/opt/hermes-surfaces/install.json"))["complete"] is True  # never left half-marked
    assert run(w, "status", "--scope", "system", "--root", str(w.root)) == 0


def test_staging_root_still_keeps_secret_files_private(tmp_path):
    w = new_world(tmp_path, platform="win32", euid=None, staging=True)
    assert run(w, "apply", "--scope", "system", "--root", str(w.root)) == 0
    assert w.fs.modes[P("/etc/hermes-surfaces/api-token")] == 0o600 and w.fs.modes[P("/etc/hermes-surfaces")] == 0o700
    for token in w.tokens:
        assert token not in w.cap.everything
