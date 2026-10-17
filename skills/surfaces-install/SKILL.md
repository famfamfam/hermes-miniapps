---
name: surfaces-install
description: "Install, upgrade or check the Hermes Mobile Surfaces server (the plugin behind the phone app's mini-apps) on this machine, one step at a time, asking the user before every change. Use when the user asks to install, set up, update or repair Mobile Surfaces or the mini-apps server for the phone."
version: 0.1.0
author: mobile-surfaces
platforms: [linux]
metadata:
  hermes:
    tags: [install, setup, upgrade, phone, apps, surfaces]
---

# Install Mobile Surfaces (the server part)

Mobile Surfaces is a small Python service that runs next to Hermes and serves the phone app's mini-apps. This skill
installs it from a checkout of the project's repository with the project's own installer
(`tools/install/install.py`). The installer does the work and refuses, changing nothing, when something is missing;
your job is to run it in the right order, explain what it will do, and ask the user first. The repository's
README.md is the manual version of the same steps; read it when the user asks "why".

Reply to the user in their language. Keep each message short: what you found, what you are about to do, one question.

## When this applies

The user asks to install, set up, update or repair Mobile Surfaces / the phone mini-apps server, or gives you the
project's repository address and asks you to install it.

## Ground rules

- You run on the machine where Hermes runs. If the user asks for another machine, stop: this skill cannot reach it.
- **Ask before every change** that is not a read: installing packages, running the installer's `apply`, writing to
  Hermes' configuration, opening a port. A command the user declines is not tried another way: stop and say so.
- If `sudo` needs a password you cannot type, do not look for a way around it: give the user the exact command to run
  in their own terminal and wait for them to say it is done.
- Never print, quote or send a token, the Hermes API key or the content of a `.env` file. Where a value has to be
  written, write it without echoing it. The one thing that may appear in this chat is the `HAP1.` connection line of
  step 7.
- **Order matters.** Hermes gets write access to the plugin (step 8) only **after** the phone is paired (step 7):
  until a phone is paired as the approver, an agent's `app_publish` publishes without review.
- Do not restart the Hermes gateway yourself: it ends this very conversation. Give the user the command.
- Do not open ports, edit a firewall or a reverse proxy by yourself. The phone's way to the server is the user's choice.
- Do not change the `trust` setting of the `surfaces` MCP server: `untrusted` asks the user before every write,
  `full` does not. That is the user's decision.

## Steps

1. **Look first (reads only).** Run `id -un`, `echo "${HERMES_HOME:-$HOME/.hermes}"`, `uname -sr`,
   `systemctl --version | head -1`, `python3 --version`, `git --version`, `node --version`, `free -m` and
   `ls -d /opt/hermes-surfaces`. The minimums are systemd 247, Python 3.11, and Node.js 20 (Node only to let Hermes
   build screens). If `/opt/hermes-surfaces` exists this is an **upgrade**: use step 9. Tell the user in three or
   four lines what you found. If something is missing (on Debian or Ubuntu usually `python3-venv`), say what and
   offer to install it; do not install without a yes.
2. **Get the code.** Use the repository address the user gave you, nothing else: `git clone <address> ~/hermes-miniapps`
   (or `git -C ~/hermes-miniapps pull` if it is already there). Work from that folder.
3. **Show the plan.** Run `python3 tools/install/install.py plan --with-authoring` (without `--with-authoring` if
   there is no Node.js 20+ and the user does not want it). It prints every change and writes nothing. Summarize it
   in plain words: the folders it creates, the two random tokens (they stay on the server, mode 0600), the hardened
   systemd service, the two ports (8787 for the phone, 8788 for Hermes' author tools, both on 127.0.0.1 only).
   If the host is small (a couple of GB of RAM or less), offer `--limits small` and say it lowers the memory and
   CPU ceilings. Then ask: "Install it now?"
4. **Install.** After a yes run `sudo python3 tools/install/install.py apply --with-authoring --enable --start`
   with the same options as the plan (leave `sudo` out when you are already root). Two extra options when they
   apply: `--hermes-user <the user from step 1>` if that user is not root (so Hermes can read its token), and
   `--hermes-home <path>` if Hermes' home is not the default of the user running the command. **Do not pass
   `--write-hermes-config` yet** (step 8). Show the installer's closing summary. If it refuses, it changed nothing:
   show its message as it is. When the message names an option (`--python /usr/bin/python3`, `--copy-node`,
   `--api-port`), explain it and offer to re-run with it; that is the installer's own advice, not a workaround.
5. **Check.** `sudo /opt/hermes-surfaces/venv/bin/python -m mobile_surfaces.install status --health --scope system`.
   Report ok, or the problem.
6. **The phone's way in, and the chat.** Ask how the phone will reach this server: USB tunnel (to try it), a VPN such
   as Tailscale, or HTTPS on the server's address (`tools/edge/README.md`). Explain the choice in two sentences, then
   do the steps of the one the user picks, one at a time, asking before each system change. If the app should also
   chat, Hermes' own API server must be on (README step 2). That edits `~/.hermes/.env`: ask first, generate the key
   straight into the file without printing it (`umask 077`, `python3 -c "import secrets; print(secrets.token_urlsafe(32))"`),
   and give the user the restart command. The user reads the key from the server when they type it into the app: that
   key reaches every tool of the agent, so it never goes through a chat.
7. **Pair the phone.** The app must be on the phone first: you cannot install it; the user takes the signed APK from the
   repository's Releases page or builds it (README step 3). Ask for the address the phone will use (never guess it,
   never use 127.0.0.1 for a phone), store it with
   `sudo sh -c 'umask 077; echo "<address>" > /etc/hermes-surfaces/public-url'`, then run
   `sudo /opt/hermes-surfaces/venv/bin/python -I -m ms_admin pair-code --token-file /etc/hermes-surfaces/api-token`.
   It prints one line that starts with `HAP1.`: send it to the user in this chat on a line of its own, unchanged, and
   say: copy it, open the Apps tab in the phone app, press "Paste connection code", confirm; it works once for 15
   minutes. If the terminal output is masked, do not rebuild the line from pieces: say so, and ask the user to run
   the command in their own terminal. Afterwards check that the health answer says `"approverPaired": true` with the
   command from README step 5 (the token stays inside `$(sudo cat …)`).
8. **Give Hermes access.** Only now, after a yes: `sudo python3 tools/install/install.py apply --upgrade --with-authoring --enable --start --write-hermes-config`
   (plus the options of step 4). It backs each file up first and never overwrites an entry it did not create. Then tell
   the user to run `/reload-mcp` in a Hermes chat and start a new session; the skills `surfaces-author` and
   `surfaces-connect-phone` appear after that.
9. **Upgrade (the install already exists).** `git pull`, then `python3 tools/install/install.py plan --upgrade`, show
   the summary, ask, then `sudo python3 tools/install/install.py apply --upgrade --with-authoring --enable --start`
   with the options the install already uses. Tokens and data are kept.
10. **Finish** with a short list: what is installed, what the user still has to do (install the app, paste the line,
    restart the gateway, `/reload-mcp`), and where to look if something fails (README, "Troubleshooting").

## Uninstall

Only when the user asks. `sudo python3 tools/install/install.py uninstall` removes the service and code and keeps data
and tokens. `uninstall --purge --yes` also deletes every app's data and the tokens: do it only after the user has said
in so many words that the data may go.

## If something fails

Show the error text as it is, say in one sentence what it means, and stop. Do not retry in another way, do not edit the
installer, do not work around a refusal (a busy port, a missing prerequisite, an old systemd): those are the installer
protecting the server, and the user decides what to change.
