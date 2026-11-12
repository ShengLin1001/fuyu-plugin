// The job-queue plugin under the mock host, with a fake ssh (fake-ssh) standing in for three
// clusters: one that answers, one whose squeue fails once, one that cannot be reached. Whether
// WSL is running on this machine varies, so its group (local: true) is left out of the checks.
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { startMockHost } from "fuyu-plugin/test";

const PLUGIN = path.resolve(import.meta.dirname, "..");
const windowsOnly = { skip: process.platform !== "win32" };

// The island's data folder with its list of remote computers, and the plugin's folder two below.
function makeAppDir() {
  const appDir = fs.mkdtempSync(path.join(os.tmpdir(), "squeue-test-"));
  const dataDir = path.join(appDir, "plugins-data", "io.github.shenglin1001.squeue");
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(
    path.join(appDir, "agent-remote-hosts.json"),
    JSON.stringify({
      hosts: ["ok-host", "flaky", "idle-host", "down-host", "custom1", "-oProxyCommand=evil"],
      custom: [{ name: "custom1", user: "me", host: "ok-host", port: 2222 }],
    }),
  );
  return { appDir, dataDir };
}

test("the bar sums every computer, a failed query is retried, the page lists the jobs", windowsOnly, async () => {
  const { appDir, dataDir } = makeAppDir();
  process.env.FUYU_SQUEUE_SSH = path.join(PLUGIN, "test", "fake-ssh.cmd");
  process.env.FAKE_SSH_STATE = appDir;
  const host = startMockHost(PLUGIN, { dataDir, timeoutMs: 60000 });
  try {
    assert.match((await host.waitForRequest("host.keepAlive")).params.reason, /Slurm/);

    // ok-host and custom1 have R, PD and CF each; flaky fails first, is asked again 5 s later
    // and then has one CG job.
    const bars = () => host.requests.filter((r) => r.method === "status.update").map((r) => r.params);
    const last = await host.waitFor((h) => h.statuses.get("queue")?.text === "R2 PD2 CG1 +2" && h.statuses.get("queue"));
    assert.ok(bars().some((bar) => /flaky/.test(bar.tooltip) && bar.text.startsWith("R")), "the bar said flaky was failing meanwhile");
    assert.doesNotMatch(last.tooltip, /flaky/);
    assert.ok(last.tooltip.length <= 200);
    assert.equal(last.pie, undefined, "no pie on an island without statusPie");

    host.viewVisible("jobs", true);
    host.webviewMessage("jobs", { type: "ready", locale: "en" });
    const page = await host.waitFor((h) => h.webviewMessages.findLast((m) => m.message.type === "jobs")?.message);
    const hosts = page.hosts.filter((h) => !h.local);
    // The island's order; the name that would be read as an option is dropped.
    assert.deepEqual(hosts.map((h) => h.name), ["ok-host", "flaky", "idle-host", "down-host", "custom1"]);

    const [ok, flaky, idle, down, custom] = hosts;
    assert.deepEqual(ok.counts, { R: 1, PD: 1, CG: 0, other: 1 });
    assert.equal(ok.error, null);
    assert.deepEqual(ok.jobs.map((job) => job.state), ["R", "PD", "CF"]);
    const pending = ok.jobs.find((job) => job.id === "102");
    assert.equal(pending.workdir, "/home/me/proj/a|b/strain/0.04", "a '|' in the last field stays in it");
    assert.equal(pending.reason, "(Priority)");
    assert.equal(pending.gres, "gres/gpu:2");
    assert.equal(pending.name, "scf_hcp");

    assert.equal(flaky.error, null);
    assert.equal(flaky.jobs.length, 1);
    assert.equal(idle.error, null, "an empty queue is an answer, not a failure");
    assert.deepEqual(idle.jobs, []);
    assert.ok(idle.updatedAt > 0);
    assert.match(down.error, /Connection refused/);
    assert.equal(down.jobs.length, 0);
    assert.ok(down.failingSince > 0);
    assert.deepEqual(custom.counts, ok.counts, "the custom computer is reached as me@ok-host -p 2222");

    // The page said the island speaks English: the bar's tooltip follows.
    await host.waitFor((h) => h.statuses.get("queue")?.tooltip.includes("other"));
    assert.equal(host.storage.get("locale"), "en");
    assert.equal(host.logs.filter((line) => /^error/i.test(line)).length, 0, host.logs.join("\n"));
  } finally {
    await host.stop();
    delete process.env.FUYU_SQUEUE_SSH;
    fs.rmSync(appDir, { recursive: true, force: true });
  }
});

test("with no computer ticked the bar says so", windowsOnly, async () => {
  const host = startMockHost(PLUGIN, { timeoutMs: 60000 });
  try {
    const status = await host.waitFor((h) => h.statuses.get("queue"));
    assert.match(status.text, /^R\d+ PD\d+ CG\d+/);
    // Unless WSL runs Slurm here, there is nothing to ask.
    if (status.text === "R0 PD0 CG0") assert.match(status.tooltip, /AI Agent/);
  } finally {
    await host.stop();
  }
});
