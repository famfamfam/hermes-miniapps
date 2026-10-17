"""Installer: status and uninstall (the end of the lifecycle), including the loopback-only probes."""
from __future__ import annotations

import http.server
import threading
from pathlib import PurePosixPath

import pytest
from install_support import new_world

from mobile_surfaces.install.cli import main
from mobile_surfaces.install.effects import Fs, RunResult, http_status
from mobile_surfaces.install.model import InstallError

P = PurePosixPath
UNIT = "/etc/systemd/system/hermes-surfaces.service"
API_HEALTH = "http://127.0.0.1:8787/api/plugins/mobile-surfaces/v1/health"
MCP_URL = "http://127.0.0.1:8788/mcp"


def run(world, *args):
    return main(list(args), deps=world.deps)


def installed(tmp_path, *args, **kwargs):
    w = new_world(tmp_path, **kwargs)
    assert run(w, "apply", "--scope", "system", *args) == 0, w.cap.stderr
    w.cap.out.clear(); w.cap.err.clear(); w.fs.clear_ops(); w.runner.calls.clear()
    return w


# -- status ----------------------------------------------------------------------------------------------


def test_status_of_nothing_is_exit_4_with_a_hint(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "status", "--scope", "system") == 4
    assert "not installed" in w.cap.stdout and "--scope user" in w.cap.stdout


def test_status_of_a_healthy_install_is_exit_0_and_shows_no_secret(tmp_path):
    w = installed(tmp_path, "--with-authoring")
    assert run(w, "status", "--scope", "system") == 0, w.cap.stdout
    out = w.cap.stdout
    assert "installed" in out and "(matches)" in out and "authoring      on" in out
    assert "/etc/hermes-surfaces/api-token" in out and "/etc/hermes-surfaces/mcp-token" in out
    assert all(t not in w.cap.everything for t in w.tokens)
    assert w.fs.ops == []  # status only reads


def test_status_uses_the_recorded_options_not_the_defaults(tmp_path):
    w = installed(tmp_path, "--api-port", "9100", "--mcp-port", "9101", "--limits", "small")
    assert run(w, "status", "--scope", "system") == 0
    assert "127.0.0.1:9100" in w.cap.stdout and "127.0.0.1:9101/mcp" in w.cap.stdout


def test_status_detects_a_hand_edited_unit(tmp_path):
    w = installed(tmp_path)
    w.put(UNIT, w.read(UNIT).replace("Restart=on-failure", "Restart=always"))
    assert run(w, "status", "--scope", "system") == 5
    assert "differs from what the installer renders" in w.cap.stdout


def test_status_detects_loose_or_missing_token_files(tmp_path):
    w = installed(tmp_path)
    w.fs.modes[P("/etc/hermes-surfaces/api-token")] = 0o644
    assert run(w, "status", "--scope", "system") == 5
    assert "accessible to others (mode 0644)" in w.cap.stdout
    w.fs.modes[P("/etc/hermes-surfaces/api-token")] = 0o600
    w.fs.real(P("/etc/hermes-surfaces/mcp-token")).unlink()
    w.cap.out.clear()
    assert run(w, "status", "--scope", "system") == 5 and "MCP token file" in w.cap.stdout


def test_status_detects_a_missing_dropin_and_a_missing_venv(tmp_path):
    w = installed(tmp_path, "--limits", "small")
    w.fs.real(P(UNIT + ".d/resources.conf")).unlink()
    w.fs.real(P("/opt/hermes-surfaces/venv/bin/python")).unlink()
    assert run(w, "status", "--scope", "system") == 5
    assert "drop-in" in w.cap.stdout and "virtualenv python" in w.cap.stdout


def test_status_reports_systemd_state_and_a_failed_service(tmp_path):
    def responder(argv):
        if "is-active" in argv:
            return RunResult(3, "failed\n")
        if "is-enabled" in argv:
            return RunResult(0, "enabled\n")
        return None

    w = installed(tmp_path, responder=responder)
    assert run(w, "status", "--scope", "system") == 5
    assert "failed, enabled" in w.cap.stdout and "the service has failed" in w.cap.stdout


def test_status_asks_systemd_with_the_right_scope(tmp_path):
    w = installed(tmp_path)
    run(w, "status", "--scope", "system")
    assert [c.argv for c in w.runner.calls if c.argv[0] == "systemctl"][0][:2] == ("systemctl", "is-active")
    u = new_world(tmp_path / "u", euid=1000)
    assert run(u, "apply", "--scope", "user") == 0
    u.runner.calls.clear()
    run(u, "status", "--scope", "user")
    assert all(c.argv[:2] == ("systemctl", "--user") for c in u.runner.calls if c.argv[0] == "systemctl")


def test_status_in_a_staging_root_does_not_pretend_to_know_systemd(tmp_path):
    w = new_world(tmp_path, platform="win32", euid=None, staging=True)
    assert run(w, "apply", "--scope", "system", "--root", str(w.root)) == 0
    assert run(w, "status", "--scope", "system", "--health") == 0
    assert "not checked" in w.cap.stdout and w.http_requests == []


def test_print_token_path_prints_only_the_path(tmp_path):
    w = installed(tmp_path)
    assert run(w, "status", "--scope", "system", "--print-token-path", "api") == 0
    assert w.cap.out == ["/etc/hermes-surfaces/api-token"]
    w.cap.out.clear()
    assert run(w, "status", "--scope", "system", "--print-token-path", "mcp") == 0
    assert w.cap.out == ["/etc/hermes-surfaces/mcp-token"]


def test_print_token_path_of_nothing_is_an_error_without_output(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "status", "--scope", "system", "--print-token-path", "api") == 4
    assert w.cap.out == [] and "not installed" in w.cap.stderr


def test_print_token_path_belongs_to_status_only(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "plan", "--print-token-path", "api") == 2


# -- health probes ----------------------------------------------------------------------------------------


def test_health_probes_loopback_with_the_tokens_from_their_files(tmp_path):
    w = installed(tmp_path)
    assert run(w, "status", "--scope", "system", "--health") == 0, w.cap.stdout
    urls = {url: headers for url, headers in w.http_requests}
    assert set(urls) == {API_HEALTH, MCP_URL}
    assert urls[API_HEALTH] == {"Authorization": f"Bearer {w.tokens[0]}"}
    assert urls[MCP_URL] == {"Authorization": f"Bearer {w.tokens[1]}"}
    assert all(t not in w.cap.everything for t in w.tokens)  # sent, never printed
    assert "phone API /health: 200" in w.cap.stdout and "token accepted" in w.cap.stdout


@pytest.mark.parametrize("answers,fragment", [
    ({API_HEALTH: 401}, "phone API did not answer 200"),
    ({API_HEALTH: None}, "phone API did not answer 200"),
    ({MCP_URL: 401}, "rejected its own token"),
    ({MCP_URL: None}, "did not answer"),
])
def test_health_problems_make_status_degraded(tmp_path, answers, fragment):
    w = installed(tmp_path)
    w.http.update(answers)
    assert run(w, "status", "--scope", "system", "--health") == 5
    assert fragment in w.cap.stdout


def test_health_mcp_405_still_means_the_token_was_accepted(tmp_path):
    w = installed(tmp_path)
    w.http[MCP_URL] = 405
    assert run(w, "status", "--scope", "system", "--health") == 0


def test_health_never_probes_a_public_address_and_uses_loopback_for_wildcards(tmp_path):
    wild = installed(tmp_path / "a", "--host", "0.0.0.0")
    assert run(wild, "status", "--scope", "system", "--health") == 0
    assert API_HEALTH in {u for u, _ in wild.http_requests}  # reached through loopback
    public = installed(tmp_path / "b", "--host", "10.0.0.5")
    assert run(public, "status", "--scope", "system", "--health") == 0
    assert all("10.0.0.5" not in u for u, _ in public.http_requests)
    assert "not probed" in public.cap.stdout


def test_the_real_probe_refuses_anything_but_loopback():
    for url in ("http://example.org/", "http://10.1.2.3:8787/", "https://127.0.0.1/", "http://0.0.0.0:8787/x", "http://[2001:db8::1]:8/x"):
        with pytest.raises(ValueError):
            http_status(url, {"Authorization": "Bearer x"})


def test_the_real_probe_reads_status_codes_and_never_follows_redirects():
    seen: list[str] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            seen.append(self.headers.get("Authorization", ""))
            if self.path == "/ok":
                self.send_response(200)
            elif self.path == "/denied":
                self.send_response(401)
            else:
                self.send_response(302)
                self.send_header("Location", "http://example.invalid/stolen")
            self.end_headers()

        def log_message(self, *args):  # noqa: ANN002
            pass

    server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        base = f"http://127.0.0.1:{server.server_address[1]}"
        assert http_status(base + "/ok", {"Authorization": "Bearer t"}) == 200
        assert http_status(base + "/denied", {}) == 401
        assert http_status(base + "/redirect", {"Authorization": "Bearer t"}) == 302  # reported, not followed
    finally:
        server.shutdown()
        server.server_close()
    assert http_status("http://127.0.0.1:1/", {}) is None  # nothing listens


# -- uninstall --------------------------------------------------------------------------------------------


def test_uninstall_removes_the_service_and_code_but_keeps_data_and_tokens(tmp_path):
    w = installed(tmp_path, "--limits", "small")
    w.put("/var/lib/hermes-surfaces/mobile-surfaces/registry.db", "precious")
    assert run(w, "uninstall", "--scope", "system") == 0, w.cap.stderr
    assert not w.exists(UNIT) and not w.exists(UNIT + ".d") and not w.exists("/opt/hermes-surfaces")
    assert w.read("/var/lib/hermes-surfaces/mobile-surfaces/registry.db") == "precious"
    assert w.exists("/etc/hermes-surfaces/api-token") and w.exists("/etc/hermes-surfaces/mcp-token")
    assert "kept:" in w.cap.stdout and "--reuse-data" in w.cap.stdout
    assert w.runner.systemctl_verbs() == ["stop", "disable", "daemon-reload"]
    stop = next(i for i, e in enumerate(w.events) if e[0] == "run" and "stop" in e[1])
    gone = next(i for i, e in enumerate(w.events) if e[:3] == ("fs", "remove", P(UNIT)))
    assert stop < gone


def test_uninstall_dry_run_changes_nothing(tmp_path):
    w = installed(tmp_path)
    before = sorted(p for p in w.root.rglob("*"))
    assert run(w, "uninstall", "--scope", "system", "--dry-run") == 0
    assert w.cap.stdout.startswith("PLAN: uninstall") and w.fs.ops == [] and sorted(w.root.rglob("*")) == before
    assert not [c for c in w.runner.calls if c.argv[0] == "systemctl"]


def test_purge_needs_yes(tmp_path):
    w = installed(tmp_path)
    assert run(w, "uninstall", "--scope", "system", "--purge") == 3
    assert "--yes" in w.cap.stdout and w.exists("/opt/hermes-surfaces") and w.fs.ops == []


def test_purge_removes_state_tokens_and_the_dynamic_users_private_copy(tmp_path):
    w = installed(tmp_path)
    w.put("/var/lib/hermes-surfaces/x.db", "data")
    w.put("/var/lib/private/hermes-surfaces/x.db", "data")
    assert run(w, "uninstall", "--scope", "system", "--purge", "--yes") == 0
    for path in ("/var/lib/hermes-surfaces", "/var/lib/private/hermes-surfaces", "/etc/hermes-surfaces", "/opt/hermes-surfaces", UNIT):
        assert not w.exists(path), path


def test_uninstall_of_nothing_is_exit_4(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "uninstall", "--scope", "system") == 4
    assert run(w, "uninstall", "--scope", "system", "--dry-run") == 4


def test_uninstall_refuses_to_delete_what_it_did_not_install(tmp_path):
    w = new_world(tmp_path)
    w.put(UNIT, "# not ours\n")
    w.put("/opt/hermes-surfaces/precious.txt", "keep me")
    assert run(w, "uninstall", "--scope", "system") == 3
    assert "no install record" in w.cap.stdout
    assert w.exists(UNIT) and w.exists("/opt/hermes-surfaces/precious.txt") and w.fs.ops == []


def test_uninstall_refuses_a_record_of_another_name_or_other_paths(tmp_path):
    w = installed(tmp_path)
    w.put("/opt/hermes-surfaces/install.json", w.read("/opt/hermes-surfaces/install.json").replace('"/etc/hermes-surfaces"', '"/etc/elsewhere"'))
    assert run(w, "uninstall", "--scope", "system") == 3
    assert "different paths" in w.cap.stdout and w.exists("/opt/hermes-surfaces")


def test_uninstall_leaves_an_admins_other_dropins_alone(tmp_path):
    w = installed(tmp_path, "--limits", "small")
    w.put(UNIT + ".d/zz-local.conf", "[Service]\nNice=5\n")
    assert run(w, "uninstall", "--scope", "system") == 0
    assert not w.exists(UNIT + ".d/resources.conf") and w.read(UNIT + ".d/zz-local.conf") == "[Service]\nNice=5\n"


def test_reinstall_after_uninstall_needs_reuse_data_and_keeps_the_tokens(tmp_path):
    w = installed(tmp_path)
    tokens = (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token"))
    assert run(w, "uninstall", "--scope", "system") == 0
    assert run(w, "apply", "--scope", "system") == 3
    assert run(w, "apply", "--scope", "system", "--reuse-data") == 0
    assert (w.read("/etc/hermes-surfaces/api-token"), w.read("/etc/hermes-surfaces/mcp-token")) == tokens
    assert len(w.tokens) == 2  # nothing new was generated


def test_status_after_uninstall_is_not_installed(tmp_path):
    w = installed(tmp_path)
    assert run(w, "uninstall", "--scope", "system") == 0
    assert run(w, "status", "--scope", "system") == 4
    assert "exist without an install record" in w.cap.stdout


def test_uninstall_does_not_touch_hermes_unless_asked(tmp_path):
    w = installed(tmp_path)
    w.put("/home/alice/.hermes/config.yaml", "mcp_servers:\n  other: {}\n")
    assert run(w, "uninstall", "--scope", "system") == 0
    assert w.read("/home/alice/.hermes/config.yaml") == "mcp_servers:\n  other: {}\n"
    assert "Hermes was not touched" in w.cap.stdout


def test_user_scope_uninstall_uses_the_user_manager(tmp_path):
    w = new_world(tmp_path, euid=1000, home="/home/bob")
    assert run(w, "apply", "--scope", "user") == 0
    w.runner.calls.clear()
    assert run(w, "uninstall", "--scope", "user") == 0
    assert all(c.argv[:2] == ("systemctl", "--user") for c in w.runner.calls if c.argv[0] == "systemctl")
    assert not w.exists("/home/bob/.local/share/hermes-surfaces")
    assert w.exists("/home/bob/.config/hermes-surfaces/api-token")


def test_uninstall_with_a_custom_name_leaves_the_other_install_alone(tmp_path):
    w = installed(tmp_path)
    assert run(w, "apply", "--scope", "system", "--name", "second", "--api-port", "9300", "--mcp-port", "9301") == 0
    assert run(w, "uninstall", "--scope", "system", "--name", "second", "--purge", "--yes") == 0
    assert w.exists(UNIT) and w.exists("/etc/hermes-surfaces/api-token")
    assert not w.exists("/etc/systemd/system/second.service") and not w.exists("/etc/second")


# -- the filesystem layer's own guards ---------------------------------------------------------------------


def test_fs_remove_refuses_paths_near_the_root(tmp_path):
    fs = Fs(tmp_path)
    (tmp_path / "opt").mkdir()
    for shallow in ("/", "/opt", "/etc"):
        with pytest.raises(InstallError, match="too close"):
            fs.remove(P(shallow))
    assert (tmp_path / "opt").is_dir()
