import assert from "node:assert/strict";
import { Readable } from "node:stream";
import test from "node:test";

import { AuthServiceError } from "../src/auth-service.js";
import { createRequestHandler } from "../src/http-server.js";

async function invokeHandler(
  handler,
  { method = "GET", url = "/v1/accounts", headers = {}, body = "" } = {},
) {
  const request = Readable.from(body === "" ? [] : [body]);
  request.method = method;
  request.url = url;
  request.headers = headers;

  const responseHeaders = new Map();
  let statusCode;
  let responseBody = "";
  const response = {
    setHeader(name, value) {
      responseHeaders.set(name.toLowerCase(), value);
    },
    writeHead(status, values = {}) {
      statusCode = status;
      for (const [name, value] of Object.entries(values)) {
        responseHeaders.set(name.toLowerCase(), value);
      }
    },
    end(chunk = "") {
      responseBody += chunk;
    },
  };

  await handler(request, response);
  return {
    statusCode,
    headers: responseHeaders,
    json: JSON.parse(responseBody),
  };
}

test("auth HTTP routes require the bridge bearer and expose only the public contract", async () => {
  const calls = [];
  const authService = {
    async listAccounts() {
      calls.push(["list"]);
      return {
        maxAccounts: 3,
        accounts: [
          {
            id: "account-a",
            displayName: "A",
            status: "signed_out",
            authMode: null,
            planType: null,
          },
        ],
      };
    },
    async startDeviceLogin(accountId) {
      calls.push(["start", accountId]);
      return {
        accountId,
        loginId: "login-a",
        status: "pending",
        expiresAt: "2026-08-30T12:10:00.000Z",
        intervalSeconds: 2,
        verificationUrl: "https://auth.openai.com/codex/device",
        userCode: "ABCD-1234",
      };
    },
    getDeviceLogin(loginId) {
      calls.push(["read", loginId]);
      return { accountId: "account-a", loginId, status: "succeeded" };
    },
    async cancelDeviceLogin(loginId) {
      calls.push(["cancel", loginId]);
      return { accountId: "account-a", loginId, status: "cancelled" };
    },
    async logoutAccount(accountId) {
      calls.push(["logout", accountId]);
      return { accountId, status: "signed_out" };
    },
  };
  const token = "long-private-bridge-token";
  const handler = createRequestHandler({
    service: { getSnapshot: async () => ({}) },
    authService,
    bearerToken: token,
  });

  for (const request of [
    {},
    { method: "POST", url: "/v1/auth/device/start" },
    { url: "/v1/auth/device/login-a" },
    { method: "DELETE", url: "/v1/auth/device/login-a" },
    { method: "DELETE", url: "/v1/accounts/account-a" },
  ]) {
    const unauthorized = await invokeHandler(handler, request);
    assert.equal(unauthorized.statusCode, 401);
    assert.deepEqual(unauthorized.json, { error: "unauthorized" });
  }

  const authorization = `Bearer ${token}`;
  const listed = await invokeHandler(handler, { headers: { authorization } });
  assert.equal(listed.statusCode, 200);
  assert.equal(listed.headers.get("cache-control"), "no-store");
  assert.equal(listed.headers.get("access-control-allow-origin"), undefined);

  const started = await invokeHandler(handler, {
    method: "POST",
    url: "/v1/auth/device/start",
    headers: { authorization, "content-type": "application/json; charset=utf-8" },
    body: JSON.stringify({ accountId: "account-a" }),
  });
  assert.equal(started.statusCode, 201);
  assert.equal(started.json.userCode, "ABCD-1234");

  const read = await invokeHandler(handler, {
    url: "/v1/auth/device/login-a",
    headers: { authorization },
  });
  assert.equal(read.json.status, "succeeded");

  const cancelled = await invokeHandler(handler, {
    method: "DELETE",
    url: "/v1/auth/device/login-a",
    headers: { authorization },
  });
  assert.equal(cancelled.json.status, "cancelled");

  const loggedOut = await invokeHandler(handler, {
    method: "DELETE",
    url: "/v1/accounts/account-a",
    headers: { authorization },
  });
  assert.deepEqual(loggedOut.json, { accountId: "account-a", status: "signed_out" });
  assert.deepEqual(calls, [
    ["list"],
    ["start", "account-a"],
    ["read", "login-a"],
    ["cancel", "login-a"],
    ["logout", "account-a"],
  ]);
});

test("auth HTTP routes reject malformed bodies and sanitize every failure", async () => {
  const authorization = "Bearer long-private-bridge-token";
  let starts = 0;
  const authService = {
    async startDeviceLogin() {
      starts += 1;
      throw new Error("private@example.test raw-access-token");
    },
    getDeviceLogin() {
      throw new AuthServiceError("login_not_found", 404);
    },
  };
  const handler = createRequestHandler({
    service: { getSnapshot: async () => ({}) },
    authService,
    bearerToken: "long-private-bridge-token",
  });

  const noContentType = await invokeHandler(handler, {
    method: "POST",
    url: "/v1/auth/device/start",
    headers: { authorization },
    body: JSON.stringify({ accountId: "account-a" }),
  });
  assert.deepEqual(noContentType.json, { error: "unsupported_media_type" });
  assert.equal(noContentType.statusCode, 415);

  const oversized = await invokeHandler(handler, {
    method: "POST",
    url: "/v1/auth/device/start",
    headers: { authorization, "content-type": "application/json" },
    body: "x".repeat(4_097),
  });
  assert.equal(oversized.statusCode, 413);
  assert.deepEqual(oversized.json, { error: "body_too_large" });

  const extraField = await invokeHandler(handler, {
    method: "POST",
    url: "/v1/auth/device/start",
    headers: { authorization, "content-type": "application/json" },
    body: JSON.stringify({ accountId: "account-a", accessToken: "secret" }),
  });
  assert.deepEqual(extraField.json, { error: "bad_request" });

  const unavailable = await invokeHandler(handler, {
    method: "POST",
    url: "/v1/auth/device/start",
    headers: { authorization, "content-type": "application/json" },
    body: JSON.stringify({ accountId: "account-a" }),
  });
  assert.equal(unavailable.statusCode, 503);
  assert.deepEqual(unavailable.json, { error: "auth_unavailable" });
  assert.equal(JSON.stringify(unavailable).includes("private@example.test"), false);

  const notFound = await invokeHandler(handler, {
    url: "/v1/auth/device/unknown",
    headers: { authorization },
  });
  assert.equal(notFound.statusCode, 404);
  assert.deepEqual(notFound.json, { error: "login_not_found" });

  const malformedId = await invokeHandler(handler, {
    url: "/v1/auth/device/%E0%A4%A",
    headers: { authorization },
  });
  assert.equal(malformedId.statusCode, 400);
  assert.deepEqual(malformedId.json, { error: "bad_request" });
  assert.equal(starts, 1);
});

test("mutable auth routes stay disabled when the bridge has no bearer token", async () => {
  let called = false;
  const handler = createRequestHandler({
    service: { getSnapshot: async () => ({ schemaVersion: 1, accounts: [] }) },
    authService: {
      async listAccounts() {
        called = true;
        return { maxAccounts: 3, accounts: [] };
      },
    },
  });

  const response = await invokeHandler(handler);
  assert.equal(response.statusCode, 503);
  assert.deepEqual(response.json, { error: "auth_unavailable" });
  assert.equal(called, false);
});
