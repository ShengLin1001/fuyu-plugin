// Runs main.ps1 under the mock host against a fake NTP server on 127.0.0.1, so the offset is known.
import assert from "node:assert/strict";
import dgram from "node:dgram";
import test from "node:test";
import { startMockHost } from "fuyu-plugin/test";

const NTP_EPOCH = 2208988800;

function ntpTime(buffer, at, ms) {
  const seconds = ms / 1000 + NTP_EPOCH;
  buffer.writeUInt32BE(Math.floor(seconds), at);
  buffer.writeUInt32BE(Math.floor((seconds % 1) * 2 ** 32), at + 4);
}

// An SNTP server whose clock is `aheadSeconds` ahead of this computer's.
async function startNtp(aheadSeconds) {
  const socket = dgram.createSocket("udp4");
  socket.on("message", (request, remote) => {
    const reply = Buffer.alloc(48);
    reply[0] = 0x24; // version 4, server
    reply[1] = 2; // stratum
    request.copy(reply, 24, 40, 48); // originate = the client's transmit
    const now = Date.now() + aheadSeconds * 1000;
    ntpTime(reply, 32, now);
    ntpTime(reply, 40, now);
    socket.send(reply, remote.port, remote.address);
  });
  await new Promise((resolve) => socket.bind(0, "127.0.0.1", resolve));
  return socket;
}

function start(ntp, options = {}) {
  const server = "127.0.0.1:" + ntp.address().port;
  return startMockHost(".", {
    timeoutMs: 60000, // PowerShell starts slowly on a busy machine
    command: ["powershell.exe", ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File", "main.ps1", "-Server", server]],
    ...options,
  });
}

test("the page shows a clock within a second as right", { timeout: 90000 }, async () => {
  const ntp = await startNtp(0);
  const host = start(ntp);
  try {
    host.viewVisible("main");
    const model = await host.waitForView("main", (m) => m.items?.length === 3);
    const clock = model.items.find((item) => item.id === "clock");
    assert.equal(clock.note.en, "OK");
    assert.match(clock.subtitle.en, /^Within [0-9.]+ s of 127\.0\.0\.1/);
    assert.deepEqual(model.items.map((item) => item.id), ["clock", "task", "zone"]);
  } finally {
    await host.stop();
    ntp.close();
  }
});

test("a clock an hour slow is reported as slow", { timeout: 90000 }, async () => {
  const ntp = await startNtp(3600 + 28 * 60);
  // English messages, so the assertion does not depend on escapes.
  const host = start(ntp, { settings: { language: "en" } });
  try {
    host.viewVisible("main");
    const model = await host.waitForView("main", (m) => m.items?.some((item) => item.id === "clock" && item.note.en === "Off"));
    const clock = model.items.find((item) => item.id === "clock");
    assert.match(clock.subtitle.en, /^1 h 28 min slow against 127\.0\.0\.1/);
    assert.match(clock.subtitle["zh-CN"], /慢 1 小时 28 分/);
    // Without the task installed it asks for it (with the task, it would resync this machine).
    if (!model.items.find((item) => item.id === "task").actions.some((action) => action.id === "uninstall")) {
      assert.equal(host.notifications[0]?.title, "The clock was 1 h 28 min slow");
      assert.equal(host.notifications[0].actions[0].id, "install");
    }
  } finally {
    await host.stop();
    ntp.close();
  }
});
