"""Installer: `plan` writes nothing, says exactly what would change, and refuses unsafe requests."""
from __future__ import annotations

from pathlib import PurePosixPath

import pytest
from install_support import SECRET_PREFIX, new_world

from mobile_surfaces.install.cli import main

P = PurePosixPath


def run(world, *args):
    return main(list(args), deps=world.deps)


def test_plan_is_the_default_command_and_writes_nothing(tmp_path):
    w = new_world(tmp_path)
    assert run(w) == 0
    assert w.fs.ops == []
    assert list(w.root.rglob("*")) == []
    assert w.cap.stdout.startswith("PLAN: install 'hermes-surfaces'. Nothing is written.")
    assert all(call.argv[0] == "git" for call in w.runner.calls)  # the only command: a read-only rev-parse


def test_plan_never_creates_a_token(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--with-authoring", "--hermes-user", "hermes")
    assert w.tokens == []
    assert SECRET_PREFIX not in w.cap.everything


def test_plan_lists_the_exact_system_layout(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    out = w.cap.stdout
    for line in (
        "mkdir  0755 /opt/hermes-surfaces",
        "mkdir  0700 /etc/hermes-surfaces",
        "token  0600 /etc/hermes-surfaces/api-token",
        "token  0600 /etc/hermes-surfaces/mcp-token",
        "write  0644 /etc/systemd/system/hermes-surfaces.service",
        "exec   systemctl daemon-reload",
        "-m venv /opt/hermes-surfaces/venv",
        "phone API      127.0.0.1:8787",
        "author MCP     127.0.0.1:8788  (always loopback)",
    ):
        assert line in out, line
    assert "systemctl start" in out  # the service is not started by default, and the plan says how
    assert "systemctl enable" not in out and "restart" not in out.split("Notes:")[0]
    assert "/var/lib/hermes-surfaces is created by systemd" in out


def test_plan_is_ordered_like_apply(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    lines = [line for line in w.cap.out if line.startswith(("  create", "  run", "  remove", "  ok", "  update"))]
    joined = "\n".join(lines)
    assert joined.index("-m venv") < joined.index("-m pip install") < joined.index("api-token")
    assert joined.index("api-token") < joined.index("hermes-surfaces.service") < joined.index("daemon-reload")
    assert joined.rindex("install.json") > joined.index("daemon-reload")  # record marked complete last


@pytest.mark.parametrize("args,expected,absent", [
    ((), ["PyPI"], ["npm registry"]),
    (("--with-authoring",), ["PyPI", "npm registry"], []),
    (("--with-authoring", "--npm-cache", "NPMCACHE"), ["PyPI"], ["npm registry"]),
    (("--wheelhouse", "WHEELS"), ["none (nothing is downloaded)"], ["PyPI", "npm registry"]),
])
def test_plan_names_every_network_access(tmp_path, args, expected, absent):
    w = new_world(tmp_path)
    wheels = tmp_path / "wheels"
    wheels.mkdir()
    (wheels / "mobile_surfaces-0.0.1-py3-none-any.whl").write_bytes(b"wheel")
    cache = tmp_path / "npmcache"
    cache.mkdir()
    args = tuple(a.replace("WHEELS", str(wheels)).replace("NPMCACHE", str(cache)) for a in args)
    assert run(w, "plan", *args) == 0
    block = w.cap.stdout.split("Network access made by `apply`:")[1].split("Notes:")[0]
    for text in expected:
        assert text in block, text
    for text in absent:
        assert text not in block, text
    assert "the service itself makes no outgoing connection" in block
    assert "enforced by IPAddressDeny=any" in block  # loopback bind, system scope


def test_plan_marks_what_is_already_in_place_after_an_install(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    w.cap.out.clear()
    assert run(w, "plan", "--scope", "system", "--upgrade") == 0
    assert "0 would change" in w.cap.stdout
    assert "create" not in "\n".join(line for line in w.cap.out if line.startswith("  create"))


# -- refusals: exit code 3, nothing changed --------------------------------------------------------------


def test_plan_refuses_when_the_unit_exists_and_is_not_ours(tmp_path):
    w = new_world(tmp_path)
    w.put("/etc/systemd/system/hermes-surfaces.service", "[Service]\n")
    assert run(w, "plan", "--scope", "system") == 3
    assert "not created by this installer" in w.cap.stdout
    assert run(w, "plan", "--scope", "system", "--upgrade") == 3  # --upgrade never adopts foreign files


def test_plan_refuses_a_foreign_install_record(tmp_path):
    w = new_world(tmp_path)
    w.put("/opt/hermes-surfaces/install.json", '{"schema": 1, "name": "someone-else", "scope": "system"}')
    assert run(w, "plan", "--scope", "system") == 3
    assert "does not describe an install named 'hermes-surfaces'" in w.cap.stdout


def test_plan_refuses_an_unreadable_install_record(tmp_path):
    w = new_world(tmp_path)
    w.put("/opt/hermes-surfaces/install.json", "{not json")
    assert run(w, "plan", "--scope", "system") == 3


def test_plan_refuses_leftover_data_without_reuse_flag(tmp_path):
    w = new_world(tmp_path)
    w.put("/etc/hermes-surfaces/api-token", "x" * 40)
    assert run(w, "plan", "--scope", "system") == 3
    assert "--reuse-data" in w.cap.stdout
    w.cap.out.clear()
    assert run(w, "plan", "--scope", "system", "--reuse-data") == 0
    assert "existing tokens are kept" in w.cap.stdout


def test_plan_refuses_leftover_state_dir_too(tmp_path):
    w = new_world(tmp_path)
    w.put("/var/lib/private/hermes-surfaces/mobile-surfaces/registry.db", "data")
    assert run(w, "plan", "--scope", "system") == 3


def test_upgrade_needs_an_install(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "plan", "--scope", "system", "--upgrade") == 3
    assert "nothing to upgrade" in w.cap.stdout or "no install of this name" in w.cap.stdout


def test_plan_refuses_an_incomplete_checkout(tmp_path):
    w = new_world(tmp_path)
    (tmp_path / "repo" / "plugin" / "constraints.txt").unlink()
    assert run(w, "plan", "--scope", "system") == 3
    assert "constraints.txt not found" in w.cap.stdout and "--source" in w.cap.stdout


def test_authoring_needs_the_template_in_the_checkout(tmp_path):
    w = new_world(tmp_path)
    (tmp_path / "repo" / "templates" / "starter-app" / "package-lock.json").unlink()
    assert run(w, "plan", "--scope", "system") == 0
    assert run(w, "plan", "--scope", "system", "--with-authoring") == 3


def test_a_second_install_with_another_name_is_independent(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    assert run(w, "plan", "--scope", "system", "--name", "second-install") == 0  # a different name is independent


# -- warnings (plan still succeeds) ----------------------------------------------------------------------


def test_plan_warns_when_the_machine_is_not_linux_but_still_plans(tmp_path):
    w = new_world(tmp_path, platform="win32", euid=None, home="/home/alice")
    assert run(w, "plan", "--scope", "system") == 0
    assert "not Linux" in w.cap.stdout and "/opt/hermes-surfaces" in w.cap.stdout


def test_plan_warns_about_a_missing_root(tmp_path):
    w = new_world(tmp_path, euid=1000)
    assert run(w, "plan", "--scope", "system") == 0
    assert "needs root" in w.cap.stdout


def test_default_scope_follows_the_user(tmp_path):
    root = new_world(tmp_path / "a", euid=0)
    user = new_world(tmp_path / "b", euid=1000, home="/home/bob")
    run(root, "plan")
    run(user, "plan")
    assert "name / scope   hermes-surfaces / system" in root.cap.stdout
    assert "name / scope   hermes-surfaces / user" in user.cap.stdout
    assert "/home/bob/.local/share/hermes-surfaces" in user.cap.stdout


def test_plan_warns_loudly_about_a_public_bind_and_keeps_mcp_on_loopback(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "plan", "--scope", "system", "--host", "0.0.0.0") == 0
    out = w.cap.stdout
    assert "NOT loopback" in out and "plain HTTP" in out and "SSH tunnel or VPN" in out
    assert "author MCP     127.0.0.1:8788  (always loopback)" in out
    unit = [s.action.text for s in _steps(w, "--host", "0.0.0.0") if s.action.describe().startswith("write") and s.action.path.suffix == ".service"][0]
    assert "--mcp-host 127.0.0.1" in unit and "--host 0.0.0.0" in unit


def _steps(world, *args):
    from mobile_surfaces.install.cli import build_parser, resolve_options
    from mobile_surfaces.install.plan import plan_install

    parsed = build_parser().parse_args(["plan", "--scope", "system", *args])
    return plan_install(resolve_options(parsed, world.deps), world.deps).steps


def test_loopback_hosts_get_no_warning(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system", "--host", "127.0.0.1")
    assert "NOT loopback" not in w.cap.stdout and "plain HTTP" not in w.cap.stdout.split("Notes:")[0]


def test_plan_warns_when_node_is_unreadable_for_the_sandboxed_unit(tmp_path):
    w = new_world(tmp_path, realpath={"/usr/bin/node": "/root/.nvm/versions/node/v22/bin/node"})
    assert run(w, "plan", "--scope", "system", "--with-authoring") == 0
    assert "cannot read (ProtectHome=yes)" in w.cap.stdout and "--copy-node" in w.cap.stdout


def test_plan_warns_when_memory_is_below_the_build_floor(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system", "--with-authoring", "--memory-max", "256M")
    assert "below 450M" in w.cap.stdout
    w.cap.out.clear()
    run(w, "plan", "--scope", "system", "--with-authoring", "--limits", "small")
    assert "below 450M" not in w.cap.stdout


def test_plan_explains_authoring_is_off_by_default(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    assert "interface authoring is off" in w.cap.stdout
    assert "templates/starter-app" not in "\n".join(l for l in w.cap.out if l.startswith("  create"))


def test_plan_shows_the_hermes_snippets_and_says_they_are_not_applied(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    out = w.cap.stdout
    assert "NOT applied" in out and "mcp_servers:" in out and "API_SERVER_ENABLED=true" in out
    assert "Authorization: \"Bearer ${MOBILE_SURFACES_MCP_TOKEN}\"" in out
    assert "external_dirs" in out and "/opt/hermes-surfaces/skills" in out
    assert "$(cat /etc/hermes-surfaces/mcp-token)" in out  # the path, never the value


def test_usage_errors_are_exit_2(tmp_path, capsys):
    w = new_world(tmp_path)
    for bad in (["plan", "--scope", "bogus"], ["frobnicate"], ["plan", "--api-port", "notanumber"], ["plan", "--limits", "huge"]):
        with pytest.raises(SystemExit) as exc:
            main(bad, deps=w.deps)
        assert exc.value.code == 2
    capsys.readouterr()


@pytest.mark.parametrize("args", [
    ["--name", "Bad Name"], ["--prefix", "relative/dir"], ["--host", "a b"], ["--api-port", "80"],
    ["--api-port", "9000", "--mcp-port", "9000"], ["--memory-max", "lots"], ["--hermes-user", "Bad User"],
    ["--hermes-home", "/tmp/a b"], ["--user-sandbox"], ["--copy-node"], ["--rotate-tokens"],
])
def test_invalid_requests_are_refused_with_exit_3_before_anything_happens(tmp_path, args):
    w = new_world(tmp_path)
    assert run(w, "plan", "--scope", "system", *args) == 3
    assert w.fs.ops == [] and w.cap.stderr.startswith("error:")
