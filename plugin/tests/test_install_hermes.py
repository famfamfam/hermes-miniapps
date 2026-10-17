"""Installer: what it tells Hermes, and the opt-in, backed-up, idempotent edit of Hermes' own files."""
from __future__ import annotations

from pathlib import PurePosixPath

import pytest
from install_support import new_world

from mobile_surfaces.install import hermes
from mobile_surfaces.install.cli import main
from mobile_surfaces.install.hermes import ConfigConflict, remove_env, remove_mcp_entry, upsert_env, upsert_mcp_entry

P = PurePosixPath
ENV_AUTH = "Bearer ${MOBILE_SURFACES_MCP_TOKEN}"
CONFIG = "/home/alice/.hermes/config.yaml"
ENV_FILE = "/home/alice/.hermes/.env"

EXISTING = """\
# my hermes config
model:
  default: some/model   # keep this comment

mcp_servers:
  # the weather server
  weather:
    command: "weather-mcp"
    args: ["--fast"]
  notes:
    url: "https://notes.example/mcp"

skills:
  external_dirs: []
"""


def yaml_of(text):
    yaml = pytest.importorskip("yaml")
    return yaml.safe_load(text)


def run(world, *args):
    return main(list(args), deps=world.deps)


# -- the snippets ------------------------------------------------------------------------------------------


def test_snippets_use_the_token_by_reference_and_never_contain_a_value(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    out = w.cap.stdout
    assert 'Authorization: "Bearer ${MOBILE_SURFACES_MCP_TOKEN}"' in out
    assert "trust: untrusted" in out and "timeout: 180" in out and 'url: "http://127.0.0.1:8788/mcp"' in out
    assert "(the value is not printed)" in out
    w2 = new_world(tmp_path / "inline")
    run(w2, "plan", "--scope", "system", "--hermes-token-mode", "inline")
    assert "<paste the contents of /etc/hermes-surfaces/mcp-token>" in w2.cap.stdout
    assert "MOBILE_SURFACES_MCP_TOKEN" not in w2.cap.stdout


def test_snippets_follow_ports_name_and_hermes_home(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system", "--mcp-port", "9101", "--api-port", "9100", "--mcp-name", "phone", "--hermes-home", "/srv/hermes")
    out = w.cap.stdout
    assert 'url: "http://127.0.0.1:9101/mcp"' in out and "phone:" in out and "/srv/hermes/config.yaml" in out
    assert "hermes mcp test phone" in out


def test_pairing_comes_before_connecting_hermes_and_the_installer_never_pairs(tmp_path):
    """Without a paired approver the agent's app_publish goes live unreviewed (ADR-006), so say so first."""
    w = new_world(tmp_path)
    w.put(CONFIG, EXISTING)
    run(w, "plan", "--scope", "system")
    out = w.cap.stdout
    assert "FIRST pair your phone as the approver" in out and "WITHOUT review" in out
    assert out.index("FIRST pair") < out.index("1. MCP server")
    w.cap.out.clear()
    run(w, "plan", "--scope", "system", "--write-hermes-config")
    assert "pair the phone as the approver BEFORE Hermes connects" in w.cap.stdout
    assert {c.argv[0] for c in w.runner.calls} == {"git"}  # a plan runs one read-only command, and pairs nothing


def test_the_pairing_hint_names_the_exact_command_for_this_install(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    default = w.cap.stdout
    assert "sudo /opt/hermes-surfaces/venv/bin/python -I -m ms_admin pair-code" in default
    assert "--token-file /etc/hermes-surfaces/api-token" in default
    assert "--api-url" not in default, "the default port needs no --api-url"
    assert "Paste connection code" in default
    assert "/etc/hermes-surfaces/public-url" in default
    w.cap.out.clear()
    # A second copy on other ports, as on a host that already runs something on 8787: the command must reach THIS one.
    run(w, "plan", "--scope", "system", "--name", "other-copy", "--api-port", "18787", "--mcp-port", "18788")
    other = w.cap.stdout
    assert "/opt/other-copy/venv/bin/python -I -m ms_admin pair-code" in other
    assert "--token-file /etc/other-copy/api-token --api-url http://127.0.0.1:18787" in other
    w.cap.out.clear()
    run(w, "plan", "--scope", "system", "--host", "::1")
    assert "--api-url http://[::1]:8787" in w.cap.stdout


def test_the_api_server_snippet_has_a_placeholder_key_and_a_warning(tmp_path):
    w = new_world(tmp_path)
    run(w, "plan", "--scope", "system")
    out = w.cap.stdout
    assert "API_SERVER_ENABLED=true" in out and "API_SERVER_HOST=127.0.0.1" in out and "API_SERVER_PORT=8642" in out
    assert "API_SERVER_KEY=<your own long random key" in out
    assert "exposes all agent tools" in out and "SSH tunnel or VPN" in out


# -- editing config.yaml -----------------------------------------------------------------------------------


def test_adding_to_an_empty_file():
    text, state = upsert_mcp_entry("", "surfaces", 8788, ENV_AUTH)
    assert state == "added" and text.startswith("mcp_servers:\n  # >>> mobile-surfaces:surfaces")
    assert text.endswith("# <<< mobile-surfaces:surfaces <<<\n")
    parsed = yaml_of(text)
    assert parsed["mcp_servers"]["surfaces"] == {
        "url": "http://127.0.0.1:8788/mcp", "trust": "untrusted", "timeout": 180,
        "headers": {"Authorization": ENV_AUTH},
    }


def test_adding_to_a_file_without_the_key_keeps_everything_else():
    original = "model:\n  default: x\n# trailing comment\n"
    text, state = upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)
    assert state == "added" and text.startswith(original + "\nmcp_servers:\n")
    assert yaml_of(text)["model"] == {"default": "x"}


def test_adding_next_to_other_servers_preserves_the_rest_byte_for_byte():
    text, state = upsert_mcp_entry(EXISTING, "surfaces", 8788, ENV_AUTH)
    assert state == "added"
    removed, state = remove_mcp_entry(text, "surfaces")
    assert state == "removed" and removed == EXISTING  # a full round trip: nothing else was touched
    parsed = yaml_of(text)
    assert set(parsed["mcp_servers"]) == {"weather", "notes", "surfaces"}
    assert parsed["skills"] == {"external_dirs": []} and parsed["model"]["default"] == "some/model"
    assert "# keep this comment" in text and "# the weather server" in text
    # inserted inside the mcp_servers block, before the next top-level key
    assert text.index("mobile-surfaces:surfaces (managed") < text.index("\nskills:")


def test_the_indentation_of_the_existing_block_is_followed():
    original = "mcp_servers:\n    a:\n        url: \"http://a\"\nother: 1\n"
    text, _ = upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)
    assert "\n    surfaces:\n" in text
    parsed = yaml_of(text)
    assert set(parsed["mcp_servers"]) == {"a", "surfaces"} and parsed["other"] == 1


def test_upsert_is_idempotent():
    once, _ = upsert_mcp_entry(EXISTING, "surfaces", 8788, ENV_AUTH)
    twice, state = upsert_mcp_entry(once, "surfaces", 8788, ENV_AUTH)
    assert state == "unchanged" and twice == once


def test_changed_values_update_only_the_managed_block():
    once, _ = upsert_mcp_entry(EXISTING, "surfaces", 8788, ENV_AUTH)
    changed, state = upsert_mcp_entry(once, "surfaces", 9999, ENV_AUTH)
    assert state == "updated" and "9999/mcp" in changed and "8788" not in changed
    assert changed.replace("9999", "8788") == once
    assert changed.count("mobile-surfaces:surfaces (managed") == 1


def test_two_names_coexist():
    one, _ = upsert_mcp_entry(EXISTING, "surfaces", 8788, ENV_AUTH)
    two, state = upsert_mcp_entry(one, "other", 9000, ENV_AUTH)
    assert state == "added" and set(yaml_of(two)["mcp_servers"]) == {"weather", "notes", "surfaces", "other"}
    assert remove_mcp_entry(two, "other")[0] == one


def test_removing_the_only_entry_takes_the_key_the_installer_added_with_it():
    for original in ("model: x\n", "", "model: x\nskills: {}\n"):
        added, state = upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)
        assert state == "added"
        removed, state = remove_mcp_entry(added, "surfaces")
        assert state == "removed"
        assert removed == original, repr(removed)
        assert "mcp_servers" not in removed  # not even a null key a client could trip over


def test_removal_keeps_a_key_that_still_has_other_servers():
    text, _ = upsert_mcp_entry("mcp_servers:\n  weather:\n    url: x\n", "surfaces", 8788, ENV_AUTH)
    removed, _ = remove_mcp_entry(text, "surfaces")
    assert removed == "mcp_servers:\n  weather:\n    url: x\n"


def test_crlf_files_stay_crlf():
    original = EXISTING.replace("\n", "\r\n")
    text, _ = upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)
    assert "\r\n" in text and "\n" not in text.replace("\r\n", "")
    assert remove_mcp_entry(text, "surfaces")[0] == original


def test_an_unmanaged_entry_with_the_same_name_is_a_conflict_not_an_overwrite():
    original = "mcp_servers:\n  surfaces:\n    url: \"http://mine\"\n"
    with pytest.raises(ConfigConflict, match="did not create"):
        upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)


@pytest.mark.parametrize("original,fragment", [
    ("mcp_servers: {}\n", "written inline"),
    ("mcp_servers: null\n", "written inline"),
    ("mcp_servers:\n\ta:\n\t\turl: x\n", "tabs"),
    ("mcp_servers:\n  # >>> mobile-surfaces:surfaces (managed by mobile_surfaces.install; edit outside the markers) >>>\n  surfaces:\n    url: x\n", "end marker"),
])
def test_files_that_cannot_be_edited_safely_are_refused(original, fragment):
    with pytest.raises(ConfigConflict, match=fragment):
        upsert_mcp_entry(original, "surfaces", 8788, ENV_AUTH)


def test_removing_what_is_not_there_is_a_no_op():
    assert remove_mcp_entry(EXISTING, "surfaces") == (EXISTING, "absent")
    assert remove_mcp_entry("", "surfaces") == ("", "absent")
    assert remove_mcp_entry("mcp_servers:\n  surfaces:\n    url: x\n", "surfaces")[1] == "absent"  # not ours: left alone


def test_the_inline_token_mode_embeds_the_header_value_you_pass():
    text, _ = upsert_mcp_entry("", "surfaces", 8788, "Bearer abc123")
    assert yaml_of(text)["mcp_servers"]["surfaces"]["headers"]["Authorization"] == "Bearer abc123"


# -- editing .env ------------------------------------------------------------------------------------------


def test_env_add_update_and_dedupe():
    text, state = upsert_env("A=1\n# note\n", "MOBILE_SURFACES_MCP_TOKEN", "tok")
    assert (text, state) == ("A=1\n# note\nMOBILE_SURFACES_MCP_TOKEN=tok\n", "added")
    assert upsert_env(text, "MOBILE_SURFACES_MCP_TOKEN", "tok") == (text, "unchanged")
    new, state = upsert_env(text, "MOBILE_SURFACES_MCP_TOKEN", "tok2")
    assert state == "updated" and new == "A=1\n# note\nMOBILE_SURFACES_MCP_TOKEN=tok2\n"
    dup, state = upsert_env("X=1\nexport MOBILE_SURFACES_MCP_TOKEN=a\nMOBILE_SURFACES_MCP_TOKEN=b\n", "MOBILE_SURFACES_MCP_TOKEN", "c")
    assert state == "updated" and dup == "X=1\nMOBILE_SURFACES_MCP_TOKEN=c\n"


def test_env_keeps_other_lines_and_line_endings():
    text, _ = upsert_env("A=1\r\nB=2", "K", "v")
    assert text == "A=1\r\nB=2\r\nK=v\r\n"
    assert upsert_env("", "K", "v") == ("K=v\n", "added")


def test_env_removal():
    assert remove_env("A=1\nK=v\nB=2\n", "K") == ("A=1\nB=2\n", "removed")
    assert remove_env("A=1\n", "K") == ("A=1\n", "absent")
    assert remove_env("KK=v\n", "K")[1] == "absent"  # a longer key with the same prefix is not ours


# -- --write-hermes-config end to end ----------------------------------------------------------------------


def hermes_world(tmp_path, **kwargs):
    w = new_world(tmp_path, **kwargs)
    w.put(CONFIG, EXISTING)
    w.put(ENV_FILE, "OPENROUTER_API_KEY=sk-or-abc\n")
    w.fs.modes[P(CONFIG)] = 0o640
    w.fs.modes[P(ENV_FILE)] = 0o600
    return w


def test_hermes_files_are_not_touched_without_the_flag(tmp_path):
    w = hermes_world(tmp_path)
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system") == 0
    assert w.read(CONFIG) == EXISTING and w.read(ENV_FILE) == "OPENROUTER_API_KEY=sk-or-abc\n"
    assert not [op for op in w.fs.ops if "/.hermes" in str(op[1])]
    assert "NOT applied" in w.cap.stdout


def test_write_hermes_config_edits_after_a_backup_and_never_prints_the_token(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0, w.cap.stderr
    mcp_token = w.tokens[1]
    config, env = w.read(CONFIG), w.read(ENV_FILE)
    assert yaml_of(config)["mcp_servers"]["surfaces"]["headers"]["Authorization"] == ENV_AUTH
    assert env == f"OPENROUTER_API_KEY=sk-or-abc\nMOBILE_SURFACES_MCP_TOKEN={mcp_token}\n"
    assert mcp_token not in config  # env mode: config.yaml refers to the variable only
    assert w.read(CONFIG + ".bak.surfaces.20260101-120000") == EXISTING
    assert w.read(ENV_FILE + ".bak.surfaces.20260101-120000") == "OPENROUTER_API_KEY=sk-or-abc\n"
    assert w.fs.modes[P(CONFIG)] == 0o640 and w.fs.modes[P(ENV_FILE)] == 0o600  # modes survive the edit
    assert w.fs.modes[P(CONFIG + ".bak.surfaces.20260101-120000")] == 0o640  # and so do the backups' modes
    assert all(t not in w.cap.everything for t in w.tokens)
    assert "written by --write-hermes-config" in w.cap.stdout


def test_hermes_files_and_their_backups_keep_their_owner(tmp_path):
    # Hermes runs as another user than root; the atomic replace must not hand its files to root.
    w = hermes_world(tmp_path)
    backup_suffix = ".bak.surfaces.20260101-120000"
    w.fs.fake_ids[P(CONFIG)] = (1001, 1002)
    w.fs.fake_ids[P(ENV_FILE)] = (1001, 1002)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0, w.cap.stderr
    for path in (CONFIG, ENV_FILE, CONFIG + backup_suffix, ENV_FILE + backup_suffix):
        assert w.fs.restored[P(path)] == (1001, 1002), path


def test_backup_is_made_before_the_edit(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    writes = [e[2] for e in w.events if e[:2] == ("fs", "write")]
    backup, edit = P(CONFIG + ".bak.surfaces.20260101-120000"), P(CONFIG)
    assert writes.index(backup) < len(writes) - 1 - writes[::-1].index(edit)


def test_rerunning_changes_nothing_and_makes_no_new_backup(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    snapshot = (w.read(CONFIG), w.read(ENV_FILE))
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--upgrade") == 0
    assert (w.read(CONFIG), w.read(ENV_FILE)) == snapshot and w.fs.ops == []
    assert sorted(p.name for p in w.fs.real(P("/home/alice/.hermes")).iterdir()).count("config.yaml.bak.surfaces.20260101-120000") == 1


def test_hermes_can_be_let_in_by_a_later_upgrade_after_the_phone_is_paired(tmp_path):
    """The install skill installs first, pairs the phone, and only then adds the Hermes entries (skills/surfaces-install)."""
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system") == 0
    assert w.read(CONFIG) == EXISTING and w.read(ENV_FILE) == "OPENROUTER_API_KEY=sk-or-abc\n"  # Hermes is untouched
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--upgrade") == 0
    config, env = w.read(CONFIG), w.read(ENV_FILE)
    assert config.count("mobile-surfaces:surfaces (managed") == 1 and "# keep this comment" in config
    assert env.startswith("OPENROUTER_API_KEY=sk-or-abc\n") and f"MOBILE_SURFACES_MCP_TOKEN={w.tokens[1]}" in env


def test_rotating_tokens_refreshes_the_hermes_env_line(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--upgrade", "--rotate-tokens") == 0
    assert w.read(ENV_FILE).splitlines()[-1] == f"MOBILE_SURFACES_MCP_TOKEN={w.tokens[3]}"
    assert w.tokens[1] not in w.read(ENV_FILE)
    assert (w.read(CONFIG)).count("mobile-surfaces:surfaces (managed") == 1


def test_inline_mode_puts_the_token_in_config_yaml_only(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--hermes-token-mode", "inline") == 0
    config = w.read(CONFIG)
    assert yaml_of(config)["mcp_servers"]["surfaces"]["headers"]["Authorization"] == f"Bearer {w.tokens[1]}"
    assert w.read(ENV_FILE) == "OPENROUTER_API_KEY=sk-or-abc\n"
    assert w.tokens[1] not in w.read(CONFIG + ".bak.surfaces.20260101-120000")
    assert all(t not in w.cap.everything for t in w.tokens)


def test_a_conflicting_entry_refuses_before_anything_is_installed(tmp_path):
    w = new_world(tmp_path)
    w.put(CONFIG, "mcp_servers:\n  surfaces:\n    url: \"http://mine\"\n")
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 3
    assert "did not create" in w.cap.stderr and "--mcp-name" in w.cap.stderr
    assert w.fs.ops == [] and not w.exists("/opt/hermes-surfaces")
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--mcp-name", "phone") == 0


def test_a_missing_hermes_home_is_never_created(tmp_path):
    w = new_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 3
    assert "does not exist" in w.cap.stderr and not w.exists("/home/alice/.hermes")
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--hermes-home", "/srv/missing") == 3


def test_hermes_home_comes_from_the_environment_or_the_flag(tmp_path):
    w = new_world(tmp_path, environ={"HERMES_HOME": "/srv/hermes-profile"})
    w.put("/srv/hermes-profile/config.yaml", "model: x\n")
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    assert "mobile-surfaces:surfaces" in w.read("/srv/hermes-profile/config.yaml")
    assert not w.exists("/home/alice/.hermes")
    other = new_world(tmp_path / "flag", environ={"HERMES_HOME": "/srv/ignored"})
    other.put("/opt/h/config.yaml", "")
    assert run(other, "apply", "--scope", "system", "--write-hermes-config", "--hermes-home", "/opt/h") == 0
    assert "mobile-surfaces:surfaces" in other.read("/opt/h/config.yaml")


def test_a_new_config_file_in_an_existing_hermes_home_is_private(tmp_path):
    w = new_world(tmp_path)
    w.fs.mkdir(P("/home/alice/.hermes"), 0o700)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    assert w.fs.modes[P(CONFIG)] == 0o600 and w.fs.modes[P(ENV_FILE)] == 0o600
    assert not [p for p in w.fs.real(P("/home/alice/.hermes")).iterdir() if ".bak." in p.name]  # nothing to back up


def test_uninstall_removes_only_what_the_installer_added_when_asked(tmp_path):
    w = hermes_world(tmp_path)
    assert run(w, "apply", "--scope", "system", "--write-hermes-config") == 0
    assert run(w, "uninstall", "--scope", "system", "--write-hermes-config") == 0
    assert w.read(CONFIG) == EXISTING and w.read(ENV_FILE) == "OPENROUTER_API_KEY=sk-or-abc\n"
    backups = [p.name for p in w.fs.real(P("/home/alice/.hermes")).iterdir() if ".bak." in p.name]
    assert len(backups) >= 2


def test_dry_run_of_a_hermes_edit_changes_nothing(tmp_path):
    w = hermes_world(tmp_path)
    w.fs.clear_ops()
    assert run(w, "apply", "--scope", "system", "--write-hermes-config", "--dry-run") == 0
    assert w.read(CONFIG) == EXISTING and w.fs.ops == []
    assert "edit   /home/alice/.hermes/config.yaml" in w.cap.stdout and "backup first" in w.cap.stdout


def test_documented_constants():
    """The numbers the docs quote: the author's builds take 10-60 s, and Hermes' API server defaults to 8642."""
    assert hermes.MCP_TIMEOUT == 180 and hermes.API_SERVER_PORT == 8642
