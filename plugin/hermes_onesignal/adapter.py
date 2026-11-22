"""Outbound-only OneSignal adapter; an accepted notification is not a delivery receipt."""

import asyncio
import json
import os
import stat
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID

from gateway.config import Platform
from gateway.platforms._shared import get_scoped_secret
from gateway.platforms.base import BasePlatformAdapter, SendResult
from hermes_constants import get_hermes_home


_NAMES = (
    "HERMES_ONESIGNAL_APP_ID",
    "HERMES_ONESIGNAL_API_KEY",
    "HERMES_ONESIGNAL_SUBSCRIPTION_ID",
)
_HOME = "HERMES_ONESIGNAL_HOME_CHANNEL"
_FILE = "onesignal.json"


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_open = build_opener(_NoRedirect()).open


def _credentials():
    # A present but invalid file must not fall back to a different identity.
    path = get_hermes_home() / _FILE
    try:
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
        fd = os.open(path, flags)
    except FileNotFoundError:
        try:
            values = [get_scoped_secret(name, "") for name in _NAMES]
        except Exception:
            return None
    except OSError:
        return None
    else:
        try:
            with os.fdopen(fd, "rb") as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode):
                    return None
                if os.name != "nt" and (info.st_mode & 0o077 or info.st_uid != os.geteuid()):
                    return None
                data = stream.read(8193)
            if len(data) > 8192:
                return None
            config = json.loads(data)
            values = [config.get(name) for name in _NAMES]
        except (OSError, ValueError, TypeError, AttributeError):
            return None
    if any(not isinstance(v, str) or not v or v != v.strip()
           or any(ord(c) < 32 or ord(c) == 127 for c in v) for v in values):
        return None
    return values


def _check():
    return _credentials() is not None


def _enablement():
    if not _check():
        return None
    return {"home_channel": {"chat_id": "phone", "name": "Phone"}}


def _parse_target(raw):
    return ("phone", None) if raw == "phone" else None


def _validate_target(target):
    return target == "phone"


def _send_http(credentials, message):
    app_id, api_key, subscription_id = credentials
    payload = json.dumps({
        "app_id": app_id,
        "include_subscription_ids": [subscription_id],
        "target_channel": "push",
        "headings": {"en": "Hermes"},
        "contents": {"en": message},
    }).encode("utf-8")
    try:
        request = Request(
            "https://api.onesignal.com/notifications", data=payload, method="POST",
            headers={"Authorization": "Key " + api_key, "Content-Type": "application/json"},
        )
        with _open(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                return {"error": "OneSignal HTTP error"}
            body = response.read(65537)
        if len(body) > 65536:
            return {"error": "Invalid OneSignal response"}
        result = json.loads(body)
        if not isinstance(result, dict) or result.get("errors", []) != []:
            return {"error": "OneSignal rejected notification"}
        message_id = result.get("id")
        if not isinstance(message_id, str) or str(UUID(message_id)) != message_id:
            return {"error": "Invalid OneSignal response"}
        return {"success": True, "message_id": message_id}
    except HTTPError as exc:
        status = exc.code
        exc.close()
        return {"error": f"OneSignal HTTP error {status}"}
    except (TimeoutError, URLError):
        return {"error": "OneSignal network error or timeout; delivery is unknown"}
    except Exception:
        return {"error": "OneSignal request failed; delivery is unknown"}


async def _standalone_send(pconfig, chat_id, message, *, thread_id=None, media_files=None, force_document=False):
    if chat_id != "phone":
        return {"error": "Unsupported OneSignal target"}
    if thread_id is not None or media_files or force_document:
        return {"error": "OneSignal supports text only"}
    if not isinstance(message, str):
        return {"error": "Invalid OneSignal message"}
    message = "".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in message).strip()[:1200].strip()
    if not message:
        return {"error": "Empty OneSignal message"}
    credentials = _credentials()
    if credentials is None:
        return {"error": "OneSignal credentials unavailable"}
    return await asyncio.to_thread(_send_http, credentials, message)


class OneSignalAdapter(BasePlatformAdapter):
    def __init__(self, config):
        super().__init__(config, Platform("onesignal"))

    async def connect(self, *, is_reconnect=False):
        if not _check():
            return False
        self._mark_connected()
        return True

    async def disconnect(self):
        self._mark_disconnected()

    async def get_chat_info(self, chat_id):
        if chat_id != "phone":
            raise ValueError("Unsupported OneSignal target")
        return {"name": "Phone", "type": "dm"}

    async def send(self, chat_id, content, reply_to=None, metadata=None):
        result = await _standalone_send(self.config, chat_id, content)
        if result.get("success"):
            return SendResult(success=True, message_id=result.get("message_id"))
        return SendResult(success=False, error=result.get("error", "OneSignal request failed"))


def register(ctx):
    ctx.register_platform(
        name="onesignal",
        label="OneSignal",
        adapter_factory=OneSignalAdapter,
        check_fn=_check,
        validate_config=lambda config: _check(),
        env_enablement_fn=_enablement,
        cron_deliver_env_var=_HOME,
        standalone_sender_fn=_standalone_send,
        parse_target_ref_fn=_parse_target,
        validate_target_ref_fn=_validate_target,
    )
