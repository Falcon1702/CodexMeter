import assert from "node:assert/strict";
import test from "node:test";

import { createRequestHandler } from "../src/http-server.js";
import { ProfileAppServerCoordinator } from "../src/profile-app-server-coordinator.js";
import { SnapshotService } from "../src/snapshot-service.js";

const upstream = {
  rateLimits: {
    primary: { usedPercent: 32, windowDurationMins: 300, resetsAt: 2_000_000_000 },
  },
  rateLimitResetCredits: { availableCount: 1 },
  accessToken: "raw-upstream-token",
  account: { email: "private@example.test" },
};

function liveConfig(overrides = {}) {
  return {
    mode: "live",
    codexCommand: "codex",
    profiles: [{ id: "account-a", displayName: "A", codexHome: "/profiles/a" }],
    cacheTtlMs: 0,
    requestTimeoutMs: 500,
    ...overrides,
  };
}

test("returns a sanitized snapshot and reuses last good data as stale", async () => {
  let calls = 0;
  const service = new SnapshotService(liveConfig(), {
    now: () => new Date("2026-08-30T12:00:00.000Z"),
    fetchLive: async () => {
      calls += 1;
      if (calls === 1) return upstream;
      throw new Error("upstream detail must not escape");
    },
  });

  const first = await service.getSnapshot({ force: true });
  const second = await service.getSnapshot({ force: true });

  assert.equal(first.accounts[0].stale, false);
  assert.equal(second.accounts[0].stale, true);
  const serialized = JSON.stringify(second);
  assert.equal(serialized.includes("raw-upstream-token"), false);
  assert.equal(serialized.includes("private@example.test"), false);
  assert.equal(serialized.includes("upstream detail"), false);
});

test("fixture reset override changes only resetsAt relative to the service clock", async () => {
  const now = new Date("2026-08-30T12:00:00.000Z");
  const service = new SnapshotService(
    {
      mode: "fixture",
      profiles: [
        {
          id: "account-a",
          displayName: "A",
          fixture: "/fixtures/a.json",
          fixtureResetAfterMinutes: 102,
        },
      ],
      cacheTtlMs: 0,
      requestTimeoutMs: 500,
    },
    {
      now: () => now,
      readFixture: async () => upstream,
    },
  );

  const snapshot = await service.getSnapshot({ force: true });

  assert.equal(snapshot.generatedAt, now.toISOString());
  assert.equal(
    snapshot.accounts[0].resetsAt,
    new Date(now.getTime() + 102 * 60_000).toISOString(),
  );
  assert.equal(snapshot.accounts[0].remainingPercent, 68);
  assert.equal(snapshot.accounts[0].windowDurationMinutes, 300);
  assert.equal(snapshot.accounts[0].resetCredits, 1);
  assert.equal(snapshot.accounts[0].stale, false);
});

test("throws a sanitized availability error when every cold profile fails", async () => {
  const service = new SnapshotService(liveConfig(), {
    fetchLive: async () => {
      throw new Error("secret upstream detail");
    },
  });

  await assert.rejects(service.getSnapshot({ force: true }), {
    code: "SNAPSHOT_UNAVAILABLE",
    message: "No Codex usage snapshot is currently available",
  });
});

test("logout invalidation removes last-good data and returns an explicit empty snapshot", async () => {
  const now = new Date("2026-08-30T12:00:00.000Z");
  const service = new SnapshotService(liveConfig(), {
    now: () => now,
    fetchLive: async () => upstream,
  });

  const populated = await service.getSnapshot({ force: true });
  assert.equal(populated.accounts.length, 1);

  service.invalidateProfile("account-a", { signedOut: true });
  const signedOut = await service.getSnapshot({ force: true });
  assert.deepEqual(signedOut, {
    schemaVersion: 1,
    generatedAt: now.toISOString(),
    accounts: [],
  });
});

test("a device login lease prevents a second app-server on the same CODEX_HOME", async () => {
  const coordinator = new ProfileAppServerCoordinator();
  const release = coordinator.tryAcquire("/profiles/a");
  let fetches = 0;
  const service = new SnapshotService(liveConfig(), {
    profileCoordinator: coordinator,
    fetchLive: async () => {
      fetches += 1;
      return upstream;
    },
  });

  await assert.rejects(service.getSnapshot({ force: true }), {
    code: "SNAPSHOT_UNAVAILABLE",
  });
  assert.equal(fetches, 0);

  release();
  const snapshot = await service.getSnapshot({ force: true });
  assert.equal(snapshot.accounts.length, 1);
  assert.equal(fetches, 1);
});

test("an in-flight refresh cannot resurrect a profile that logs out", async () => {
  let releaseSecond;
  const secondGate = new Promise((resolve) => {
    releaseSecond = resolve;
  });
  const service = new SnapshotService(
    liveConfig({
      profiles: [
        { id: "account-a", displayName: "A", codexHome: "/profiles/a" },
        { id: "account-b", displayName: "B", codexHome: "/profiles/b" },
      ],
    }),
    {
      fetchLive: async (profile) => {
        if (profile.id === "account-b") await secondGate;
        return upstream;
      },
    },
  );

  const inFlight = service.getSnapshot({ force: true });
  await new Promise((resolve) => setImmediate(resolve));
  service.invalidateProfile("account-a", { signedOut: true });
  releaseSecond();

  const snapshot = await inFlight;
  assert.deepEqual(snapshot.accounts.map((account) => account.id), ["account-b"]);
});

function invokeHandler(handler, { method = "GET", url = "/v1/snapshot", headers = {} } = {}) {
  const responseHeaders = new Map();
  let statusCode;
  let body = "";
  const response = {
    setHeader(name, value) {
      responseHeaders.set(name.toLowerCase(), value);
    },
    writeHead(status, headersToAdd = {}) {
      statusCode = status;
      for (const [name, value] of Object.entries(headersToAdd)) {
        responseHeaders.set(name.toLowerCase(), value);
      }
    },
    end(chunk = "") {
      body += chunk;
    },
  };

  return Promise.resolve(handler({ method, url, headers }, response)).then(() => ({
    statusCode,
    headers: responseHeaders,
    json: JSON.parse(body),
  }));
}

test("HTTP endpoint enforces bearer auth without CORS or secret leakage", async () => {
  const token = "test-bearer-token-long";
  const snapshot = {
    schemaVersion: 1,
    generatedAt: "2026-08-30T12:00:00.000Z",
    accounts: [],
  };
  const service = { getSnapshot: async () => snapshot };
  const handler = createRequestHandler({ service, bearerToken: token });

  const unauthorized = await invokeHandler(handler);
  assert.equal(unauthorized.statusCode, 401);
  assert.deepEqual(unauthorized.json, { error: "unauthorized" });

  const wrongToken = await invokeHandler(handler, {
    headers: { authorization: "Bearer definitely-wrong-token" },
  });
  assert.equal(wrongToken.statusCode, 401);

  const authorized = await invokeHandler(handler, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(authorized.statusCode, 200);
  assert.deepEqual(authorized.json, snapshot);
  assert.equal(authorized.headers.get("access-control-allow-origin"), undefined);
  assert.equal(authorized.headers.get("cache-control"), "no-store");

  const health = await invokeHandler(handler, { url: "/healthz" });
  assert.equal(health.json.status, "ok");
});

test("HTTP handler returns 400 for a malformed request URL instead of throwing", async () => {
  const service = {
    getSnapshot: async () => {
      throw new Error("must not be called");
    },
  };
  const handler = createRequestHandler({ service });

  const response = await invokeHandler(handler, { url: "http://[" });

  assert.equal(response.statusCode, 400);
  assert.deepEqual(response.json, { error: "bad_request" });
});

test("HTTP handler trims its configured bearer token and compares the normalized value exactly", async () => {
  const snapshot = {
    schemaVersion: 1,
    generatedAt: "2026-08-30T12:00:00.000Z",
    accounts: [],
  };
  const service = { getSnapshot: async () => snapshot };
  const token = "normalized-token-long";
  const handler = createRequestHandler({ service, bearerToken: `  ${token}  ` });

  const authorized = await invokeHandler(handler, {
    headers: { authorization: `Bearer ${token}` },
  });
  assert.equal(authorized.statusCode, 200);

  const paddedRequestToken = await invokeHandler(handler, {
    headers: { authorization: `Bearer   ${token}  ` },
  });
  assert.equal(paddedRequestToken.statusCode, 401);

  assert.throws(
    () => createRequestHandler({ service, bearerToken: "   \t\n" }),
    /whitespace-only/,
  );
  assert.throws(
    () => createRequestHandler({ service, bearerToken: "too-short" }),
    /at least 16 characters/,
  );
});

test("HTTP availability failures expose only a stable error code", async () => {
  const service = {
    getSnapshot: async () => {
      throw new Error("account and token detail");
    },
  };
  const handler = createRequestHandler({ service });
  const response = await invokeHandler(handler);
  assert.equal(response.statusCode, 503);
  assert.deepEqual(response.json, { error: "snapshot_unavailable" });
});
