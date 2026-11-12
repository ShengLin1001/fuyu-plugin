// The battery plugin under the mock host. What it
// reads depends on the machine (a battery, paired Bluetooth devices), so this checks that the
// script runs on Windows PowerShell 5.1 (its C# compiles, the readings come back) and that
// whatever it shows is well-formed.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import path from "node:path";
import test from "node:test";
import { startMockHost } from "fuyu-plugin/test";

const PLUGIN = path.resolve(import.meta.dirname, "..");
const windowsOnly = { skip: process.platform !== "win32" };
const PERCENT = /^(\d|[1-9]\d|100)%$/;

test("the plugin stays running and shows well-formed levels on the bar and the page", windowsOnly, async () => {
  const host = startMockHost(PLUGIN, { timeoutMs: 60000 });
  try {
    assert.match((await host.waitForRequest("host.keepAlive")).params.reason, /battery/i);
    const page = await host.waitForView("levels");
    assert.equal(host.logs.filter((line) => /error/i.test(line)).length, 0, host.logs.join("\n"));
    assert.ok(page.empty["zh-CN"].includes("蓝牙") && page.empty.en.includes("Bluetooth"), "the escapes turn into Chinese text");

    const items = page.groups.flatMap((group) => group.items);
    assert.equal(new Set(items.map((item) => item.id)).size, items.length, "ids are unique");
    for (const item of items) assert.match(item.note, /^(-|(\d|[1-9]\d|100)%)$/, item.id);

    const battery = host.statuses.get("battery");
    assert.ok(battery !== undefined || !items.some((item) => item.id === "pc"), "the bar item is there when the page lists this computer");
    if (battery) {
      // One upright battery per level in the text, this computer's first.
      const lpercent = battery.text.split(" ");
      for (const percent of lpercent) assert.match(percent, PERCENT);
      assert.ok(lpercent.length <= 4 && battery.tooltip.startsWith(`PC ${lpercent[0]}`) && battery.tooltip.length <= 200);
      assert.deepEqual(battery.batteries.map((drawn) => drawn.level), lpercent.map((percent) => Number.parseInt(percent, 10) / 100));
      for (const drawn of battery.batteries) assert.ok(["neutral", "warning", "danger"].includes(drawn.tone));
    }

    // Opening the page reads again and sends the list anew.
    const updates = host.requests.filter((request) => request.method === "view.update").length;
    host.viewVisible("levels", true);
    await host.waitFor((h) => h.requests.filter((request) => request.method === "view.update").length > updates);
  } finally {
    await host.stop();
  }
});

test("the earphone listener builds on this Windows and decodes a broadcast", windowsOnly, () => {
  // A proximity pairing message of model 0x2036: pod levels 4 and 3 (tenths), no case level.
  // Status 0x21 puts the left pod in the low half of 0x43; without bit 0x20 the halves swap.
  const decode = (status) => `[FocusdAppleAdverts]::Decode([byte[]](7, 25, 1, 0x36, 0x20, ${status}, 0x43, 0x8F, 0x10)) -join ' '`;
  const script = `. '${path.join(PLUGIN, "power.ps1")}'; Import-AppleAdverts; ${decode("0x21")}; ${decode("0x01")}; $null -eq [FocusdAppleAdverts]::Decode([byte[]](16, 5, 1))`;
  const output = execFileSync("powershell.exe", ["-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", script], { encoding: "utf8" });
  assert.deepEqual(output.trim().split(/\r?\n/), ["8246 30 40 -1", "8246 40 30 -1", "True"]);
});
