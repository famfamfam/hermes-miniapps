"""Patch the known Hermes cron-delivery seam without changing its routing."""

import ast


_ANCHOR = "    _record_delivery_verification(job, unverified_targets)\n    return \"; \".join(delivery_errors) if delivery_errors else None\n"
_HOOK = '''    _record_delivery_verification(job, unverified_targets)
    if suppressed_targets < len(targets):
        try:
            from hermes_constants import get_hermes_home
            from cron.hermes_onesignal_push import notify_cron
            if notify_cron("/etc/hermes-cron-push/config.json", get_hermes_home(), cleaned_delivery_content) is False:
                logger.warning("Cron push was not accepted")
        except Exception:
            logger.warning("Cron push could not be sent")
    return "; ".join(delivery_errors) if delivery_errors else None
'''


def patch_delivery(source):
    """Refuse unknown versions and duplicate patches rather than guess a seam."""
    tree = ast.parse(source)
    matches = [n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "_deliver_result"]
    if len(matches) != 1:
        raise ValueError("Expected one cron delivery function")
    lines = source.splitlines(keepends=True)
    node = matches[0]
    function = "".join(lines[node.lineno - 1:node.end_lineno])
    if source.count(_ANCHOR) != 1 or function.count(_ANCHOR) != 1 or "hermes_onesignal_push" in function:
        raise ValueError("Unknown or already patched cron delivery")
    result = source.replace(_ANCHOR, _HOOK, 1)
    ast.parse(result)
    return result
