---
name: surfaces-connect-phone
description: "Connect the user's phone app (Apps) to the Mobile Surfaces server: print a one-time connection line and send it in the chat for the user to paste. Use when the user asks to connect, pair or set up the mini-apps on their phone."
version: 0.1.0
author: mobile-surfaces
platforms: [linux]
metadata:
  hermes:
    tags: [phone, pairing, setup, apps, surfaces]
---

# Connect the phone app (mobile-surfaces)

The phone app connects to the Surfaces server with a **connection line**: text that starts with `HAP1.`.
It holds the server's public address and a **one-time code** (valid 15 minutes, works once), never the
long-lived token. The user copies the line from this chat, opens the Apps tab of the phone app, presses
**Paste connection code**, and confirms. That also makes this phone the device that confirms publishing and
deleting apps (the first phone that connects).

Reply to the user in their language.

## When this applies

The user asks to connect, pair or set up the apps on the phone, or says the app shows "not set up" or
"no access".

## What to do

1. The command needs the **public address** the phone must use: the HTTPS address of the Surfaces phone API, for
   example `https://host:8443/<secret-prefix>/ms` (see tools/edge/README.md), without `/api/...`. Normally it is
   already stored in a file named `public-url` next to the token files, and the command reads it by itself:
   then do not pass `--public-url`. Only when the command says that it has no address, ask the user for it; never
   guess it and never use `127.0.0.1` for a phone.
2. Run this in the terminal (it will ask for approval; it talks to the running service and stops nothing):

   ```
   sudo /opt/hermes-surfaces/venv/bin/python -I -m ms_admin pair-code --token-file /etc/hermes-surfaces/api-token
   ```

   (With an address from the user: add `--public-url <ADDRESS>`.) If the service was installed under another
   name, scope or port, take the token file path from
   `python3 -m mobile_surfaces.install status --print-token-path api` and add
   `--api-url http://127.0.0.1:<port>` (the command talks to port 8787 by default, which may be another
   service). The command prints one line that starts with `HAP1.`.
3. Send that line to the user in the chat **on a line of its own, unchanged**, and tell them in one or two
   sentences: copy it, open the Apps tab in the phone app, press "Paste connection code", confirm the
   question. Say that it works once and for 15 minutes; if it expires, you can make a new one.
4. If the command fails, show its error as it is and stop. Do not try other ways.

## Never

- Never work around masking. If the terminal output shows the line as asterisks or otherwise hidden, do not print it
  in pieces, write it to a file, re-encode it or reassemble it: stop and tell the user that this server hides the
  command's output from you, and that an administrator can run the command and read the line out of the terminal.
- Never print, quote or send the phone token, the MCP token or any token file's content. Only the `HAP1.`
  line leaves the server.
- Never put the line anywhere except this chat (no files, no other channels, no web pages).
- Never try to reset or replace the phone that confirms publications: that is an administrator action on
  the server, and it is how a lost phone is replaced. Tell the user it needs the administrator.
