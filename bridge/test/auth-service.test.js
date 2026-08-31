import assert from "node:assert/strict";
import test from "node:test";

import { AccountAuthService, AuthServiceError } from "../src/auth-service.js";
import { ProfileAppServerCoordinator } from "../src/profile-app-server-coordinator.js";

function liveConfig(profiles) {
  return {
    mode: "live",
    codexCommand: "/opt/codex",
    requestTimeoutMs: 500,
    profiles,
  };
}

function fakeClientFactory({ accounts = new Map(), ceremonies = new Map() } = {}) {
  const clients = [];
  const factory = (options) => {
    const notificationHandlers = new Set();
    const closeHandlers = new Set();
    const calls = [];
    const client = {
      options,
      calls,
      closed: false,
      async initialize() {
        calls.push(["initialize"]);
      },
      async readAccount() {
        calls.push(["account/read", { refreshToken: false }]);
        const configured = accounts.get(options.codexHome);
        if (Array.isArray(configured)) return configured.shift();
        if (configured instanceof Error) throw configured;
        return configured ?? { account: null, requiresOpenaiAuth: true };
      },
      async startDeviceCodeLogin() {
        calls.push(["account/login/start", { type: "chatgptDeviceCode" }]);
        const configured = ceremonies.get(options.codexHome);
        if (configured instanceof Error) throw configured;
        return (
          configured ?? {
            type: "chatgptDeviceCode",
            loginId: "login-default",
            verificationUrl: "https://auth.openai.com/codex/device",
            userCode: "ABCD-1234",
          }
        );
      },
      async cancelLogin(loginId) {
        calls.push(["account/login/cancel", { loginId }]);
        return {};
      },
      async logout() {
        calls.push(["account/logout"]);
        accounts.set(options.codexHome, { account: null, requiresOpenaiAuth: true });
        return {};
      },
      onNotification(handler) {
        notificationHandlers.add(handler);
        return () => notificationHandlers.delete(handler);
      },
      onClose(handler) {
        closeHandlers.add(handler);
        return () => closeHandlers.delete(handler);
      },
      emitNotification(method, params) {
        for (const handler of notificationHandlers) handler(method, params);
      },
      emitUnexpectedClose() {
        for (const handler of closeHandlers) handler(new Error("private transport detail"));
      },
      close() {
        this.closed = true;
        notificationHandlers.clear();
        closeHandlers.clear();
      },
    };
    clients.push(client);
    return client;
  };
  return { factory, clients };
}

test("lists configured homes without exposing account identity or auth material", async () => {
  const profiles = [
    { id: "account-a", displayName: "A", codexHome: "/profiles/a" },
    { id: "account-b", displayName: "B", codexHome: "/profiles/b" },
    { id: "account-c", displayName: "C", codexHome: "/profiles/c" },
  ];
  const accounts = new Map([
    [
      "/profiles/a",
      {
        account: {
          type: "chatgpt",
          email: "private@example.test",
          planType: "plus",
          accessToken: "raw-secret",
        },
      },
    ],
    ["/profiles/b", { account: null, requiresOpenaiAuth: true }],
    ["/profiles/c", { account: { type: "apiKey", apiKey: "sk-secret" } }],
  ]);
  const fake = fakeClientFactory({ accounts });
  const service = new AccountAuthService(liveConfig(profiles), {
    clientFactory: fake.factory,
    profileCoordinator: new ProfileAppServerCoordinator(),
  });

  const result = await service.listAccounts();

  assert.equal(result.maxAccounts, 3);
  assert.deepEqual(
    result.accounts.map(({ id, status, authMode, planType }) => ({
      id,
      status,
      authMode,
      planType,
    })),
    [
      { id: "account-a", status: "signed_in", authMode: "chatgpt", planType: "plus" },
      { id: "account-b", status: "signed_out", authMode: null, planType: null },
      { id: "account-c", status: "error", authMode: null, planType: null },
    ],
  );
  assert.deepEqual(
    fake.clients.map((client) => client.options.codexHome).sort(),
    ["/profiles/a", "/profiles/b", "/profiles/c"],
  );
  const serialized = JSON.stringify(result);
  assert.equal(serialized.includes("private@example.test"), false);
  assert.equal(serialized.includes("raw-secret"), false);
  assert.equal(serialized.includes("sk-secret"), false);
});

test("runs the documented device-code lifecycle and verifies success with account/read", async () => {
  const profile = { id: "account-a", displayName: "A", codexHome: "/profiles/a" };
  const accounts = new Map([
    [
      profile.codexHome,
      [
        { account: null, requiresOpenaiAuth: true },
        { account: { type: "chatgpt", email: "never-return@example.test", planType: "pro" } },
      ],
    ],
  ]);
  const ceremonies = new Map([
    [
      profile.codexHome,
      {
        type: "chatgptDeviceCode",
        loginId: "login-a",
        verificationUrl: "https://auth.openai.com/codex/device",
        userCode: "WXYZ-9876",
        accessToken: "must-not-escape",
      },
    ],
  ]);
  const changed = [];
  const fake = fakeClientFactory({ accounts, ceremonies });
  const service = new AccountAuthService(liveConfig([profile]), {
    clientFactory: fake.factory,
    profileCoordinator: new ProfileAppServerCoordinator(),
    now: () => Date.parse("2026-08-30T12:00:00.000Z"),
    onProfileAuthChanged: (id, authenticated) => changed.push([id, authenticated]),
  });

  const started = await service.startDeviceLogin(profile.id);
  assert.deepEqual(started, {
    accountId: "account-a",
    loginId: "login-a",
    status: "pending",
    expiresAt: "2026-08-30T12:10:00.000Z",
    intervalSeconds: 2,
    verificationUrl: "https://auth.openai.com/codex/device",
    userCode: "WXYZ-9876",
  });
  assert.deepEqual(
    fake.clients[0].calls.slice(0, 3),
    [
      ["initialize"],
      ["account/read", { refreshToken: false }],
      ["account/login/start", { type: "chatgptDeviceCode" }],
    ],
  );
  await assert.rejects(service.startDeviceLogin(profile.id), (error) => {
    assert.ok(error instanceof AuthServiceError);
    assert.equal(error.code, "login_in_progress");
    assert.equal(error.statusCode, 409);
    return true;
  });

  fake.clients[0].emitNotification("account/login/completed", {
    loginId: "login-a",
    success: true,
    error: null,
  });
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(service.getDeviceLogin("login-a").status, "succeeded");
  assert.equal(fake.clients[0].closed, true);
  assert.deepEqual(changed, [["account-a", true]]);
  const serialized = JSON.stringify(service.getDeviceLogin("login-a"));
  assert.equal(serialized.includes("never-return@example.test"), false);
  assert.equal(serialized.includes("must-not-escape"), false);
});

test("fails closed for an unexpected verification URL and transport close", async () => {
  const profile = { id: "account-a", displayName: "A", codexHome: "/profiles/a" };
  const accounts = new Map([[profile.codexHome, { account: null }]]);
  const badCeremony = fakeClientFactory({
    accounts,
    ceremonies: new Map([
      [
        profile.codexHome,
        {
          type: "chatgptDeviceCode",
          loginId: "login-bad",
          verificationUrl: "https://phishing.example/device",
          userCode: "ABCD-1234",
        },
      ],
    ]),
  });
  const rejected = new AccountAuthService(liveConfig([profile]), {
    clientFactory: badCeremony.factory,
  });
  await assert.rejects(rejected.startDeviceLogin(profile.id), {
    code: "auth_unavailable",
    statusCode: 503,
  });
  assert.equal(badCeremony.clients[0].closed, true);

  const valid = fakeClientFactory({ accounts });
  const service = new AccountAuthService(liveConfig([profile]), {
    clientFactory: valid.factory,
  });
  const started = await service.startDeviceLogin(profile.id);
  valid.clients[0].emitUnexpectedClose();
  assert.equal(service.getDeviceLogin(started.loginId).status, "failed");
  assert.equal(JSON.stringify(service.getDeviceLogin(started.loginId)).includes("private"), false);
});

test("cancels a pending login and logs out without deleting its CODEX_HOME", async () => {
  const profile = { id: "account-a", displayName: "A", codexHome: "/profiles/a" };
  const accounts = new Map([[profile.codexHome, { account: null }]]);
  const fake = fakeClientFactory({ accounts });
  const changed = [];
  const service = new AccountAuthService(liveConfig([profile]), {
    clientFactory: fake.factory,
    profileCoordinator: new ProfileAppServerCoordinator(),
    onProfileAuthChanged: (id, authenticated) => changed.push([id, authenticated]),
  });

  const started = await service.startDeviceLogin(profile.id);
  const cancelled = await service.cancelDeviceLogin(started.loginId);
  assert.equal(cancelled.status, "cancelled");
  assert.deepEqual(fake.clients[0].calls.at(-1), [
    "account/login/cancel",
    { loginId: started.loginId },
  ]);

  accounts.set(profile.codexHome, {
    account: { type: "chatgpt", email: "private@example.test", planType: "plus" },
  });
  const loggedOut = await service.logoutAccount(profile.id);
  assert.deepEqual(loggedOut, { accountId: profile.id, status: "signed_out" });
  assert.deepEqual(fake.clients[1].calls, [["initialize"], ["account/logout"]]);
  assert.deepEqual(changed, [[profile.id, false]]);
});

test("expires abandoned logins and prunes terminal sessions", async () => {
  const profile = { id: "account-a", displayName: "A", codexHome: "/profiles/a" };
  const fake = fakeClientFactory({
    accounts: new Map([[profile.codexHome, { account: null }]]),
  });
  let now = Date.parse("2026-08-30T12:00:00.000Z");
  const service = new AccountAuthService(liveConfig([profile]), {
    clientFactory: fake.factory,
    now: () => now,
    loginLifetimeMs: 10,
    terminalSessionRetentionMs: 5,
  });

  const started = await service.startDeviceLogin(profile.id);
  await new Promise((resolve) => setTimeout(resolve, 20));
  assert.equal(service.getDeviceLogin(started.loginId).status, "failed");
  assert.equal(fake.clients[0].closed, true);
  assert.deepEqual(fake.clients[0].calls.at(-1), [
    "account/login/cancel",
    { loginId: started.loginId },
  ]);

  now += 10;
  assert.throws(() => service.getDeviceLogin(started.loginId), {
    code: "login_not_found",
    statusCode: 404,
  });
});
