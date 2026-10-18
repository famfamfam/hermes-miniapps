---
name: surfaces-author
description: "Create or change a phone app screen (interface) over a skill's data with the `surfaces` MCP server: queries, React screens, build, publish. Use when the user asks to make, redo or change a screen, interface or app on the phone."
version: 0.1.0
author: mobile-surfaces
platforms: [linux]
metadata:
  hermes:
    tags: [interface, phone, app, screens, React, surfaces]
---

# Phone interfaces (mobile-surfaces)

The `surfaces` MCP server keeps small apps for the user's phone. An app is a database (its own, or a
**linked** read-only view of an existing skill's SQLite file) plus a React interface that the server
compiles. Phones then run it without any model. Tools are named `mcp__surfaces__<tool>`.

Reply to the user in their language.

## When this applies

The user asks for a new screen/app ("make an interface for ..."), or to change one ("move the totals to
the top", "merge duplicate addresses in the overview").

## What to do

**Do not write the interface in this conversation.** It takes many tool calls and several build cycles,
and it needs a stronger model than the chat's. Hand it to a subagent with `delegate_task`; the subagent
has the same `mcp__surfaces__*` tools and runs on the model configured for delegation.

1. Find the app: `mcp__surfaces__app_list` (`linked: true` means a read-only view of another skill's
   data; `published: false` means nothing is on the phone yet). For a new app choose an id
   (lowercase letters, digits, `_`).
2. Write the subagent a **complete** brief. It cannot see this chat. Include:
   - the app id, and whether it is new or an existing one to change;
   - what the user wants to see and do, in the user's words, and anything they said about layout;
   - where the data comes from (which skill / table). An app over another skill's data (`linked: true`) is
     **read-only** unless `writable: true` in `app_list`: then no button may write there except a mutation
     you declare, and the user is told which rows it changes. Never a button that only pretends to save;
   - the working order: `reference` → `data_read` (the schema from `sqlite_master` and 3-5 sample rows,
     no more) → `definitions.json` → `app_check_definitions` → `app_edit` for each file →
     `app_build` (read the `file:line` errors, at most three fix cycles) → report;
   - what to return: which screens changed, the build result, anything it could not do.
3. After a successful build call `mcp__surfaces__app_publish`. When the user's phone is paired this does
   **not** replace anything: it submits the build, and the user previews it on the phone (the section
   "Waiting for your decision", «Ждут вашего решения» in Russian) and approves there. The result says `awaiting_review`: tell the user which
   screens changed and to open the preview. Do not look for another way to publish: the approval is a
   signature made on the phone, which nothing on the server can produce. If no phone is paired the call
   publishes at once and replaces the current version (there is no rollback): then ask the user first.
4. If the user wants changes after looking at the preview, edit and build again with a short brief; a new
   submission replaces the earlier one.

## Rules worth repeating to the subagent

- Money is integer kopecks in queries (convert REAL rubles with `CAST(ROUND(x * 100) AS INTEGER)`).
- Long text columns (raw document text, file paths) do not belong on a phone screen. Do not select them
  in a query. (A file path is used only inside a file locator, see below.)
- Data reaches screens only through named queries in `definitions.json`; no network, no storage, no
  external URLs or fonts.
- Use the kit in `src/components.tsx` (Tile, BarChart, Chips, ListCard, DataMeta, FilePicker,
  DownloadButton, FileThumb, ActionButton) instead of new CSS.

## Buttons that write

Choose per button, and put the choice into the brief for the subagent (`reference` has the exact shapes):

- **Changes rows of the app's own database** (save a form, mark as paid, delete): a **mutation** in
  `definitions.json` (`sql` or `statements`, typed `params`, a `label` in the user's language) and an
  `ActionButton` or `useMutation`. Instant, no model, no tokens. The phone asks before anything that deletes.
  The page never sends SQL: only the name and arguments. Only a published app saves; in the preview the button
  says saving is off, so describe in your report what each button does.
- **Needs work by the agent or a program** (generate a picture, read a PDF, run a script, write into another
  skill's database): `askHermes` with a prompt that says exactly what to run, with which values and files, and
  where the result goes. A sub-agent then writes and runs the script. There is no separate script runner behind a
  button yet (planned): do not promise one.
- **An app over another skill's data** (`linked: true`) saves only when `writable: true`; otherwise use
  `askHermes`. Only the administrator switches writing on (`ms_admin allow-writes`); do not run
  it yourself, and never edit that database yourself.

## Files, uploads and "send to Hermes"

When the user wants to download documents (receipts), add a file (a receipt, a reference picture), or fill
a form that Hermes should then act on, the screens use the file kit. `reference` has the exact shapes;
in short:

- **Download**: a `files` locator in `definitions.json` (one SQL column with the file's place + a linked
  host `root`) and a `DownloadButton`. If the app has no linked folder (`file_list` shows `roots`), do not
  invent one: report that the administrator must run `ms_admin link-files` for it.
- **A download that fails with "not allowed to read"**, or a `warnings` entry in `file_list`: the service runs
  without root rights and reads only what other users may read, so a file the skill saved with mode 600 is
  refused. Tell the user, in words: the administrator runs `ms_admin files <app_id>` (it lists which files) and
  `find <folder> -type f ! -perm -o=r -exec chmod a+r {} +` on the host, and the skill that saves the files should
  use mode 0644. Do not change modes or move the skill's files yourself.
- **Upload**: a `FilePicker`; the file is kept for the app. Read it with `file_read` (text) or `file_view`
  (pictures). Do not guess what is in a PDF.
- **Submit to Hermes**: the form calls `hermes.askHermes(prompt, fileIds)` with a prompt the screen builds
  from the form values. The phone shows the whole text and sends it as the user's message only after the
  user taps Send. Write the prompt so that Hermes can act without asking again: the goal, the values, the
  skill or table to use, and "read the attached file with `file_read` / `file_view`".
- **A file the user uploaded** (a receipt PDF, a reference picture) when Hermes is asked to act on it:
  `file_path` gives its place on this host and its real name; copy it out under that name and hand the
  copy to the skill or tool that needs a path. Never edit, move or delete the original there.
- **Generated files** (pictures): save them in a host folder linked as a root, then `file_import`.
- Screens cannot be tried with files in the preview: describe in your report what each button does.

## Never work around a refusal

Tool calls can be refused (the user did not approve, or the server said no). That is an answer, not
an obstacle:

- If a call is denied, **stop and report it** to the main assistant. Do not look for another way to
  do the same thing.
- Do not read the server's token or credential files, do not call its HTTP endpoints from scripts,
  and do not touch its state directories. Everything needed is available through the
  `mcp__surfaces__*` tools; the server's secrets are not part of the task. (The one exception is a file the
  user uploaded: read the path `file_path` returns, and only that.)
- Read data with `data_read` (it needs no approval), not with `sqlite3` or scripts in the terminal.
  The tool shortens long text columns on purpose.
- Do not write to the skill's own database or files yourself. A button may change them only through a mutation
  of an app the administrator made writable.

## If something fails

- A build error lists `file:line`: fix that file and build again. After three cycles, simplify the
  screen or tell the user what blocks it; do not loop.
- "interface builds are not configured": the server was started without its template; tell the user.
- Approval prompts for edit/build/publish are expected: the server is configured as untrusted. Each
  prompt times out after about a minute and then counts as a refusal; tell the user and wait.
- Tools of this server may be reached through `tool_search` / `tool_call` when they are not listed
  directly; pass `app_id` and the other required arguments inside each call.
