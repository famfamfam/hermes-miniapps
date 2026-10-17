#!/usr/bin/env python3
"""Run the server installer straight from a clone: nothing has to be installed first.

    python3 tools/install/install.py plan                    # what would change; writes nothing
    sudo python3 tools/install/install.py apply              # system service (root)
    python3 tools/install/install.py apply --scope user       # user service (no root)
    python3 tools/install/install.py status --health

This is the same program as `python -m mobile_surfaces.install` (run from plugin/) and
`ms_admin install`; see README.md. Standard library only.
"""
from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "plugin"))

from mobile_surfaces.install.cli import main  # noqa: E402

if __name__ == "__main__":
    raise SystemExit(main())
