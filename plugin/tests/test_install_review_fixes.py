"""Installer: regressions found in the code review of 16 October 2026."""
from __future__ import annotations

from pathlib import PurePosixPath

from install_support import new_world

from mobile_surfaces.install.cli import main

P = PurePosixPath
UNIT = "/etc/systemd/system/hermes-surfaces.service"
MCP_TOKEN = "/etc/hermes-surfaces/mcp-token"


def run(world, *args):
    return main(list(args), deps=world.deps)


def test_a_bare_python_name_is_looked_up_on_path_before_it_is_judged(tmp_path):
    # `realpath("python3.12")` alone is "<cwd>/python3.12" (a clone under /home): the interpreter that runs is
    # /usr/bin/python3.12, which the sandboxed service can read.
    w = new_world(
        tmp_path,
        which={"python3.12": "/usr/bin/python3.12"},
        realpath={"python3.12": "/home/alice/clone/python3.12"},
    )
    assert run(w, "plan", "--scope", "system", "--python", "python3.12") == 0, w.cap.stderr
    assert "resolves to" not in w.cap.stdout
    assert run(w, "apply", "--scope", "system", "--python", "python3.12") == 0, w.cap.stderr


def test_a_bare_python_name_that_resolves_under_home_is_still_refused(tmp_path):
    w = new_world(
        tmp_path,
        which={"python3.12": "/home/alice/.pyenv/shims/python3.12"},
        realpath={"/home/alice/.pyenv/shims/python3.12": "/home/alice/.pyenv/versions/3.12/bin/python3.12"},
    )
    assert run(w, "apply", "--scope", "system", "--python", "python3.12") == 3
    assert "Python interpreter resolves to /home/alice/.pyenv/versions" in w.cap.stderr


def test_health_probe_of_an_ipv6_loopback_host_brackets_the_address(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--host", "::1") == 0, w.cap.stderr
    w.cap.out.clear()
    assert run(w, "status", "--scope", "system", "--health") == 0, w.cap.stdout + w.cap.stderr
    urls = [url for url, _ in w.http_requests]
    assert "http://[::1]:8787/api/plugins/mobile-surfaces/v1/health" in urls


def test_a_drop_in_written_by_someone_else_is_never_overwritten(tmp_path):
    w = new_world(tmp_path)
    w.put(UNIT + ".d/resources.conf", "[Service]\nMemoryMax=1G\n")  # an administrator's file
    assert run(w, "apply", "--scope", "system", "--limits", "small") == 3
    assert "was not created by this installer" in w.cap.stderr
    assert w.read(UNIT + ".d/resources.conf") == "[Service]\nMemoryMax=1G\n"
    assert not w.exists("/opt/hermes-surfaces")


def test_an_upgrade_that_names_hermes_user_hands_over_the_kept_mcp_token(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0, w.cap.stderr
    token = w.read(MCP_TOKEN)
    w.fs.owners[P(MCP_TOKEN)] = "root"  # what a first install without --hermes-user leaves behind
    assert run(w, "apply", "--scope", "system", "--upgrade", "--hermes-user", "hermes") == 0, w.cap.stderr
    assert w.fs.owners[P(MCP_TOKEN)] == "hermes"
    assert w.read(MCP_TOKEN) == token  # the value is kept, only the owner changes
    assert f"chown  hermes {MCP_TOKEN}" in w.cap.stdout


def test_a_kept_token_that_already_belongs_to_hermes_is_left_alone(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--hermes-user", "hermes") == 0, w.cap.stderr
    assert w.fs.owners[P(MCP_TOKEN)] == "hermes"
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system", "--upgrade", "--hermes-user", "hermes") == 0, w.cap.stderr
    assert not [op for op in w.fs.ops if op[0] == "chown" and op[1] == P(MCP_TOKEN)]


def test_refreshed_code_without_a_unit_change_still_asks_for_a_restart(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0, w.cap.stderr
    (tmp_path / "repo" / "plugin" / "devserver.py").write_text("print('new code')\n", encoding="utf-8")
    w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0, w.cap.stderr
    assert "still uses the old one until it restarts" in w.cap.stdout
    assert "restart" not in w.runner.systemctl_verbs()  # asked for, never done behind the admin's back


import json
import pytest

MANIFEST = "/opt/hermes-surfaces/install.json"


@pytest.mark.parametrize("flag", ["--start", "--enable"])
def test_an_upgrade_whose_only_change_is_a_service_action_still_ends_with_a_complete_record(tmp_path, flag):
    # Found on a real host (16 October 2026): the plan wrote the record "incomplete" first (the restart counts as a
    # change) and then skipped the closing "complete" write, which it had compared with the record read BEFORE the run.
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0, w.cap.stderr
    assert json.loads(w.read(MANIFEST))["complete"] is True
    w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade", flag) == 0, w.cap.stderr
    assert json.loads(w.read(MANIFEST))["complete"] is True
    w.cap.out.clear()
    assert run(w, "status", "--scope", "system") == 0, w.cap.stdout + w.cap.stderr
    assert "INCOMPLETE" not in w.cap.stdout


def test_a_fresh_install_and_a_changing_upgrade_still_end_complete(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--start") == 0, w.cap.stderr
    assert json.loads(w.read(MANIFEST))["complete"] is True
    (tmp_path / "repo" / "plugin" / "devserver.py").write_text("print('new code')\n", encoding="utf-8")
    assert run(w, "apply", "--scope", "system", "--upgrade", "--start") == 0, w.cap.stderr
    assert json.loads(w.read(MANIFEST))["complete"] is True


def test_an_upgrade_that_changes_nothing_says_nothing_about_restarting(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0, w.cap.stderr
    w.cap.out.clear()
    assert run(w, "apply", "--scope", "system", "--upgrade") == 0, w.cap.stderr
    assert "restart" not in w.cap.stdout.lower().replace("--upgrade", "")
