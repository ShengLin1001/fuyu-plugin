---
name: fuyu-plugin
description: Build, change, test and package plugins for Fuyu (浮屿), the desktop island for Windows. Use whenever the work is a Fuyu plugin - a folder with fuyu-plugin.json (or the older focusd-plugin.json) - or the user asks to 写浮屿插件 / 做一个插件 / 给岛加一个页面、折叠条状态、命令、快捷键、右键菜单、提示、音效包, "fuyu plugin", "island plugin", or to validate, pack, sign or publish one to the plugin market.
---

# Writing a Fuyu plugin

A Fuyu plugin is a folder the island runs as a child process. They talk JSON-RPC 2.0, one JSON message per line on stdin/stdout. The plugin sends no HTML: it sends data, and the island draws its pages, collapsed-bar status, notifications and settings page in its own style. Everything below is checked against the `fuyu-plugin` CLI and the docs; when in doubt, read them (links at the end) rather than guess.

## The loop

1. **Start from the scaffold**, not from an empty folder:
   ```sh
   npm create fuyu-plugin@latest my-plugin -- --language powershell --template list --author <github-name> --id <name>.<plugin> --name "English name" --name-zh 中文名 --yes
   ```
   - `--language`: `powershell` (runs on the PowerShell 5.1 every Windows has: users install nothing; prefer it for plugins meant for everyone), `typescript` or `javascript` (users need Node.js).
   - `--template`: `list` (a page on the island), `command` (a button that shows a notification), `status` (text on the collapsed bar), `blank`.
   - The id: 3-64 chars of `a-z 0-9 . -`, the same as the folder name; it must not contain `fuyu` or `focusd` (kept for official plugins).
   - The plugin runs from `lib/` (the SDK is copied there); it needs no `node_modules` at run time.
2. **Edit `fuyu-plugin.json`** (see [references/manifest.md](references/manifest.md)) and the main file (`main.ps1`, `main.mjs` or `src/main.mts` compiled to `dist/main.mjs`). Ask only for the permissions you call; ask for rarely used sensitive ones as `optionalPermissions` and `permissions.request` them when needed.
3. **Test without the island**: `npx fuyu-plugin test`. With `test/*.test.mjs` it runs them under `node --test`; without, it smoke-tests: starts the plugin, runs every command, opens every view and checks nothing failed. Write tests with the mock host from `fuyu-plugin/test` (example in [references/api.md](references/api.md#testing)). TypeScript: `npm run build` (or `npm test`, which builds) first.
4. **Try it on the real island** (only if the user has it running): `npx fuyu-plugin dev`. Needs, in the island, Settings > Plugins: the **Local API** plugin with **Allow changes** on, and Developer > **Development mode** (not saved across restarts). It loads the folder, restarts the plugin 300 ms after a file changes and prints its log; Ctrl+C removes it. If it cannot connect, tell the user which of those switches to turn on; don't loop on retries.
5. **Check and package**: `npx fuyu-plugin validate`, then `npx fuyu-plugin pack` (writes `.package/<id>-<version>.zip`, byte-for-byte reproducible). `validate` also warns about permissions asked but apparently unused, and used but not asked: fix both.
6. **Publish** (only when the user asks): bump `version`, `npx fuyu-plugin keygen` once (the user must back up the key), `npx fuyu-plugin publish --sign` packs, signs and prints the steps: a GitHub release with the zip and `.zip.sig` (the scaffold's workflow does it when a version tag is pushed), then a first-time pull request to `TixXin/fuyu-plugins` adding `plugins/<id>.json`. These are outward actions: confirm with the user before pushing tags or opening pull requests.

## Rules that bite

- **stdout is the protocol.** Never print anything else to stdout: in PowerShell no bare expressions, no `Write-Output`/`Write-Host` for logs; use `Write-FuyuLog` (or stderr). In Node use `plugin.log()`. Every stderr line goes to the plugin's log.
- **Exit when stdin closes**, and on `shutdown` finish within 2 s. The SDKs do this for you; don't block the read loop with long work.
- **Re-send state after a restart.** View models, status text and event subscriptions are cleared when the process stops. Send the view model when `view.visible` arrives with `visible: true`; subscribe to events right after `initialize`.
- **Plugins with `activationEvents` stop after 60 s idle** (no messages, no open view). `"activationEvents": []` means "start only when a command or view is used". Need to keep running (a timer, a connection)? `host.keepAlive { reason }`. Prefer `onSchedule:<minutes>` (5-1440) to keeping a loop alive.
- **Sensitive permissions** (`clipboard:read`, `messages:read`, `media:read`, `shelf:read`, `shelf:write`) are confirmed by the user on the island the first time they are used; the request waits up to 30 s. Give requests a timeout longer than that (the Node SDK has none; keep it that way). Denied: error `-32001`.
- **PowerShell**: keep `.ps1` files ASCII; write Chinese as `\uXXXX` escapes through `ConvertFrom-FuyuEscape`. A function returning one item unrolls the array: wrap calls in `@(...)` before `.Count`. Dot-source the SDK: `. "$PSScriptRoot\lib\fuyu.ps1"`, then dispatch with `Invoke-FuyuLoop` (helpers: `Invoke-FuyuMethod`, `Update-FuyuView`, `Update-FuyuStatus`, `Show-FuyuNotification`, `Register-FuyuEvent`, `Get-/Set-/Remove-FuyuStorage`, `Get-/Set-/Remove-FuyuSecret`, `Request-FuyuPermission`, `Set-FuyuKeepAlive`, `Write-FuyuLog`). Read `lib/fuyu.ps1` for exact parameters.
- **Data**: small state in `storage.*` (no permission, 64 KB per value, 1 MB per plugin); tokens in `secrets.*` (needs `secrets`); files in `FUYU_PLUGIN_DATA_DIR`, never in the plugin folder (an update replaces it).
- **Text** shown on the island can be a string or `{ "zh-CN": "...", "en": "..." }`; give both languages for anything users read. Manifest names, titles and setting titles must have both.
- **Limits** the island enforces (and the mock host too): a view model at most 256 KB, list pages at most 500 items, status text at most 24 characters, `island.notify` at most 6 a minute, at most 2 views, 2 status items, 8 commands, 20 settings.
- **No `.cmd`/`.bat` entry points.** Runtime command extensions: `.ps1`, `.exe`, `.js`/`.mjs`/`.cjs` (Node).
- Don't add `experimentalApis`: the island has none today, and the market rejects plugins that use them.

## Choosing the shape

| The user wants | Use |
|---|---|
| A page they open on the island | `contributes.views` with template `list` (rows, check boxes, search, inline buttons), `detail` (markdown and facts), `form` (inputs and submit) or `status` (one big number, progress) |
| Something always visible when collapsed | `contributes.statusItems` + `status.update` (text; `cells` columns, a `ring`, or `batteries` when the island supports them) |
| A one-off action | `contributes.commands` (+ `keybinding`, `when`), shown on the plugin's settings page; `menus` to put it on the todo / clipboard / shelf / message right-click menu |
| A heads-up | `island.notify` (`island:notify`), with up to 2 buttons |
| A chart or something templates can't draw | template `webview` (a local HTML page, no network, talks to the plugin through `acquireFuyuApi()`). Last resort: templates match the island's look |
| React to the user's data | `events.subscribe` (`todos.changed`, `clipboard.changed`, `media.changed`, `system.idle`...) or `onEvent:<name>` activation |
| Custom AI agent sounds | `contributes.sounds`, `runtime: { "type": "none" }` |

Details of every field, method and event: [references/manifest.md](references/manifest.md) and [references/api.md](references/api.md).

## Done means

- `npx fuyu-plugin validate` passes with no permission warnings left unexplained.
- `npx fuyu-plugin test` passes, with a test for each command and view the plugin adds.
- README.md says what the plugin does, which permissions it asks for and why, and its settings, in the user's language (the market shows README.md and CHANGELOG.md).
- Then tell the user how to try it (`npx fuyu-plugin dev`, or unzip the package into the island's plugins folder in a folder named after the id).

## Sources of truth

- Guide (Chinese): https://github.com/TixXin/fuyu/blob/main/docs/plugins/README.md
- Quick start: https://github.com/TixXin/fuyu/blob/main/docs/plugins/quickstart.md
- Every method and event, generated from the protocol: https://github.com/TixXin/fuyu/blob/main/docs/plugins/api.md
- Manifest JSON schema: `node_modules/fuyu-plugin/schema/manifest.schema.json` (installed with the dev dependency) or https://github.com/TixXin/fuyu/blob/main/plugins/schema/manifest.schema.json
- Types of the Node SDK: `lib/fuyu.d.mts`; of the mock host: `node_modules/fuyu-plugin/src/test/index.d.mts`
- Examples: https://github.com/TixXin/fuyu/tree/main/plugins/examples
- `npx fuyu-plugin help` lists every command.
