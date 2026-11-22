# Temporary cron push bridge

This is a temporary deployment prototype, not the GitHub installation path. The separate OneSignal platform plugin
is documented in the main README. Do not enable both delivery paths for the same tasks: they can send duplicate pushes.
Switching an existing deployment requires removing the old hook with a backup and rollback plan before enabling the plugin.

This optional bridge mirrors non-local Hermes cron deliveries to one explicitly bound Android subscription through
OneSignal. Existing Telegram and other delivery targets remain unchanged; `local` jobs and fully suppressed notices are
not sent. The payload is the Hermes-redacted delivery text, limited to 1,200 characters, and passes through OneSignal and
Firebase. Push delivery is not guaranteed; failures do not re-run the task.

The deployment must keep the app API key and subscription ID in a root-only file, bind it to the intended Hermes profile,
and never put them in an APK or repository. `patch_hermes.py` only accepts the specific upstream delivery seam it knows;
unknown versions fail closed. The patch is lost when Hermes replaces its source files and must be reviewed and reapplied
after an update. Test with `python -m unittest discover -s tools/cron_push/tests`.
