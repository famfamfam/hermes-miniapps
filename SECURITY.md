# Security policy

## Status

This is pre-release software. It has **not** had an independent security review and is not a security release. A
summary of the security model is in the [README](README.md#security); the known open items are below. Run it only on a
private network, behind a tunnel or VPN or HTTPS reverse proxy, with tokens you can rotate.

## Reporting a vulnerability

**Contact: GitHub private vulnerability reporting (Security tab, "Report a vulnerability") on this repository.**

Please report privately. Do not open a public issue for a vulnerability, and do not paste tokens, API keys, server
addresses or logs that contain them into any issue, discussion or pull request. If you find that a secret has been
committed, report it the same way so that it can be rotated.

Helpful content: what you did, what you expected, what happened, the component and commit, and whether it needs the
phone, the server or both. A reproduction against a throw-away setup is ideal.

## Scope

In scope: the server plugin (`plugin/`), the Android app (`client/`), the Flutter packages (`packages/`), the templates
and SDK and the install tooling in this repository.

Out of scope, please report upstream: the Hermes Agent and its Gateway API server, Flutter, `flutter_inappwebview`, Android WebView and other third-party components. A
weakness in how this project uses them is in scope.

## Known open items

These are documented, not secret:

- The WebView network seal has a known gap: a page that creates a fresh `about:blank` iframe can build a WebRTC peer
  connection and send UDP (STUN/TURN) to arbitrary hosts. The risk was accepted for the author template, which
  contains no such code. Treat apps whose content is built from untrusted text with care.
- The author build lint is a text scanner, not a parser; the build and the WebView CSP are the real boundaries.
  Escaped CSS `url()` forms and some JSX text can slip past it.
- Stopping a build started under `systemd-run` after a timeout is not implemented; give the transient unit its own
  `RuntimeMaxSec=`.
- Pairing of the approver device is trust on first use: the first device that pairs becomes the approver. Pair from a
  channel you control, before exposing the service to anyone else.
- The server uses static bearer tokens and polls for events. It has been run on the author's own server only; other
  distributions and `--scope user` are untested.
