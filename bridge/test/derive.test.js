import assert from "node:assert/strict";
import test from "node:test";

import {
  collectRateLimitWindows,
  deriveAccountSnapshot,
  formatWindowLabel,
} from "../src/derive.js";

const profile = { id: "account-a", displayName: "A" };

test("selects the most constrained window across all multi-bucket windows", () => {
  const result = {
    rateLimits: {
      primary: { usedPercent: 10, windowDurationMins: 15, resetsAt: 100 },
    },
    rateLimitsByLimitId: {
      codex: {
        primary: { usedPercent: 32.4, windowDurationMins: 300, resetsAt: 2_000_000_000 },
        secondary: { usedPercent: 68.6, windowDurationMins: 10_080, resetsAt: 2_100_000_000 },
      },
      other: {
        primary: { usedPercent: 90.2, windowDurationMins: 60, resetsAt: 2_050_000_000 },
      },
    },
    rateLimitResetCredits: { availableCount: 2, credits: [{ id: "must-not-leak" }] },
    accessToken: "must-not-leak",
  };

  const snapshot = deriveAccountSnapshot(profile, result);

  assert.deepEqual(snapshot, {
    id: "account-a",
    displayName: "A",
    remainingPercent: 10,
    usedPercent: 90,
    resetsAt: new Date(2_050_000_000_000).toISOString(),
    windowDurationMinutes: 60,
    windowLabel: "1h",
    resetCredits: 2,
    stale: false,
  });
  assert.equal(JSON.stringify(snapshot).includes("must-not-leak"), false);
});

test("uses the earliest reset to resolve an equal-usage tie", () => {
  const snapshot = deriveAccountSnapshot(profile, {
    rateLimitsByLimitId: {
      later: {
        primary: { usedPercent: 70, windowDurationMins: 300, resetsAt: 2_100_000_000 },
      },
      earlier: {
        primary: { usedPercent: 70, windowDurationMins: 60, resetsAt: 2_000_000_000 },
      },
    },
  });

  assert.equal(snapshot.windowDurationMinutes, 60);
  assert.equal(snapshot.resetsAt, new Date(2_000_000_000_000).toISOString());
});

test("falls back to the legacy rateLimits bucket", () => {
  const windows = collectRateLimitWindows({
    rateLimitsByLimitId: {},
    rateLimits: {
      primary: { usedPercent: 25, windowDurationMins: 15, resetsAt: 2_000_000_000 },
      secondary: null,
    },
  });

  assert.equal(windows.length, 1);
  assert.equal(windows[0].usedPercent, 25);
});

test("clamps percentages and rejects a response without a usable window", () => {
  const snapshot = deriveAccountSnapshot(profile, {
    rateLimits: {
      primary: { usedPercent: 120, windowDurationMins: 15, resetsAt: 2_000_000_000 },
    },
  });
  assert.equal(snapshot.usedPercent, 100);
  assert.equal(snapshot.remainingPercent, 0);

  assert.throws(() => deriveAccountSnapshot(profile, { rateLimits: {} }), /no usable/i);
});

test("rounded used and remaining percentages always add up to 100", () => {
  const snapshot = deriveAccountSnapshot(profile, {
    rateLimits: {
      primary: { usedPercent: 90.5, windowDurationMins: 15, resetsAt: 2_000_000_000 },
    },
  });

  assert.equal(snapshot.usedPercent, 91);
  assert.equal(snapshot.remainingPercent, 9);
  assert.equal(snapshot.usedPercent + snapshot.remainingPercent, 100);
});

test("formats concise quota-window labels", () => {
  assert.equal(formatWindowLabel(15), "15m");
  assert.equal(formatWindowLabel(60), "1h");
  assert.equal(formatWindowLabel(300), "5h");
  assert.equal(formatWindowLabel(10_080), "7d");
  assert.equal(formatWindowLabel(0), "--");
});
