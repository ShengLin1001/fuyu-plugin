// The keeper under the mock host, with a fake claude.exe (fake-claude) editing a throwaway
// ~/.claude.json and a fake windows-mcp (windows-mcp) answering HTTP. Ports are moved up by
// MCP_KEEPER_PORT_OFFSET so a real shared server on this machine is never touched.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { startMockHost } from "fuyu-plugin/test";

const PLUGIN = path.resolve(import.meta.dirname, "..");
const PORT = 8932 + 10000;
const windowsOnly = { skip: process.platform !== "win32" };

async function ask(port) {
  try {
    return await (await fetch(`http://127.0.0.1:${port}/`)).json();
  } catch {
    return null;
  }
}

test("ticking shares a server, a crash restarts it, unticking puts the entry back", windowsOnly, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcp-keeper-test-"));
  const claudeJson = path.join(dir, ".claude.json");
  const original = { type: "stdio", command: process.execPath, args: [path.join(PLUGIN, "test", "windows-mcp"), "serve"], env: { FAKE_TOKEN: "t0ken" } };
  fs.writeFileSync(
    claudeJson,
    JSON.stringify({
      projects: {},
      mcpServers: {
        win: original,
        plain: { type: "stdio", command: "some-stdio-server", args: [] },
        remote: { type: "http", url: "https://example.com/mcp" },
      },
    }),
  );
  Object.assign(process.env, {
    MCP_KEEPER_CLAUDE_JSON: claudeJson,
    MCP_KEEPER_CLAUDE: process.execPath,
    MCP_KEEPER_CLAUDE_ARGS: path.join(PLUGIN, "test", "fake-claude"),
    MCP_KEEPER_PORT_OFFSET: "10000",
  });
  const servers = () => JSON.parse(fs.readFileSync(claudeJson, "utf8")).mcpServers;
  const host = startMockHost(PLUGIN, { dataDir: dir, timeoutMs: 60000 });
  try {
    host.viewVisible("servers", true);
    const page = await host.waitFor((h) => h.views.get("servers")?.groups);
    const [shareable, single] = page;
    assert.deepEqual(shareable.items.map((i) => [i.id, i.checked]), [["win", false]]);
    assert.deepEqual(single.items.map((i) => [i.id, i.checked]), [["plain", undefined]]);
    assert.ok(!page.some((g) => g.items.some((i) => i.id === "remote")), "remote addresses are not listed");

    host.viewAction("servers", "check", { itemId: "win", checked: true });
    await host.waitFor(() => servers().win?.type === "http");
    assert.deepEqual(servers().win, { type: "http", url: `http://127.0.0.1:${PORT}/mcp` });
    assert.deepEqual(JSON.parse(host.secrets.get("orig-win")), original);
    const first = await ask(PORT);
    assert.equal(first.token, "t0ken", "the original env reaches the server");

    process.kill(first.pid);
    await host.waitForLog(/win exited; restart #1/);
    let second = null;
    for (let i = 0; i < 60 && !(second && second.pid !== first.pid); i++) {
      await new Promise((resolve) => setTimeout(resolve, 500));
      second = await ask(PORT);
    }
    assert.ok(second && second.pid !== first.pid, "a new server answers on the same port");

    host.viewAction("servers", "check", { itemId: "win", checked: false });
    await host.waitFor((h) => !h.secrets.has("orig-win"));
    assert.deepEqual(servers().win, original);
    assert.equal(await ask(PORT), null, "the server is stopped");
  } finally {
    await host.stop();
  }
});

test("a switch cut short by a stop is finished on the next start", windowsOnly, async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "mcp-keeper-test-"));
  const claudeJson = path.join(dir, ".claude.json");
  const original = { type: "stdio", command: process.execPath, args: [path.join(PLUGIN, "test", "windows-mcp"), "serve"], env: { FAKE_TOKEN: "t0ken" } };
  fs.writeFileSync(claudeJson, JSON.stringify({ mcpServers: { win: original } }));
  Object.assign(process.env, {
    MCP_KEEPER_CLAUDE_JSON: claudeJson,
    MCP_KEEPER_CLAUDE: process.execPath,
    MCP_KEEPER_CLAUDE_ARGS: path.join(PLUGIN, "test", "fake-claude"),
    MCP_KEEPER_PORT_OFFSET: "10000",
  });
  const host = startMockHost(PLUGIN, {
    dataDir: dir,
    timeoutMs: 60000,
    storage: { managed: { win: PORT } },
    secrets: { "orig-win": JSON.stringify(original) },
  });
  try {
    await host.waitFor(() => JSON.parse(fs.readFileSync(claudeJson, "utf8")).mcpServers.win?.type === "http");
    assert.equal((await ask(PORT)).token, "t0ken");
  } finally {
    await host.stop();
  }
});
