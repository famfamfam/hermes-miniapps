# Templates

Four small web projects. Hermes does not copy them by hand; the plugin builds screens from the first one, and the others
are there to read.

| Folder | What it is |
|---|---|
| `starter-app/` | What every new app starts from, and what the plugin's build tools use (`--template`). The kit in `src/components.tsx` (tiles, chips, charts, the data line, the file picker and download button) shows Russian on a Russian phone and English elsewhere (`src/format.ts`, `tr()`). |
| `react-app/` | A small demo (utility bills over an app's own database) used by `ms_admin demo`, with buttons that write (add, mark paid, delete). English. |
| `zhkh-app/` | An example of an interface over **someone else's database**: the screens the author runs over a receipts skill (a read-only linked SQLite file), with a PDF download through a file locator. Russian, and tied to that skill's schema; read it as an example, do not expect it to fit your data. |
| `probe-app/` | Not an app template: a deliberately hostile page used to check that the WebView sandbox holds (no network by any channel). Russian text. |

Build one: `cd templates/<name> && npm ci && npm run build` (type-check and bundle). The mobile SDK these projects import
lives in `packages/mobile-sdk`; the screens read data only through named queries and change it only through named mutations in `definitions.json`.
