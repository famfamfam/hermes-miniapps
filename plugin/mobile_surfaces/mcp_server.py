"""Author tools exposed as an MCP server (Streamable HTTP).

Hermes is an MCP *client*: it lists this server under `mcp_servers:` in its config and shows the
tools to the model as `mcp_<server>_<tool>`. That removes any dependency on Hermes's internal
plugin API: the server is an ordinary process next to Hermes, on the same Store as the phone API.

Tool names are deliberately short, because Hermes prefixes them with the server name.

Errors: a refused or failing operation raises, and FastMCP returns it to the model as a tool error
with the message text (SQLite's own wording for SQL problems), which is what the model needs to fix
its next call.

Tools that only read are annotated `readOnlyHint`, so Hermes does not ask for approval each time the
model looks at a file or the list of apps; editing, building and publishing still do.
"""
from __future__ import annotations

from typing import Any, Literal

import anyio
from mcp.server.fastmcp import FastMCP, Image
from mcp.server.transport_security import TransportSecuritySettings
from mcp.types import ToolAnnotations

from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.store import Store, StoreError

READ_ONLY = ToolAnnotations(readOnlyHint=True)

# Appears in the descriptions of the tools that start or continue interface work. A subagent inherits
# exactly the main assistant's tools, so tool visibility cannot make the main assistant delegate;
# the description is the one place the model is certain to read before calling.
DELEGATE_NOTE = (
    "Interface work is long: many edits and builds, and it should run on the author model. If you are the "
    "main chat assistant answering the user directly, do not do it inline: call delegate_task with a complete "
    "brief (see the surfaces-author skill). If you were given an authoring brief, you are the subagent: proceed."
)


def _described(text: str) -> str:
    return f"{text}\n\n{DELEGATE_NOTE}"

INSTRUCTIONS = """\
Tools for building small persistent mobile apps ("surfaces") for the user's Hermes client.
Each app has its own SQLite database (or reads a database owned by an existing skill). Create the
app, define its tables with data_sql(mode="schema"), fill it with data_sql(mode="write"), look at data
with data_read, and check named queries with app_check_definitions. Interfaces are React code edited
with app_source/app_edit, checked with app_build and put on the phone with app_publish.
Call reference first if you have not used these tools before.
"""

REFERENCE = """\
Conventions for app data (apply them every time):
- money is an INTEGER in minor units (kopecks, cents), never a float;
- dates and times are ISO 8601 strings; the client formats them;
- every table has `id INTEGER PRIMARY KEY` and `created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP`;
- statuses and categories are short lowercase codes; labels belong to the interface;
- table names starting with `_ms_` are reserved and refused.

data_read runs one SELECT (use it to look at schemas and rows; it needs no approval). data_sql modes:
"write" (INSERT/UPDATE/DELETE) and "schema" (CREATE/ALTER/DROP of tables, indexes, views); "read" is
accepted there too but asks for approval, so prefer data_read. Use ":name" parameters with the
`params` object instead of pasting values into SQL. Pass `rows` (a list of lists) with an INSERT using "?" placeholders to insert many rows in
one transaction. Every write bumps the app's data revision and notifies open screens. Long text cells
are shortened in read results: look at the shape of the data, do not copy documents into the chat.

Linked apps (`linked: true` in app_list) read a database that another service owns, for example an
existing skill's receipts. They are read-only for you: data_sql write/schema modes are refused, and so are
mutations, unless the administrator switched writing on for that app (`writable: true` in app_list); then only
its reviewed mutations, never data_sql, may change that file. The owning service does not know about such a change,
so keep to simple, safe ones (a status flag) and say in your report which rows a button changes. The owning
service keeps writing to its file. Use data_read to explore their tables
(SELECT name, sql FROM sqlite_master). Their money columns may be REAL rubles: convert in the query,
e.g. CAST(ROUND(amount * 100) AS INTEGER), so the interface still receives integer kopecks.

SQL notes: string helpers available are substr, instr, replace, trim/ltrim/rtrim, length, printf, char,
concat, upper/lower. SQLite's upper()/lower() fold only ASCII letters (Cyrillic is left as it is), and
LIKE is case-insensitive only for ASCII; use GLOB or compare after normalising. Window functions and
JSON functions work. Do not parse free text with long chains of substr/instr in a phone query: if data
needs cleaning, say so to the user, because the fix belongs in the skill that writes it.

A named query is {"sql": "...", "params": {"name": {"type": "string|integer|number|boolean|date|datetime|enum", "nullable": true}}, "shape": "rows|row|value", "maxRows": 200}.
Parameters are declared by name and must appear in the SQL as :name. :now, :today and :device_id are
provided by the server and must not be declared. A mutation is {"sql": "...", "params": {...}, "label": "...", "confirm": true} (label and confirm are
optional) or, for changes that must succeed together, {"statements": ["...", "..."], ...} with 2-5 statements run in
one transaction. It must change a table; every statement can use the params and :now/:today/:device_id. label is
what the phone's confirmation window says (1-60 characters, in the language of the user); statements that can delete rows (DELETE, REPLACE INTO, INSERT OR REPLACE, UPDATE OR
REPLACE, or a table declared ON CONFLICT REPLACE) are marked destructive and always confirmed by the user.
"""

AUTHORING_REFERENCE = """\

Building an interface (React + TypeScript, compiled on the server, run on the phone without a model):
1. Look at the schema and 3-5 sample rows with data_read. Do not read more than you need.
2. Describe what the screens need as named queries in definitions.json (format above) and check them
   with app_check_definitions. Queries are the only way the interface gets data.
3. app_source(app_id) lists the draft; app_source(app_id, path) reads a file. The starter has
   src/App.tsx (tabs), src/screens.tsx (screens), src/components.tsx (kit), src/format.ts, src/styles.css.
4. app_edit(app_id, path, content) replaces a whole file. Writable: definitions.json and
   src/<name>.ts|tsx|css (no sub-folders). src/main.tsx is fixed. No new packages exist: use react,
   "@hermes/mobile-sdk" and the files of the project.
5. app_build(app_id) type-checks and builds; fix every file:line error it lists. At most three fix
   cycles: if it is still failing, simplify the screen or tell the user what blocks you.
6. app_publish(app_id) puts the last successful build in front of the user. With the user's phone
   paired it only submits: the user sees a preview on the phone with real data and approves there; the
   approval is a signature the server cannot make, so nothing you do can publish instead. Tell the user
   which screens changed and to open the preview. Any further edit withdraws the submission.

Code rules (the build refuses the others):
- data only through useQueryGroup([{ name, args }]) from "@hermes/mobile-sdk"; it returns
  { group, loading, error, refetch } and the rows are in group.results[name].data. Every query named
  in the code must exist in definitions.json.
- amounts arrive as integers in minor units (kopecks, cents): show them with money() from "./format" (money(amount,
  "EUR") for another currency than the default: RUB on a Russian phone, USD elsewhere); months with periodLabel().
- write every text of the screens in the language the user speaks to you; the kit (Chips, DataMeta, FilePicker, ...)
  already shows Russian or English by the phone's language.
- no fetch/XMLHttpRequest/WebSocket/eval/localStorage/external URLs/fonts, and no images except stored
  pictures through hermes.fileUrl (see Files); navigation is by hash (href="#/path") with routes listed
  in src/App.tsx.
- a button that saves, marks or deletes must be a real mutation (see Buttons): never one that only looks like it saves.
- put <DataMeta state={state} /> at the bottom of every screen that reads data.

Kit in src/components.tsx: Tile({label,value,tone?}), BarChart({rows:[{month:"2026-09",total}]}),
Chips({label,options:[{label,value}],value,onChange}), ListCard({title,subtitle,amount,badge,actions?}),
DataMeta({state}), FilePicker({label,accept?,onPicked}), DownloadButton({label,source}),
FileThumb({file}), ActionButton({label,mutation,args?,onDone?,tone?}). Reuse them; add new components to the same
file rather than new libraries.

Buttons. Choose the kind by what the button has to do:
- Change rows of the app's own database (save a form, mark as paid, rename, delete): a MUTATION. Declare it in
  definitions.json under "mutations", e.g. {"mark_paid": {"sql": "UPDATE bills SET status = 'paid' WHERE id = :id",
  "params": {"id": {"type": "integer"}}, "label": "Mark the bill as paid"}} (a form adds a row the same way:
  INSERT with :name parameters; money typed by the user goes through toMinor() from "./format"). On the screen:
  <ActionButton label="Mark paid" mutation="mark_paid" args={{ id: b.id }} /> or the hook const save =
  useMutation("mark_paid"); save.run({ id }) -> { done, rowsAffected, lastInsertId } with save.pending and
  save.error (it never throws). It is instant and uses no model. The page sends only the name and typed arguments,
  never SQL: the server runs the SQL you wrote and the user approved. The phone asks the user before anything that
  deletes by itself ("confirm": true asks before the others). After a save the queries on screen read again. A
  repeat of one tap (a lost answer) never writes twice. Only a published app saves: in a preview a save button says
  that saving is off.
- The work needs thinking, a skill, a program or the web (generate a picture, read a PDF, run a script, write to the
  database of another skill): hermes.askHermes(prompt, fileIds), see Files. The user reads the text and sends it;
  Hermes, usually a sub-agent, then does the work, including writing and running a script. Say in the prompt
  exactly what to run, with which values and files, and where the result goes (a linked folder + file_import, or
  rows), so that nothing is left to guess.
- A button that runs a script of its own on the server, without a model, does not exist yet (planned). Do not
  promise one; use askHermes for that and word the prompt as an instruction to run the script.

Files. The phone moves them; the page never sees bytes, paths or addresses.
- Download (e.g. a receipt's PDF): declare a locator in definitions.json under "files":
  {"files": {"receipt_file": {"sql": "SELECT file_path FROM receipts WHERE id = :id",
  "params": {"id": {"type": "integer"}}, "root": "receipts"}}}. The statement returns ONE column, the place of
  the file; "root" names a host folder the administrator linked to the app (file_list shows the names; if there
  is none, tell the user to ask the administrator for `ms_admin link-files`). The server serves only a file
  inside that folder, of an accepted type (pdf, pictures, text, tables, archives; at most 30 MB). On the screen:
  <DownloadButton label="Download PDF" source={{ name: "receipt_file", args: { id: r.id } }} />. The user then
  picks save, open or share on the phone. The path column stays in the locator; never select it in a query.
- Upload (a reference picture, a receipt to add): <FilePicker label="Choose a file" accept={["image/*"]}
  onPicked={(file) => ...} /> opens the phone's own picker (20 MB). The file is stored for the app; file_list,
  file_read and file_view show it to you; file_path gives its place on the host (and real name) when a skill
  or a command has to process it. List stored files with useFiles() (it re-reads when they change).
- Pictures: <FileThumb file={file} /> or <img src={hermes.fileUrl(file.fileId)} alt="" /> (stored png, jpg, webp
  or gif of this app only; other images and URLs are not available).
- Telling Hermes ("submit"): build the prompt from the form and call hermes.askHermes(prompt, fileIds). The phone
  shows the whole text and sends it as the user's own message in a new chat only after the user taps Send; it adds
  the list of attached files with their file_id. Write the prompt as you would write to Hermes: what the user
  wants, the form values, which skill or table to use, and to read the files with file_read / file_view. At most
  2400 characters and 8 files. Nothing is sent without the tap, so do not word the screen as if it already was.
- A file you produce (a generated picture): put it into a host folder linked as a root, then
  file_import(app_id, root, path); it appears in the app's files and in useFiles().
- A download that fails with "not allowed to read" (or a `warnings` entry in file_list): the service has no root
  rights and reads only what other users may read; the administrator fixes the file mode with chmod a+r. Tell the
  user; do not try to change modes yourself.
- A stored file is offered under the type its first bytes show, not its extension (a JPEG saved as x.pdf is
  offered as x.jpg).
- In a preview the buttons only say that files are switched off; check the screens by their layout.

Screen example (src/screens.tsx):

    import { useState } from "react";
    import { useQueryGroup } from "@hermes/mobile-sdk";
    import { Chips, DataMeta, ListCard } from "./components";
    import { money } from "./format";

    export function Overview() {
      const [status, setStatus] = useState<string | null>(null);
      const state = useQueryGroup([{ name: "items", args: { status } }]);
      const rows = (state.group?.results.items.data as { id: number; title: string; amount: number }[] | undefined) ?? [];
      return (
        <section>
          <h1>Items</h1>
          <Chips label="Status" value={status} onChange={setStatus}
                 options={[{ label: "All", value: null }, { label: "Open", value: "open" }]} />
          <ul className="list">
            {rows.map((r) => <ListCard key={r.id} title={r.title} amount={money(r.amount)} />)}
          </ul>
          <DataMeta state={state} />
        </section>
      );
    }
"""


def create_mcp(
    store: Store, *, allowed_hosts: list[str] | None = None, authoring: Authoring | None = None
) -> FastMCP:
    hosts = allowed_hosts or ["127.0.0.1:*", "localhost:*", "[::1]:*"]
    mcp = FastMCP(
        "mobile-surfaces",
        instructions=INSTRUCTIONS,
        stateless_http=True,  # every request stands alone: clients can reconnect freely
        json_response=True,
        streamable_http_path="/mcp",
        transport_security=TransportSecuritySettings(
            enable_dns_rebinding_protection=True,
            allowed_hosts=hosts,
            allowed_origins=[],
        ),
    )

    @mcp.tool(annotations=READ_ONLY)
    def reference() -> str:
        """Conventions and the query/mutation definition format. Read before building an app."""
        return REFERENCE + (AUTHORING_REFERENCE if authoring is not None else "")

    @mcp.tool(annotations=READ_ONLY)
    def app_list() -> list[dict[str, Any]]:
        """List all apps, including ones that are not published yet."""
        return store.all_apps()

    @mcp.tool(
        description=_described(
            "Create an empty app with its own database.\n\n"
            "app_id: lowercase letters, digits and underscores, starts with a letter, 2-40 characters.\n"
            "brief: what the app is for and where its data comes from (one or two sentences)."
        )
    )
    def app_create(app_id: str, title: str, icon: str | None = None, brief: str | None = None) -> dict[str, Any]:
        store.create_app(app_id, title, icon=icon, brief=brief)
        return {"appId": app_id, "created": True}

    @mcp.tool(annotations=READ_ONLY)
    def data_read(app_id: str, sql: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        """Run one SELECT against an app's database (its own, or a linked skill's, read-only).

        Returns columns and rows (long text cells are shortened). Use it to look at the schema
        (SELECT name, sql FROM sqlite_master) and a few sample rows. It never changes anything.
        """
        return store.agent_sql(app_id, "read", sql, params)

    @mcp.tool()
    def data_sql(
        app_id: str,
        mode: Literal["read", "write", "schema"],
        sql: str,
        params: dict[str, Any] | None = None,
        rows: list[list[Any]] | None = None,
    ) -> dict[str, Any]:
        """Run one SQL statement inside the app's own database.

        Use mode "write" or "schema" (they return the new dataRev and the tables touched). With
        `rows`, the statement runs once per row (use "?" placeholders). Mode "read" works but asks
        for approval; prefer data_read for looking at data.
        """
        return store.agent_sql(app_id, mode, sql, params, rows)

    @mcp.tool(annotations=READ_ONLY)
    def app_check_definitions(app_id: str, definitions: dict[str, Any]) -> dict[str, Any]:
        """Validate named queries and mutations against the app's real database; nothing is saved.

        Returns each query's column names, its completeness and each mutation's destructive flag,
        or the first error with SQLite's own message.
        """
        checked = store.validate_definitions(app_id, definitions)
        return {
            "queries": {
                name: {"columns": q["columns"], "shape": q["shape"], "completeness": q["completeness"]}
                for name, q in checked["queries"].items()
            },
            "mutations": {name: {"destructive": m["destructive"]} for name, m in checked["mutations"].items()},
        }

    @mcp.tool(annotations=READ_ONLY)
    def file_list(app_id: str) -> dict[str, Any]:
        """Files kept for the app (uploaded from the phone or imported), newest first, and the names of the
        host folders the administrator linked to it (for file_import and for file locators). `warnings` appears when
        files of a folder cannot be read by the service."""
        out: dict[str, Any] = {"files": store.files.list_files(app_id), "roots": sorted(store.files.root_names(app_id))}
        warnings = [
            f"folder {w['root']!r}: {w['files']} file(s) the service is not allowed to read (the administrator sees which "
            f"with `ms_admin files {app_id}` and fixes them with chmod a+r); downloads of those files fail until then"
            for w in store.files.readability_warnings(app_id) if w["files"]
        ]
        if warnings:
            out["warnings"] = warnings
        return out

    @mcp.tool(annotations=READ_ONLY)
    def file_read(app_id: str, file_id: str) -> dict[str, Any]:
        """Name, type and size of a stored file, and its text when it is a short text file (.txt .csv .md .json).
        For a picture use file_view; for a PDF or any other document tell the user what is there only from
        what file_view or the name shows, never guess the contents."""
        return store.files.read_for_agent(app_id, file_id)

    @mcp.tool(annotations=READ_ONLY)
    def file_path(app_id: str, file_id: str) -> dict[str, Any]:
        """Where a stored file lies on this host, with its real name and type, so that a skill or a terminal
        command can process it (a PDF receipt to parse, a reference picture to pass to an image tool).

        The file is kept without its extension, so copy it out under the returned name before using it, and treat
        the original as read-only: do not edit, move or delete it there. The path can be opened only by a user who
        may read this service's state directory (root can); otherwise use file_read / file_view.
        """
        path, record = store.files.get(app_id, file_id)
        return {"path": str(path), "name": record["name"], "mime": record["mime"], "size": record["size"]}

    @mcp.tool(annotations=READ_ONLY)
    def file_view(app_id: str, file_id: str) -> Image:
        """Show a stored picture (png, jpg, webp, gif up to 5 MB) to you. Refused for anything else."""
        shown = store.files.image_bytes(app_id, file_id)
        if shown is None:
            raise StoreError("this file is not a picture of a size that can be shown (png, jpg, webp or gif, 5 MB at most)")
        data, mime = shown
        return Image(data=data, format=mime.split("/", 1)[1])

    @mcp.tool(
        description=(
            "Copy a file from a host folder linked to the app into the app's own files, so its screens can show "
            "and offer it (a generated picture, a downloaded document).\n\n"
            "root: a folder name from file_list(...).roots. path: the file's path relative to that folder (or "
            "absolute, when it lies inside the folder). Returns the new fileId; the same content again returns "
            "the same file. At most 20 MB; pdf, pictures, text, tables and archives only."
        )
    )
    def file_import(app_id: str, root: str, path: str) -> dict[str, Any]:
        return store.files.import_from_root(app_id, root, path)

    @mcp.tool()
    def file_delete(app_id: str, file_id: str) -> dict[str, Any]:
        """Delete one stored file of the app for good."""
        store.files.delete(app_id, file_id)
        return {"deleted": True, "fileId": file_id}

    if authoring is None:
        return mcp

    @mcp.tool(annotations=READ_ONLY)
    def app_source(app_id: str, path: str | None = None) -> dict[str, Any]:
        """List the files of the app's interface draft, or read one file.

        Without `path`: the file list with sizes, the draft revision and the state of the last build.
        With `path`: the file's full text. The draft starts from the published version or the starter.
        """
        if path is None:
            return authoring.status(app_id)
        return authoring.read(app_id, path)

    # `content` is annotated exactly `str`: FastMCP tries to JSON-decode string arguments whose
    # annotation is anything else (e.g. `str | None`), which would turn a definitions.json body into
    # an object and make the call fail. test_mcp_authoring pins this.
    @mcp.tool(
        description=_described(
            "Replace one file of the interface draft with `content` (the whole file).\n\n"
            "Writable paths: definitions.json and src/<name>.ts|tsx|css. Pass expected_draft_rev (from the "
            "previous result) to refuse the edit if the draft changed in between. Editing does not change "
            "what phones run."
        )
    )
    def app_edit(
        app_id: str, path: str, content: str, expected_draft_rev: int | None = None
    ) -> dict[str, Any]:
        return authoring.write(app_id, path, content, expected_draft_rev)

    @mcp.tool()
    def app_delete_file(app_id: str, path: str) -> dict[str, Any]:
        """Delete one file of the draft (src/App.tsx and definitions.json are required)."""
        return authoring.delete(app_id, path)

    @mcp.tool(
        description=_described(
            "Check and build the interface draft in an isolated environment.\n\n"
            "Returns ok, the stage that failed (lint, types, bundle, definitions, checks) and a short list "
            "of file:line diagnostics. The result belongs to the draft revision it names; any later edit "
            "makes it stale. Takes several seconds."
        )
    )
    async def app_build(app_id: str) -> dict[str, Any]:
        return await anyio.to_thread.run_sync(authoring.build, app_id)

    @mcp.tool(
        description=_described(
            "Put the last successful build of the current draft in front of the user. When the user's "
            "phone is paired this only SUBMITS the build: the user previews it on the phone and approves "
            "there, and only that publishes (the result says status=awaiting_review; tell the user to open "
            "the preview, do not try to publish another way). Without a paired phone it publishes at once, "
            "replacing the version the user has now (there is no rollback yet): then ask before calling.\n\n"
            "Refused if the draft changed after the build, if the app was published from another draft in "
            "the meantime, or if the definitions no longer validate against the data."
        )
    )
    def app_publish(app_id: str) -> dict[str, Any]:
        return authoring.publish(app_id)

    @mcp.tool()
    def app_reset_draft(app_id: str) -> dict[str, Any]:
        """Discard the draft; the next edit starts again from the published version."""
        return authoring.reset(app_id)

    return mcp
