import assert from "node:assert/strict";
import { EventEmitter } from "node:events";
import { PassThrough } from "node:stream";
import test from "node:test";

import { AppServerClient, fetchProfileRateLimits } from "../src/app-server-client.js";

function createFakeSpawner(rateLimitsResult, recorded) {
  return (command, arguments_, options) => {
    recorded.spawn = { command, arguments_, options };

    const child = new EventEmitter();
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.exitCode = null;
    child.kill = (signal) => {
      recorded.killSignal = signal;
      child.exitCode = 0;
      queueMicrotask(() => child.emit("close", 0));
      return true;
    };

    let input = "";
    child.stdin.on("data", (chunk) => {
      input += chunk.toString("utf8");
      let newline;
      while ((newline = input.indexOf("\n")) >= 0) {
        const message = JSON.parse(input.slice(0, newline));
        input = input.slice(newline + 1);
        recorded.messages.push(message);

        if (message.method === "initialize") {
          child.stdout.write(`${JSON.stringify({ id: message.id, result: { userAgent: "fake" } })}\n`);
        }
        if (message.method === "account/rateLimits/read") {
          child.stdout.write(`${JSON.stringify({ id: message.id, result: rateLimitsResult })}\n`);
        }
      }
    });
    return child;
  };
}

test("uses the documented stdio handshake before reading rate limits", async () => {
  const raw = {
    rateLimits: {
      primary: { usedPercent: 25, windowDurationMins: 15, resetsAt: 2_000_000_000 },
    },
  };
  const recorded = { messages: [] };

  const result = await fetchProfileRateLimits(
    { codexHome: "/profiles/a" },
    {
      codexCommand: "/usr/local/bin/codex",
      requestTimeoutMs: 500,
      spawnProcess: createFakeSpawner(raw, recorded),
    },
  );

  assert.deepEqual(result, raw);
  assert.equal(recorded.spawn.command, "/usr/local/bin/codex");
  assert.deepEqual(recorded.spawn.arguments_, [
    "app-server",
    "-c",
    'cli_auth_credentials_store="file"',
  ]);
  assert.equal(recorded.spawn.options.env.CODEX_HOME, "/profiles/a");
  assert.deepEqual(
    recorded.messages.map((message) => message.method),
    ["initialize", "initialized", "account/rateLimits/read"],
  );
  assert.equal(recorded.messages[0].params.clientInfo.name, "watch_overlay_bridge");
  assert.equal(recorded.killSignal, "SIGTERM");
});

test("does not forward the bridge bearer token to the Codex child", async () => {
  const original = process.env.WATCH_OVERLAY_BRIDGE_TOKEN;
  const originalApiKey = process.env.OPENAI_API_KEY;
  const originalAccessToken = process.env.CODEX_ACCESS_TOKEN;
  process.env.WATCH_OVERLAY_BRIDGE_TOKEN = "bridge-only-secret";
  process.env.OPENAI_API_KEY = "unrelated-api-key";
  process.env.CODEX_ACCESS_TOKEN = "unrelated-access-token";
  const recorded = { messages: [] };

  try {
    await fetchProfileRateLimits(
      { codexHome: "/profiles/a" },
      {
        requestTimeoutMs: 500,
        spawnProcess: createFakeSpawner(
          {
            rateLimits: {
              primary: { usedPercent: 25, windowDurationMins: 15, resetsAt: 2_000_000_000 },
            },
          },
          recorded,
        ),
      },
    );
  } finally {
    if (original === undefined) {
      delete process.env.WATCH_OVERLAY_BRIDGE_TOKEN;
    } else {
      process.env.WATCH_OVERLAY_BRIDGE_TOKEN = original;
    }
    if (originalApiKey === undefined) delete process.env.OPENAI_API_KEY;
    else process.env.OPENAI_API_KEY = originalApiKey;
    if (originalAccessToken === undefined) delete process.env.CODEX_ACCESS_TOKEN;
    else process.env.CODEX_ACCESS_TOKEN = originalAccessToken;
  }

  assert.equal(recorded.spawn.options.env.WATCH_OVERLAY_BRIDGE_TOKEN, undefined);
  assert.equal(recorded.spawn.options.env.OPENAI_API_KEY, undefined);
  assert.equal(recorded.spawn.options.env.CODEX_ACCESS_TOKEN, undefined);
});

test("uses documented account methods and delivers login notifications", async () => {
  const recorded = { messages: [], notifications: [] };
  const spawnProcess = (command, arguments_, options) => {
    recorded.spawn = { command, arguments_, options };
    const child = new EventEmitter();
    child.stdin = new PassThrough();
    child.stdout = new PassThrough();
    child.stderr = new PassThrough();
    child.exitCode = null;
    child.kill = () => {
      child.exitCode = 0;
      return true;
    };
    recorded.child = child;
    let input = "";
    child.stdin.on("data", (chunk) => {
      input += chunk.toString("utf8");
      let newline;
      while ((newline = input.indexOf("\n")) >= 0) {
        const message = JSON.parse(input.slice(0, newline));
        input = input.slice(newline + 1);
        recorded.messages.push(message);
        const responses = {
          initialize: { userAgent: "fake" },
          "account/read": { account: null, requiresOpenaiAuth: true },
          "account/login/start": {
            type: "chatgptDeviceCode",
            loginId: "login-a",
            verificationUrl: "https://auth.openai.com/codex/device",
            userCode: "ABCD-1234",
          },
          "account/login/cancel": {},
          "account/logout": {},
        };
        if (Object.hasOwn(responses, message.method)) {
          child.stdout.write(`${JSON.stringify({ id: message.id, result: responses[message.method] })}\n`);
        }
      }
    });
    return child;
  };

  const client = new AppServerClient({
    codexHome: "/profiles/a",
    requestTimeoutMs: 500,
    spawnProcess,
  });
  client.onNotification((method, params) => recorded.notifications.push([method, params]));
  await client.initialize();
  await client.readAccount();
  const login = await client.startDeviceCodeLogin();
  recorded.child.stdout.write(
    `${JSON.stringify({
      method: "account/login/completed",
      params: { loginId: login.loginId, success: true, error: null },
    })}\n`,
  );
  await new Promise((resolve) => setImmediate(resolve));
  client.notify("client/test-notification", { safe: true });
  await client.cancelLogin(login.loginId);
  await client.logout();
  client.close();

  assert.deepEqual(recorded.notifications, [
    [
      "account/login/completed",
      { loginId: "login-a", success: true, error: null },
    ],
  ]);
  assert.deepEqual(
    recorded.messages.map(({ method, params }) => [method, params]),
    [
      ["initialize", { clientInfo: { name: "watch_overlay_bridge", title: "CodexMeter Bridge", version: "0.1.0" } }],
      ["initialized", {}],
      ["account/read", { refreshToken: false }],
      ["account/login/start", { type: "chatgptDeviceCode" }],
      ["client/test-notification", { safe: true }],
      ["account/login/cancel", { loginId: "login-a" }],
      ["account/logout", undefined],
    ],
  );
});

test("treats malformed app-server output as a transport failure", async () => {
  let child;
  const client = new AppServerClient({
    codexHome: "/profiles/a",
    spawnProcess: () => {
      child = new EventEmitter();
      child.stdin = new PassThrough();
      child.stdout = new PassThrough();
      child.stderr = new PassThrough();
      child.exitCode = null;
      child.kill = () => true;
      return child;
    },
  });
  let failures = 0;
  client.onClose(() => {
    failures += 1;
  });

  child.stdout.write("{not-json}\n");
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(failures, 1);
  client.close();
});
