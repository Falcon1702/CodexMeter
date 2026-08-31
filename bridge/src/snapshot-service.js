import { readFile } from "node:fs/promises";

import { fetchProfileRateLimits } from "./app-server-client.js";
import { deriveAccountSnapshot, markAccountStale } from "./derive.js";

function sanitizedUnavailableError() {
  const error = new Error("No Codex usage snapshot is currently available");
  error.code = "SNAPSHOT_UNAVAILABLE";
  return error;
}

async function defaultReadFixture(filePath) {
  return JSON.parse(await readFile(filePath, "utf8"));
}

/**
 * Fetches 1-3 profiles concurrently and retains only the last sanitized result
 * per profile. Raw app-server responses never enter the cache.
 */
export class SnapshotService {
  #config;
  #readFixture;
  #fetchLive;
  #profileCoordinator;
  #now;
  #lastGoodAccounts = new Map();
  #cachedSnapshot = null;
  #cachedAtMs = 0;
  #inFlight = null;
  #signedOutProfileIds = new Set();

  constructor(
    config,
    {
      readFixture = defaultReadFixture,
      fetchLive = fetchProfileRateLimits,
      now = () => new Date(),
      profileCoordinator,
    } = {},
  ) {
    this.#config = config;
    this.#readFixture = readFixture;
    this.#fetchLive = fetchLive;
    this.#now = now;
    this.#profileCoordinator = profileCoordinator;
  }

  async #fetchProfile(profile, generatedAt) {
    let result;
    if (this.#config.mode === "fixture") {
      result = await this.#readFixture(profile.fixture);
    } else {
      const release = this.#profileCoordinator?.tryAcquire(profile.codexHome);
      if (this.#profileCoordinator && !release) {
        throw new Error("Codex profile is busy");
      }
      try {
        result = await this.#fetchLive(profile, {
          codexCommand: this.#config.codexCommand,
          requestTimeoutMs: this.#config.requestTimeoutMs,
        });
      } finally {
        release?.();
      }
    }

    // This is the only transition from an upstream payload to the public data
    // model. Account identity, auth fields, tokens, and opaque credit ids are
    // intentionally not copied.
    const account = deriveAccountSnapshot(profile, result);
    if (
      this.#config.mode === "fixture" &&
      Number.isInteger(profile.fixtureResetAfterMinutes)
    ) {
      return {
        ...account,
        resetsAt: new Date(
          generatedAt.getTime() + profile.fixtureResetAfterMinutes * 60_000,
        ).toISOString(),
      };
    }
    return account;
  }

  async #performRefresh() {
    const fixtureReference = this.#config.mode === "fixture" ? this.#now() : null;
    if (
      fixtureReference !== null &&
      (!(fixtureReference instanceof Date) || !Number.isFinite(fixtureReference.getTime()))
    ) {
      throw new Error("Clock returned an invalid date");
    }

    const activeProfiles = this.#config.profiles.filter(
      (profile) => !this.#signedOutProfileIds.has(profile.id),
    );
    const settled = await Promise.allSettled(
      activeProfiles.map((profile) => this.#fetchProfile(profile, fixtureReference)),
    );

    const accounts = [];
    settled.forEach((entry, index) => {
      const profile = activeProfiles[index];
      // Auth state may change while another profile refresh is still in
      // flight. Never resurrect a just-logged-out profile from that older
      // request.
      if (this.#signedOutProfileIds.has(profile.id)) return;
      if (entry.status === "fulfilled") {
        this.#lastGoodAccounts.set(profile.id, entry.value);
        accounts.push(entry.value);
        return;
      }

      const previous = this.#lastGoodAccounts.get(profile.id);
      if (previous) {
        accounts.push(markAccountStale(previous));
      }
    });

    const currentlyActiveProfileCount = this.#config.profiles.filter(
      (profile) => !this.#signedOutProfileIds.has(profile.id),
    ).length;
    if (accounts.length === 0 && currentlyActiveProfileCount > 0) {
      throw sanitizedUnavailableError();
    }

    const generatedAt = fixtureReference ?? this.#now();
    if (!(generatedAt instanceof Date) || !Number.isFinite(generatedAt.getTime())) {
      throw new Error("Clock returned an invalid date");
    }

    const snapshot = {
      schemaVersion: 1,
      generatedAt: generatedAt.toISOString(),
      accounts,
    };
    this.#cachedSnapshot = snapshot;
    this.#cachedAtMs = generatedAt.getTime();
    return snapshot;
  }

  async getSnapshot({ force = false } = {}) {
    const currentTimeMs = this.#now().getTime();
    if (
      !force &&
      this.#cachedSnapshot &&
      currentTimeMs - this.#cachedAtMs < this.#config.cacheTtlMs
    ) {
      return this.#cachedSnapshot;
    }

    if (!this.#inFlight) {
      this.#inFlight = this.#performRefresh().finally(() => {
        this.#inFlight = null;
      });
    }
    return this.#inFlight;
  }

  invalidateProfile(profileId, { signedOut = false } = {}) {
    this.#lastGoodAccounts.delete(profileId);
    this.#cachedSnapshot = null;
    this.#cachedAtMs = 0;
    if (signedOut) {
      this.#signedOutProfileIds.add(profileId);
    } else {
      this.#signedOutProfileIds.delete(profileId);
    }
  }
}
