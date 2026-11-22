"""Send one push without coupling notification failure to the cron job."""

from contextlib import suppress
import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


# Never forward the authorization header or notification to a redirect target.
urlopen = build_opener(_NoRedirect()).open


def notify_cron(config_path, profile_home, content):
    """Mirror a redacted cron result only for the explicitly bound profile."""
    try:
        with open(config_path, encoding="utf-8") as config_file:
            config = json.load(config_file)
        bound_home = config.get("profile_home")
        if not isinstance(bound_home, str) or not bound_home or not profile_home:
            return None
        if Path(bound_home).resolve() != Path(profile_home).resolve():
            return None
        return send_push(config_path, "Hermes", content)
    except Exception:
        return False


def send_push(config_path, title, message):
    """Return True when OneSignal accepts the notification, not when it is delivered.

    config_path names a JSON file containing appid, subscription_id and api_key.
    The caller should run the cron job independently and ignore a False result.
    """
    try:
        with open(config_path, encoding="utf-8") as config_file:
            config = json.load(config_file)
        if not isinstance(config, dict):
            return False
        values = [config.get(key) for key in ("appid", "subscription_id", "api_key")]
        if any(not isinstance(value, str) or not value.strip()
               or value != value.strip() or any(ord(c) < 32 or ord(c) == 127 for c in value)
               for value in values):
            return False
        if not isinstance(title, str) or not isinstance(message, str):
            return False
        title = "".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in title).strip()[:120].strip()
        message = "".join(" " if ord(c) < 32 or ord(c) == 127 else c for c in message).strip()[:1200].strip()
        if not title or not message:
            return False

        appid, subscription_id, api_key = values
        payload = json.dumps({
            "app_id": appid,
            "include_subscription_ids": [subscription_id],
            "target_channel": "push",
            "headings": {"en": title},
            "contents": {"en": message},
        }).encode("utf-8")
        request = Request(
            "https://api.onesignal.com/notifications", data=payload, method="POST",
            headers={"Authorization": "Key " + api_key, "Content-Type": "application/json"},
        )
        with urlopen(request, timeout=10) as response:
            if not 200 <= response.status < 300:
                return False
            body = response.read(65537)
        if len(body) > 65536:
            return False
        result = json.loads(body)
        return (isinstance(result, dict) and isinstance(result.get("id"), str)
                and bool(result["id"].strip()) and result.get("errors", []) == [])
    except HTTPError as error:
        with suppress(Exception):
            error.close()
        return False
    except Exception:
        return False
