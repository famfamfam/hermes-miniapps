# hermes_surfaces

Flutter host for Hermes mini-apps (Stage 0 spike, not a release). It installs verified web
bundles from a Hermes `mobile-surfaces` server, runs them in a locked-down WebView and answers
their data requests through a checked bridge.

- `lib/src/bundle_verify.dart`, `bundle_store.dart`: verification and atomic install of bundles
- `lib/src/bridge.dart`: gatekeeper for page-to-host messages (origin, frame, size, schema)
- `lib/src/surface_view.dart`: the WebView screen (request interception, CSP, navigation rules)
- `lib/src/host.dart`, `snapshots.dart`: queries, offline snapshots, connectivity
- `example/`: test app used for the Stage 0 device checks

Setup and how to run the checks: [CONTRIBUTING.md](../../CONTRIBUTING.md). MIT licence, see `LICENSE` in the repository root.
