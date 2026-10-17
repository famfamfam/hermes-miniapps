"""The connection string a user copies from a chat into the phone app.

    HAP1.<base64url of {"u": <base address of the phone API>, "c": <one-time code>}>

It is not a link on purpose: chat apps do not turn it into something to tap, and the app reads it
itself and shows the host it would connect to before anything is sent. It carries a one-time code,
never the long-lived token (`Store.issue_pair_code`), so a copy left in a chat history is dead after
one use or fifteen minutes. The Dart side parses the same format (`packages/hermes_surfaces`).
"""
from __future__ import annotations

import base64
import json
import re
from urllib.parse import urlsplit

PREFIX = "HAP1."


class ConnectionStringError(ValueError):
    pass


def encode(base_url: str, code: str) -> str:
    """The string for `base_url` (e.g. https://host:8443/<secret>/ms) and a freshly issued `code`."""
    parts = urlsplit(base_url)
    if parts.scheme not in ("http", "https") or not parts.hostname or parts.username or parts.query or parts.fragment:
        raise ConnectionStringError("the address must be an http(s) URL without credentials, query or fragment")
    if not re.fullmatch(r"[A-Za-z0-9_-]{16,200}", code):
        raise ConnectionStringError("unexpected code format")
    payload = json.dumps({"u": base_url.rstrip("/"), "c": code}, separators=(",", ":"), ensure_ascii=False)
    # JSON that starts with `{"` encodes to base64 that starts with `eyJ`, the mark of a JWT, which Hermes (and other
    # tools) mask in terminal output: an agent then cannot show the line and tries to work around the masking. One space
    # after the brace (still valid JSON, read by every parser) moves the start to `eyAi`.
    payload = "{ " + payload[1:]
    return PREFIX + base64.urlsafe_b64encode(payload.encode("utf-8")).decode("ascii").rstrip("=")


def decode(text: str) -> tuple[str, str]:
    """(base address, code) from a string made by `encode`; leading/trailing whitespace is ignored."""
    text = (text or "").strip()
    if not text.startswith(PREFIX):
        raise ConnectionStringError("not a connection string")
    body = text[len(PREFIX):]
    try:
        data = json.loads(base64.urlsafe_b64decode(body + "=" * (-len(body) % 4)).decode("utf-8"))
        url, code = data["u"], data["c"]
    except (ValueError, KeyError, TypeError):
        raise ConnectionStringError("damaged connection string") from None
    if not isinstance(url, str) or not isinstance(code, str):
        raise ConnectionStringError("damaged connection string")
    return url, code
