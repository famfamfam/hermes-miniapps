"""Installer: rendered unit files (golden), template rules and what a unit must never contain."""
from __future__ import annotations

import re
from importlib import resources
from pathlib import PurePosixPath

import pytest
from install_support import assert_golden

from mobile_surfaces.install import model, render
from mobile_surfaces.install.model import Options, make_layout
from mobile_surfaces.install.render import render_dropin, render_template, render_unit

HOME = PurePosixPath("/home/alice")


def unit(opts: Options, env=None, node_dir=None) -> str:
    return render_unit(make_layout(opts, HOME, env or {}), opts, node_dir)


def dropin(opts: Options) -> str | None:
    return render_dropin(make_layout(opts, HOME, {}), opts)


# -- golden files -------------------------------------------------------------------------------------

UNITS = {
    "system-default.service": (Options(), None),
    "system-authoring.service": (Options(authoring=True), None),
    "system-authoring-nodepath.service": (Options(authoring=True, build_timeout=200), PurePosixPath("/opt/node/bin")),
    "system-copied-node.service": (Options(authoring=True, copy_node=True), PurePosixPath("/opt/hermes-surfaces/node/bin")),
    "system-public-bind.service": (Options(host="0.0.0.0", api_port=9100, mcp_port=9101), None),
    "user-default.service": (Options(scope="user"), None),
    "user-authoring-sandbox.service": (Options(scope="user", authoring=True, user_sandbox=True), None),
}


@pytest.mark.parametrize("golden", sorted(UNITS))
def test_unit_golden(golden):
    opts, node_dir = UNITS[golden]
    assert_golden(golden, unit(opts, node_dir=node_dir))


def test_dropin_golden():
    assert_golden("resources-small-data-only.conf", dropin(Options(limits=model.SMALL_DATA_ONLY)))
    assert_golden("resources-small-authoring.conf", dropin(Options(authoring=True, limits=model.SMALL_WITH_BUILDS)))
    assert_golden("resources-custom.conf", dropin(Options(limits=model.Limits(memory_max="600M", cpu_quota="50%"))))


def test_no_dropin_without_limits():
    assert dropin(Options()) is None


# -- properties every unit must have -------------------------------------------------------------------


@pytest.mark.parametrize("golden", sorted(UNITS))
def test_unit_never_carries_a_secret_argument(golden):
    opts, node_dir = UNITS[golden]
    text = unit(opts, node_dir=node_dir)
    exec_start = text[text.index("ExecStart="):text.index("\nRestart=")]
    assert not re.search(r"--(?:mcp-)?token(?:\s|=)", exec_start)  # only the *-file forms exist
    assert "Environment=MS_" not in text and "MS_DEV_TOKEN" not in text and "MS_MCP_TOKEN" not in text
    if opts.scope == "system":  # root-only files, handed to the dynamic user as systemd credentials
        assert "--token-file credential:api-token" in exec_start and "--mcp-token-file credential:mcp-token" in exec_start
        assert "LoadCredential=api-token:/etc/hermes-surfaces/api-token" in text
        assert "LoadCredential=mcp-token:/etc/hermes-surfaces/mcp-token" in text
    else:  # the user reads its own 0600 files; no credentials needed (older user managers lack them)
        assert "--token-file /home/alice/.config/hermes-surfaces/api-token" in exec_start
        assert "--mcp-token-file /home/alice/.config/hermes-surfaces/mcp-token" in exec_start
        assert "LoadCredential" not in text


@pytest.mark.parametrize("golden", sorted(UNITS))
def test_mcp_is_always_loopback_and_has_no_seed_step(golden):
    opts, node_dir = UNITS[golden]
    text = unit(opts, node_dir=node_dir)
    assert "--mcp-host 127.0.0.1" in text
    assert "ExecStartPre" not in text.replace("# No ExecStartPre", "")  # no startup reseed, ever
    assert "seed" not in re.sub(r"#.*", "", text).lower()


def test_system_unit_hardening_matches_the_reference_deployment():
    text = unit(Options())
    for line in (
        "DynamicUser=yes", "StateDirectory=hermes-surfaces", "StateDirectoryMode=0700", "UMask=0077",
        "NoNewPrivileges=yes", "ProtectSystem=strict", "ProtectHome=yes", "PrivateTmp=yes", "PrivateDevices=yes",
        "RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6", "Restart=on-failure",
    ):
        assert line in text.splitlines(), line
    assert "MemoryDenyWriteExecute" not in re.sub(r"#.*", "", text)  # would break Node


def test_loopback_service_is_denied_all_other_ip_traffic():
    """The service only listens; the unit enforces that it never connects out (and nothing but loopback reaches it)."""
    for opts in (Options(), Options(authoring=True), Options(host="::1"), Options(host="localhost")):
        lines = unit(opts).splitlines()
        assert "IPAddressDeny=any" in lines and "IPAddressAllow=localhost" in lines
        assert lines.index("IPAddressDeny=any") < lines.index("IPAddressAllow=localhost")
    public = unit(Options(host="0.0.0.0"))
    assert "IPAddressDeny=any" not in public.splitlines() and "IPAddressAllow" not in public
    assert "# IPAddressDeny is not set because the phone API is bound to a non-loopback address." in public
    assert "IPAddress" not in unit(Options(scope="user"))  # a user manager cannot install the cgroup firewall


def test_unit_has_no_resource_limits_without_the_dropin():
    text = unit(Options())
    for key in ("MemoryMax", "MemoryHigh", "CPUQuota", "TasksMax"):
        assert key not in text


def test_authoring_arguments_only_when_enabled():
    assert "--template" not in unit(Options()) and "--no-authoring" in unit(Options())
    on = unit(Options(authoring=True))
    assert "--no-authoring" not in on
    assert "--template /opt/hermes-surfaces/templates/starter-app" in on and "--sdk /opt/hermes-surfaces/sdk" in on
    assert "--work-dir /var/lib/hermes-surfaces/work" in on and "--build-timeout 150" in on


def test_public_bind_is_visible_in_the_unit():
    loopback = unit(Options())
    public = unit(Options(host="0.0.0.0"))
    assert "WARNING" not in loopback
    assert "WARNING: the phone API is bound to 0.0.0.0" in public and "--host 0.0.0.0" in public


def test_user_unit_differs_from_system_unit():
    user = unit(Options(scope="user"))
    assert "DynamicUser" not in user and "StateDirectory" not in user and "ProtectSystem" not in user
    assert "WantedBy=default.target" in user and "WantedBy=multi-user.target" in unit(Options())
    assert "--home /home/alice/.local/state/hermes-surfaces" in user


def test_user_sandbox_block_is_opt_in():
    assert "ProtectSystem" not in unit(Options(scope="user"))
    sandboxed = unit(Options(scope="user", user_sandbox=True))
    assert "ProtectSystem=strict" in sandboxed
    assert "ReadWritePaths=/home/alice/.local/state/hermes-surfaces" in sandboxed
    assert "226/NAMESPACE" in sandboxed


def test_path_environment_is_set_only_for_a_node_directory():
    assert "Environment=PATH" not in unit(Options(authoring=True))
    text = unit(Options(authoring=True), node_dir=PurePosixPath("/opt/node/bin"))
    assert "Environment=PATH=/opt/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" in text


def test_unit_ends_with_a_newline_and_uses_lf():
    for opts, node_dir in UNITS.values():
        text = unit(opts, node_dir=node_dir)
        assert text.endswith("\n") and "\r" not in text and "\n\n\n" not in text


# -- the template engine --------------------------------------------------------------------------------


def test_placeholder_alone_on_a_line_vanishes_when_empty():
    assert render_template("a\n@@X@@\nb\n", {"X": ""}) == "a\nb\n"
    assert render_template("a\n@@X@@\nb\n", {"X": "line1\nline2"}) == "a\nline1\nline2\nb\n"
    assert render_template("k=@@X@@\n", {"X": ""}) == "k=\n"


def test_missing_and_unused_values_are_errors():
    with pytest.raises(ValueError, match="no value"):
        render_template("@@A@@ @@B@@\n", {"A": "1"})
    with pytest.raises(ValueError, match="unused"):
        render_template("@@A@@\n", {"A": "1", "TYPO": "2"})


@pytest.mark.parametrize("bad", ["50%h", "a$HOME", "x\x07y", "a\x00b"])
def test_values_systemd_would_expand_are_refused(bad):
    with pytest.raises(ValueError, match="expand"):
        render_template("Key=@@A@@\n", {"A": bad})


def test_cpu_quota_percent_is_a_value_not_a_specifier():
    assert "CPUQuota=100%" in render_template("[Service]\n@@A@@\n", {"A": "CPUQuota=100%"})


def test_every_template_is_fully_covered_by_the_renderer():
    """Every placeholder in every shipped template gets a value in at least one rendering."""
    shipped = {p.name for p in (resources.files("mobile_surfaces.install") / "templates").iterdir() if p.name.endswith(".tmpl")}
    assert shipped == {"system.service.tmpl", "user.service.tmpl", "resources.conf.tmpl"}
    for name in shipped:
        keys = set(re.findall(r"@@([A-Z_]+)@@", render.load_template(name)))
        assert keys, name  # a template without placeholders would be a copy of a file
    unit(Options()), unit(Options(scope="user")), dropin(Options(limits=model.SMALL_DATA_ONLY))  # no exception
