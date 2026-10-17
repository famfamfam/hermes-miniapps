# Contributing

This project is pre-release. Interfaces change without notice. Contributions are accepted under the [MIT licence](LICENSE); open an issue first for anything large.

## Run the checks

```text
cd plugin && python -m pytest                          # server, SQL sandbox, bundles, events
cd packages/hermes_surfaces && flutter test && flutter analyze
cd packages/hermes_surfaces_bridge && flutter test && flutter analyze
cd packages/hermes_surfaces/example && flutter test && flutter analyze
cd client && flutter test && flutter analyze                    # the Android app
cd templates/react-app && npm ci && npm run build      # typecheck + production build
python contracts/tools/make_fixtures.py                # only when the bundle format changes
```

Versions: Flutter 3.44.0 (stable) for `client/`, JDK 17 and Android SDK 36 to build the APK, Python 3.12 and Node.js 22
for `plugin/` and the templates. These are synthetic tests; they do not replace a run on a device. CI is defined in
`.github/workflows/ci.yml`.

## Ground rules

- **No secrets or personal data in commits, issues or logs.** No server addresses, tokens, API keys, keystores,
  `key.properties`, device identifiers, personal file paths or user names. Use placeholders such as
  `<server>` and `127.0.0.1`. If something leaks, report it as described in [SECURITY.md](SECURITY.md) rather than
  deleting it quietly: it has to be rotated.
- **Do not commit built APKs, keystores or `key.properties`.**
- **Native credential rules** (bridge README): no automatic pairing, no key creation at module start, no sharing the
  chat client or its credentials with Surfaces, no writes of root-level identity from the Apps module.
- **State what you verified.** A claim in documentation needs a test or a recorded run behind it. Say "not verified"
  where that is true.
- Language: `README.md` is the English source; the other `README.<language>.md` files translate it, and a test keeps
  their commands and links in step with it. Code comments and issues are in English. User-visible app text goes through
  the string layer in `hermes_surfaces` (the app itself uses `client/lib/l10n`); a test fails on a missing key.

## Pull requests

Small, focused changes with a description of what was run. Update the README in the same pull request when a command
or a step changes. Do not combine formatting changes with behaviour changes.
