# Plugin API, condensed

The complete list, generated from the protocol: https://github.com/TixXin/fuyu/blob/main/docs/plugins/api.md. Errors: `-32601` no such method (or a version-2 method from a version-1 plugin), `-32001` no permission / user declined / no answer in 30 s, `-32000` with `data.status` 400 bad params, 404 unknown, 409 feature off (or `view.patch` before `view.update`), 413 too big, 429 too many (16 requests in flight, 6 notifications a minute).

## Permissions

| Permission | Methods | Events |
|---|---|---|
| `todos:read` | `todos.list`, `todos.days` | `todos.changed` |
| `todos:write` | `todos.add`, `todos.update`, `todos.remove` | |
| `notes:read` | `note.get` | `note.changed` |
| `notes:write` | `note.set` | |
| `agent-status:read` | | `agentStatus.changed` |
| `agent-status:write` | `agentStatus.report`, `agentStatus.clear` | |
| `island:notify` | `island.notify` | |
| `secrets` | `secrets.get`, `secrets.set`, `secrets.delete` | |
| `clipboard:read` (sensitive) | `clipboard.history` | `clipboard.changed` |
| `messages:read` (sensitive) | `messages.list` | `messages.received` |
| `media:read` (sensitive) | `media.nowPlaying`, `media.cover` | `media.changed` |
| `media:control` | `media.playPause`, `.next`, `.previous`, `.seek`, `.setVolume`, `.toggleShuffle`, `.cycleRepeat` | |
| `shelf:read` (sensitive) | `shelf.list` | `shelf.changed` |
| `shelf:write` (sensitive) | `shelf.add`, `shelf.remove` | |

No permission: `host.info`, `host.keepAlive`, `settings.get`, `settings.set`, `ui.setInfo`, `events.*`, `storage.*`, `view.*`, `status.update`, `island.openView`, `permissions.request`; events `island.expanded`, `island.collapsed`, `app.locale.changed`, `system.locked`/`unlocked`, `system.suspended`/`resumed`, `system.idle`/`active`. Mail passwords and translation keys are reachable by no permission.

## Island → plugin

`initialize { apiVersion, capabilities, activationEvent?, appVersion, pluginId, dataDir, permissions, optionalPermissions?, settings }`, `command { id, args? }`, `settings.changed { settings }`, `event { name, payload }`, `notification.action { id }`, `uri { uri, path, query }`, `view.visible { viewId, visible }`, `view.action { viewId, actionId, itemId?, checked? }`, `view.submit { viewId, values }`, `view.search { viewId, query }`, `webview.message { viewId, message }`, `shutdown {}` (then stdin closes; the process is ended 2 s later).

Check `initialize.capabilities` before newer features (`views`, `status`, `statusCells`, `statusBatteries`, `notifyStyle`, `permissions`, `openView`, `webview`...); fields older islands don't know are ignored, so extra fields are safe.

## Node SDK (`lib/fuyu.mjs`)

```js
import { createPlugin } from "./lib/fuyu.mjs";
const plugin = createPlugin();

plugin.onReady(async (context) => plugin.log(`started by ${context.activationEvent}`));
plugin.onCommand("refresh", async () => { /* ... */ });
plugin.onEvent("todos.changed", async ({ date }) => { /* subscribed for you when ready */ });
plugin.views.onVisible("main", (visible) => visible && show());
plugin.views.onAction("main", async ({ actionId, itemId, checked }) => { /* ... */ });
plugin.views.onSubmit("form", async (values) => { /* ... */ });
plugin.onSettingsChanged((settings) => { /* ... */ });

async function show() {
  await plugin.views.update("main", { items: [{ id: "1", title: { "zh-CN": "一项", en: "An item" }, checked: false }] });
}
// Also: plugin.status.update(id, text, { tooltip, tone, cells, ring, batteries }), plugin.notify(title, { body, actions }),
// plugin.storage.get/set/delete/keys, plugin.secrets.*, plugin.todos.*, plugin.note.*, plugin.clipboard.history(),
// plugin.media.*, plugin.shelf.*, plugin.permissions.request/has, plugin.keepAlive(reason), plugin.setInfo(items),
// plugin.setSettings(values), plugin.openView(id), plugin.call(method, params) for anything else.
```

## PowerShell SDK (`lib/fuyu.ps1`)

```powershell
. "$PSScriptRoot\lib\fuyu.ps1"
Invoke-FuyuLoop @{
    initialize = { param($params) Register-FuyuEvent @('todos.changed') | Out-Null }
    'view.visible' = { param($params) if ($params.visible) { Update-FuyuView 'main' @{ items = @() } } }
    'view.action' = { param($params) Write-FuyuLog "clicked $($params.itemId)" }
    command = { param($params) if ($params.id -eq 'refresh') { Show-FuyuNotification 'Refreshed' } }
    event = { param($params) if ($params.name -eq 'todos.changed') { $todos = @((Invoke-FuyuMethod 'todos.list').todos) } }
}
```

Bilingual text, file kept ASCII: `New-FuyuText (ConvertFrom-FuyuEscape '\u4f60\u597d') 'Hello'` (the escapes spell 你好). A third argument to `Invoke-FuyuLoop` is an `-OnIdle` script block run when no message came within `-TimeoutMs` (default 5000): use it for periodic work in a plugin without `activationEvents`, or `Set-FuyuKeepAlive`.

## Testing

```js
import assert from "node:assert/strict";
import test from "node:test";
import { startMockHost } from "fuyu-plugin/test";

test("the page lists the saved items", async () => {
  const host = startMockHost(".", { storage: { items: [{ id: "1", title: "Read", done: false }] } });
  try {
    host.viewVisible("main");
    const model = await host.waitForView("main");
    assert.equal(model.items[0].title, "Read");
    host.viewAction("main", "check", { itemId: "1", checked: true });
    await host.waitFor((state) => state.storage.get("items")?.[0].done);
  } finally {
    await host.stop();
  }
});
```

Options: `permissions`, `deny` (refuse sensitive / optional ones), initial `todos`, `note`, `storage`, `secrets`, `clipboard`, `messages`, `media`, `shelf`, `settings`. Drive it with `command(id)`, `viewVisible`, `viewAction`, `viewSubmit`, `viewSearch`, `notificationAction`, `changeSettings`, `publish(event, payload)`, `openUri`. Inspect `requests`, `logs`, `views`, `statuses`, `notifications`, `storage`, `subscriptions`, `keepAlive`. Wait with `waitFor(fn)`, `waitForRequest(method)`, `waitForView(id, fn?)`, `waitForLog(text)`. It enforces the island's rules (permissions, version-1 limits, sizes, rate limits). PowerShell plugins are tested the same way: the test file is JavaScript, the plugin under test is `main.ps1`. Full types: `fuyu-plugin/src/test/index.d.mts`.
