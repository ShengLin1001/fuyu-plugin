# fuyu-plugin.json

Condensed from the guide's "清单" and "岛上页面" sections; the JSON schema is the final word (`fuyu-plugin validate` checks against it).

```json
{
  "id": "yourname.reading-list",
  "name": { "zh-CN": "阅读清单", "en": "Reading list" },
  "description": { "zh-CN": "……", "en": "…" },
  "version": "0.1.0",
  "apiVersion": 2,
  "minAppVersion": "0.3.4",
  "author": "yourname",
  "homepage": "https://github.com/yourname/reading-list",
  "runtime": { "type": "process", "command": "main.ps1" },
  "permissions": ["island:notify"],
  "optionalPermissions": ["clipboard:read"],
  "activationEvents": [],
  "contributes": {
    "commands": [{ "id": "add", "title": { "zh-CN": "添加", "en": "Add" }, "keybinding": "Ctrl+Alt+R", "when": "island.expanded" }],
    "menus": { "clipboard/context": [{ "command": "add" }] },
    "views": [{ "id": "main", "title": { "zh-CN": "阅读", "en": "Reading" }, "icon": "list-checks", "template": "list" }],
    "statusItems": [{ "id": "count", "priority": 0 }],
    "settings": [{ "key": "interval", "type": "number", "title": { "zh-CN": "间隔（分钟）", "en": "Every (minutes)" }, "min": 5, "max": 60, "default": 15 }]
  }
}
```

| Field | Notes |
|---|---|
| `id` | Required. 3-64 chars `a-z 0-9 . -`, equal to the folder name. No `fuyu` / `focusd` in third-party ids. |
| `name` | Required, both `zh-CN` and `en`. |
| `version` | Required, 1-32 chars. Bump it for every release; the release tag must match. |
| `apiVersion` | Required. Write `2` (views, events, storage, notifications need it; version 1 ignores them). |
| `minAppVersion` | Lowest Fuyu version; older islands show "can't load". Set it when using newer features (`webview`, `frame: "none"` need 0.3.4). |
| `runtime` | `{ "type": "process", "command": "<relative path>", "args": [] }` or `{ "type": "none" }` (manifest only, e.g. a sound pack). Command by extension: `.ps1` (Windows PowerShell 5.1), `.exe`, `.js`/`.mjs`/`.cjs` (needs Node.js). No `.cmd`/`.bat`. |
| `permissions` | Granted when the user enables the plugin. A new version asking for more pauses the plugin until the user agrees. |
| `optionalPermissions` | Not granted up front; call `permissions.request` before use. Same values as `permissions`. |
| `activationEvents` | Omit = runs as long as the island. Otherwise any of `onStartup`, `onStartupFinished`, `onCommand:<id>`, `onView:<id>`, `onEvent:<event>`, `onSchedule:<5-1440 minutes>`, `onUri`. Commands and views add their own `onCommand`/`onView`, so `[]` = "only when used". Idle 60 s → `shutdown`. |
| `contributes.commands` | Max 8. `id`: letters, digits, `-`. Shown as buttons on the plugin's settings page. `keybinding`: modifiers (`Ctrl`, `Alt`, `Shift`, `Win`) + one key; users can rebind. `when` (max 200 chars): `island.expanded`, `todos.hasActive`, `island.page == todo` (`todo`, `music`, `clipboard`, `shelf`, `qq`, `agents`, `translation`), with `!`, `&&`, `||`, `==`, `!=`, parentheses. |
| `contributes.menus` | `todo/context` (command gets `args: { todoId }`), `clipboard/context`, `shelf/context`, `message/context` (command gets `args: { item }`, no read permission needed for that item). Max 4 commands per menu, each from this plugin's commands. |
| `contributes.views` | Max 2. `id` 1-32 letters/digits/`-`; `title` both languages; `icon` a lucide name listed in the schema (default `puzzle`); `template` `list`, `detail`, `form`, `status` or `webview` (+ `entry`, `height` 80-480, `width` 320-860, `frame: "none"`). |
| `contributes.statusItems` | Max 2. `id`, `priority` -100..100. Text set with `status.update`. |
| `contributes.settings` | Max 20. `key` 1-32 letters/digits/`-`/`_`; `type` `boolean`, `number` (integer, `min`/`max`), `string` (max 1000 chars), `select` (`options: [{ value, title }]`); `title` (and optional `description`) in both languages; `default` matching the type. The island draws and saves them; the plugin gets them complete in `initialize.settings` and `settings.changed`. |
| `contributes.sounds` | Sound pack: `{ "license": "CC0-1.0", "files": { "<event>": "sounds/x.wav" } }`; events `start`, `complete`, `error`, `approval`, `question`, `ack`, `compact`, `idle`, `quotaLow`, `quotaReset`; `.wav .mp3 .ogg .m4a .flac`, 4 MB each. |
| `contributes.agentEffortLabels` | Rename effort labels on the Agent page: `{ "claudeCode": { "high": "max" } }`. |
| `experimentalApis` | Don't use: no experimental APIs exist and the market rejects them. |

`.fuyuignore` (gitignore-like) lists what `pack` leaves out of the zip: tests, sources, `node_modules/`, `.github/`, `.claude/`, `AGENTS.md`. The entry file must not be ignored.

## View models (`view.update { viewId, model }`)

All text fields take a string or `{ "zh-CN", "en" }`.

- **list**: `{ items?, groups?: [{ title?, items }], empty?, loading?, error?, search?: { placeholder?, mode?: "local" | "remote" } }`. Item: `id` (required, 1-128 of `A-Za-z0-9-_.:/`), `title` (required), `subtitle`, `note`, `icon`, `checked` (true/false shows a box; click → `view.action { actionId: "check", itemId, checked }`), `url` (https only, opens in the browser), `action` (click → `view.action { actionId: <action>, itemId }`), `actions` (max 3 `{ id, title, icon? }`). Max 500 items. `view.patch { viewId, items, remove?, add? }` edits rows after a first `view.update`.
- **detail**: `{ title?, markdown?, meta?: [{ label, value }] (max 20), actions? (max 3), loading?, error? }`. Markdown: headings, bold, italic, inline code, lists, paragraphs, https links; HTML shows as text.
- **form**: `{ fields, submitTitle?, message?, error? }`; field `{ key, type, title, description?, placeholder?, value?, options?, min?, max? }`, types as settings plus `multiline` (4000 chars). Submit → `view.submit { viewId, values }`.
- **status**: `{ primary, secondary?, caption?, progress? (0-1), tone? ("neutral" | "accent" | "warning" | "danger"), actions? }`.
- **webview**: the plugin's own HTML (`entry`), no network, strict CSP, no island APIs. Page script: `const api = acquireFuyuApi()` (once) → `api.postMessage(m)` (plugin gets `webview.message`), `api.onMessage(fn)` (plugin sends `webview.postMessage { viewId, message }`), `api.getState()/setState()`, `api.locale`. Theme variables `--fuyu-text`, `--fuyu-accent`, `--fuyu-surface`... Have the page post "ready" first; messages sent before it loads are dropped.

Models up to 256 KB; at most 10 shown updates per second per view.

## Status (`status.update { itemId, text, tooltip?, tone?, cells?, ring?, batteries? }`)

`text` required, max 24 chars, `""` clears. `cells`: up to 4 `{ label (6), value (8), tone? }`; `ring`: 0-1; `batteries`: up to 4 `{ level, tone? }`. Older islands show `text` only, so always send it.
