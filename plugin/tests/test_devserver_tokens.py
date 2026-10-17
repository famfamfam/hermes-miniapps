"""devserver: tokens from files or systemd credentials (how the installed service gets them) and --no-authoring.

The existing behaviour (`load_token`, default dev tokens printed on the console) is covered by test_mcp.py and
is deliberately unchanged; these tests cover only the additions.
"""
from __future__ import annotations

import sys

import pytest

import devserver

GOOD_API = "A" * 20 + "api-token-value-xxxxx"
GOOD_MCP = "B" * 20 + "mcp-token-value-xxxxx"


def write(path, text):
    path.write_text(text, encoding="utf-8")
    return str(path)


def test_read_token_file_strips_whitespace(tmp_path):
    assert devserver.read_token_file(write(tmp_path / "t", f"  {GOOD_API}\n")) == GOOD_API


def test_read_token_file_never_creates_anything(tmp_path):
    with pytest.raises(SystemExit) as exc:
        devserver.read_token_file(str(tmp_path / "absent"))
    assert "cannot read token file" in str(exc.value) and not (tmp_path / "absent").exists()


def test_read_token_file_refuses_a_short_value_without_echoing_it(tmp_path):
    with pytest.raises(SystemExit) as exc:
        devserver.read_token_file(write(tmp_path / "t", "hunter2hunter2\n"))
    assert "fewer than 24 characters" in str(exc.value) and "hunter2" not in str(exc.value)
    with pytest.raises(SystemExit):
        devserver.read_token_file(write(tmp_path / "empty", ""))


def test_credential_form_reads_from_the_credentials_directory(tmp_path):
    (tmp_path / "api-token").write_text(GOOD_API + "\n", encoding="utf-8")
    env = {"CREDENTIALS_DIRECTORY": str(tmp_path)}
    assert devserver.read_token_file("credential:api-token", env) == GOOD_API


@pytest.mark.parametrize("spec", ["credential:../x", "credential:", "credential:a/b", "credential:.hidden", "credential:a\\b"])
def test_credential_names_cannot_escape_the_directory(tmp_path, spec):
    (tmp_path / "x").write_text(GOOD_API, encoding="utf-8")
    with pytest.raises(SystemExit, match="not a valid credential name"):
        devserver.read_token_file(spec, {"CREDENTIALS_DIRECTORY": str(tmp_path / "sub")})


def test_credential_form_without_systemd_is_a_clear_error():
    with pytest.raises(SystemExit, match="CREDENTIALS_DIRECTORY"):
        devserver.read_token_file("credential:api-token", {})


def test_a_missing_credential_does_not_reveal_the_directory_contents(tmp_path):
    with pytest.raises(SystemExit) as exc:
        devserver.read_token_file("credential:api-token", {"CREDENTIALS_DIRECTORY": str(tmp_path)})
    assert "cannot read token file credential:api-token" in str(exc.value)


# -- main(): what the service prints and which listeners it starts --------------------------------------------


class Started:
    """Replaces uvicorn so that main() can be run without opening sockets."""

    def __init__(self) -> None:
        self.configs: list[dict] = []
        self.runs: list[dict] = []


@pytest.fixture
def run_main(monkeypatch, tmp_path, capsys):
    started = Started()

    class FakeServer:
        def __init__(self, config):
            started.configs.append(config)

        def run(self):
            return None

    monkeypatch.setattr(devserver.uvicorn, "Config", lambda app, **kw: kw)
    monkeypatch.setattr(devserver.uvicorn, "Server", FakeServer)
    monkeypatch.setattr(devserver.uvicorn, "run", lambda app, **kw: started.runs.append(kw))

    def go(*args: str):
        monkeypatch.setattr(sys, "argv", ["devserver", "--home", str(tmp_path / "home"), *args])
        devserver.main()
        return capsys.readouterr().out, started

    return go


def test_token_files_are_used_and_never_printed(run_main, tmp_path):
    api, mcp = write(tmp_path / "api", GOOD_API), write(tmp_path / "mcp", GOOD_MCP)
    out, started = run_main("--token-file", api, "--mcp-token-file", mcp, "--no-authoring")
    assert GOOD_API not in out and GOOD_MCP not in out
    assert f"token: from {api}" in out and f"token: from {mcp}" in out
    assert "interface tools OFF: disabled with --no-authoring" in out
    assert not (tmp_path / "home" / "dev-token").exists() and not (tmp_path / "home" / "mcp-token").exists()  # nothing auto-created
    assert started.runs[0]["host"] == "127.0.0.1" and started.configs[0]["host"] == "127.0.0.1"


def test_credentials_are_used_the_same_way(run_main, tmp_path, monkeypatch):
    creds = tmp_path / "creds"
    creds.mkdir()
    (creds / "api-token").write_text(GOOD_API, encoding="utf-8")
    (creds / "mcp-token").write_text(GOOD_MCP, encoding="utf-8")
    monkeypatch.setenv("CREDENTIALS_DIRECTORY", str(creds))
    out, _ = run_main("--token-file", "credential:api-token", "--mcp-token-file", "credential:mcp-token", "--no-authoring")
    assert "from credential:api-token" in out and str(creds) not in out and GOOD_API not in out


def test_the_default_dev_mode_is_unchanged_and_still_prints_its_tokens(run_main, tmp_path):
    out, _ = run_main("--no-authoring")
    dev = (tmp_path / "home" / "dev-token").read_text(encoding="utf-8").strip()
    assert f"token: {dev}" in out  # documented dev behaviour (README: the console shows the token)


def test_token_file_requires_the_mcp_token_file(run_main, tmp_path, capsys):
    with pytest.raises(SystemExit) as exc:
        run_main("--token-file", write(tmp_path / "api", GOOD_API))
    assert exc.value.code == 2
    assert "--mcp-token-file" in capsys.readouterr().err
    with pytest.raises(SystemExit) as exc:
        run_main("--mcp-token-file", write(tmp_path / "m", GOOD_MCP))
    assert exc.value.code == 2


def test_the_two_tokens_must_differ(run_main, tmp_path):
    same = write(tmp_path / "same", GOOD_API)
    with pytest.raises(SystemExit, match="must differ"):
        run_main("--token-file", same, "--mcp-token-file", same)


def test_no_mcp_needs_only_the_phone_token(run_main, tmp_path):
    out, started = run_main("--token-file", write(tmp_path / "api", GOOD_API), "--no-mcp")
    assert "MCP " not in out and started.configs == [] and len(started.runs) == 1


def test_the_service_never_bakes_a_demo_or_seed_into_startup():
    """The installed unit has no ExecStartPre, and the server itself never seeds apps on startup."""
    source = open(devserver.__file__, encoding="utf-8").read()
    assert "seed" not in source.lower().replace("secrets.token", "")
    assert "create_app" not in source
