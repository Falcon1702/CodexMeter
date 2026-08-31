import assert from "node:assert/strict";
import test from "node:test";

import { validateConfig } from "../src/config.js";

function fixtureConfig(overrides = {}) {
  return {
    mode: "fixture",
    profiles: [{ id: "account-a", displayName: "A", fixture: "a.json" }],
    ...overrides,
  };
}

test("allows one to three profiles and resolves fixture paths", () => {
  const config = validateConfig(fixtureConfig(), {
    configDirectory: "/tmp/watch-overlay",
    environment: {},
  });

  assert.equal(config.profiles.length, 1);
  assert.equal(config.profiles[0].fixture, "/tmp/watch-overlay/a.json");
  assert.equal(config.server.host, "127.0.0.1");
  assert.equal(config.server.bearerToken, undefined);
});

test("validates the fixture-only relative reset option", () => {
  const minimum = validateConfig(
    fixtureConfig({
      profiles: [
        {
          id: "account-a",
          displayName: "A",
          fixture: "a.json",
          fixtureResetAfterMinutes: 1,
        },
      ],
    }),
    { environment: {} },
  );
  const maximum = validateConfig(
    fixtureConfig({
      profiles: [
        {
          id: "account-a",
          displayName: "A",
          fixture: "a.json",
          fixtureResetAfterMinutes: 10_080,
        },
      ],
    }),
    { environment: {} },
  );

  assert.equal(minimum.profiles[0].fixtureResetAfterMinutes, 1);
  assert.equal(maximum.profiles[0].fixtureResetAfterMinutes, 10_080);

  for (const invalidValue of [0, 10_081, 1.5, "102"]) {
    assert.throws(
      () =>
        validateConfig(
          fixtureConfig({
            profiles: [
              {
                id: "account-a",
                displayName: "A",
                fixture: "a.json",
                fixtureResetAfterMinutes: invalidValue,
              },
            ],
          }),
          { environment: {} },
        ),
      /integer from 1 through 10080/,
    );
  }

  assert.throws(
    () =>
      validateConfig(
        {
          mode: "live",
          profiles: [
            {
              id: "account-a",
              displayName: "A",
              codexHome: "/profiles/a",
              fixtureResetAfterMinutes: 102,
            },
          ],
        },
        { environment: {} },
      ),
    /only in fixture mode/,
  );
});

test("rejects zero, four, and duplicate profiles", () => {
  assert.throws(
    () => validateConfig(fixtureConfig({ profiles: [] }), { environment: {} }),
    /between 1 and 3/,
  );
  assert.throws(
    () =>
      validateConfig(
        fixtureConfig({
          profiles: Array.from({ length: 4 }, (_, index) => ({
            id: `account-${index}`,
            displayName: `${index}`,
            fixture: `${index}.json`,
          })),
        }),
        { environment: {} },
      ),
    /between 1 and 3/,
  );
  assert.throws(
    () =>
      validateConfig(
        fixtureConfig({
          profiles: [
            { id: "same", displayName: "A", fixture: "a.json" },
            { id: "same", displayName: "B", fixture: "b.json" },
          ],
        }),
        { environment: {} },
      ),
    /unique/,
  );
});

test("requires an absolute codexHome in live mode", () => {
  assert.throws(
    () =>
      validateConfig(
        {
          mode: "live",
          profiles: [{ id: "account-a", displayName: "A", codexHome: "relative" }],
        },
        { environment: {} },
      ),
    /absolute path/,
  );
});

test("rejects duplicate normalized codexHome paths in live mode", () => {
  assert.throws(
    () =>
      validateConfig(
        {
          mode: "live",
          profiles: [
            { id: "account-a", displayName: "A", codexHome: "/profiles/a/" },
            {
              id: "account-b",
              displayName: "B",
              codexHome: "/profiles/child/../a",
            },
          ],
        },
        { environment: {} },
      ),
    /codexHome paths must be unique/,
  );
});

test("fails closed for non-loopback HTTP without a token", () => {
  assert.throws(
    () =>
      validateConfig(fixtureConfig({ server: { host: "0.0.0.0", port: 8787 } }), {
        environment: {},
      }),
    /bearer token is required/i,
  );
});

test("accepts an environment token for non-loopback and gives it precedence", () => {
  const config = validateConfig(
    fixtureConfig({
      server: { host: "0.0.0.0", port: 8787, bearerToken: "configured-secret-long" },
    }),
    { environment: { WATCH_OVERLAY_BRIDGE_TOKEN: "  environment-secret-long  " } },
  );

  assert.equal(config.server.bearerToken, "environment-secret-long");
});

test("rejects whitespace-only bearer tokens instead of disabling authentication", () => {
  assert.throws(
    () =>
      validateConfig(
        fixtureConfig({
          server: { host: "127.0.0.1", port: 8787, bearerToken: "   \t\n" },
        }),
        { environment: {} },
      ),
    /at least 16 characters/,
  );

  assert.throws(
    () =>
      validateConfig(
        fixtureConfig({
          server: { host: "0.0.0.0", port: 8787, bearerToken: "configured-secret-long" },
        }),
        { environment: { WATCH_OVERLAY_BRIDGE_TOKEN: "   " } },
      ),
    /at least 16 characters/,
  );
});
