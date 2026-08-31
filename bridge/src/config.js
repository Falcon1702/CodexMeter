import { readFile } from "node:fs/promises";
import path from "node:path";

import { validateLiveProfileHomes } from "./profile-home-validator.js";

const ID_PATTERN = /^[a-zA-Z0-9][a-zA-Z0-9_-]{0,31}$/;
const SUPPORTED_MODES = new Set(["fixture", "live"]);
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "::1", "localhost", "0:0:0:0:0:0:0:1"]);

function requireObject(value, label) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error(`${label} must be an object`);
  }
  return value;
}

function validateProfile(profile, index, mode, configDirectory) {
  requireObject(profile, `profiles[${index}]`);

  if (typeof profile.id !== "string" || !ID_PATTERN.test(profile.id)) {
    throw new Error(`profiles[${index}].id must match ${ID_PATTERN}`);
  }

  if (
    typeof profile.displayName !== "string" ||
    profile.displayName.trim().length === 0 ||
    profile.displayName.trim().length > 12
  ) {
    throw new Error(`profiles[${index}].displayName must contain 1-12 characters`);
  }

  const normalized = {
    id: profile.id,
    displayName: profile.displayName.trim(),
  };

  if (mode === "fixture") {
    if (typeof profile.fixture !== "string" || profile.fixture.trim().length === 0) {
      throw new Error(`profiles[${index}].fixture is required in fixture mode`);
    }
    normalized.fixture = path.resolve(configDirectory, profile.fixture);
    if (profile.fixtureResetAfterMinutes !== undefined) {
      if (
        !Number.isInteger(profile.fixtureResetAfterMinutes) ||
        profile.fixtureResetAfterMinutes < 1 ||
        profile.fixtureResetAfterMinutes > 10_080
      ) {
        throw new Error(
          `profiles[${index}].fixtureResetAfterMinutes must be an integer from 1 through 10080`,
        );
      }
      normalized.fixtureResetAfterMinutes = profile.fixtureResetAfterMinutes;
    }
  } else {
    if (profile.fixtureResetAfterMinutes !== undefined) {
      throw new Error(
        `profiles[${index}].fixtureResetAfterMinutes is available only in fixture mode`,
      );
    }
    if (typeof profile.codexHome !== "string" || !path.isAbsolute(profile.codexHome)) {
      throw new Error(`profiles[${index}].codexHome must be an absolute path in live mode`);
    }
    normalized.codexHome = path.resolve(profile.codexHome);
  }

  return normalized;
}

export function isLoopbackHost(host) {
  return LOOPBACK_HOSTS.has(host.toLowerCase());
}

export function validateConfig(
  input,
  { configDirectory = process.cwd(), environment = process.env } = {},
) {
  const config = requireObject(input, "config");
  const mode = config.mode ?? "fixture";

  if (!SUPPORTED_MODES.has(mode)) {
    throw new Error(`mode must be one of: ${[...SUPPORTED_MODES].join(", ")}`);
  }

  if (!Array.isArray(config.profiles) || config.profiles.length < 1 || config.profiles.length > 3) {
    throw new Error("profiles must contain between 1 and 3 accounts");
  }

  const profiles = config.profiles.map((profile, index) =>
    validateProfile(profile, index, mode, configDirectory),
  );

  if (new Set(profiles.map((profile) => profile.id)).size !== profiles.length) {
    throw new Error("profile ids must be unique");
  }
  if (
    mode === "live" &&
    new Set(profiles.map((profile) => profile.codexHome)).size !== profiles.length
  ) {
    throw new Error("live profile codexHome paths must be unique after normalization");
  }

  const server = requireObject(config.server ?? {}, "server");
  const port = server.port ?? 8787;
  const host =
    typeof server.host === "string" && server.host.trim().length > 0
      ? server.host.trim()
      : "127.0.0.1";
  const environmentToken = environment.WATCH_OVERLAY_BRIDGE_TOKEN;
  const configuredToken = server.bearerToken;
  const rawBearerToken = environmentToken !== undefined ? environmentToken : configuredToken;
  let bearerToken;
  if (rawBearerToken !== undefined) {
    if (typeof rawBearerToken !== "string") {
      throw new Error("server.bearerToken must be a string");
    }
    bearerToken = rawBearerToken.trim();
  }
  const cacheTtlMs = config.cacheTtlMs ?? 60_000;
  const requestTimeoutMs = config.requestTimeoutMs ?? 10_000;

  if (!Number.isInteger(port) || port < 0 || port > 65_535) {
    throw new Error("server.port must be an integer from 0 through 65535");
  }
  if (!Number.isInteger(cacheTtlMs) || cacheTtlMs < 0 || cacheTtlMs > 3_600_000) {
    throw new Error("cacheTtlMs must be an integer from 0 through 3600000");
  }
  if (!Number.isInteger(requestTimeoutMs) || requestTimeoutMs < 250 || requestTimeoutMs > 60_000) {
    throw new Error("requestTimeoutMs must be an integer from 250 through 60000");
  }
  if (bearerToken !== undefined && bearerToken.length < 16) {
    throw new Error("server.bearerToken must contain at least 16 characters");
  }
  if (!isLoopbackHost(host) && !bearerToken) {
    throw new Error(
      "A bearer token is required for non-loopback bindings; set WATCH_OVERLAY_BRIDGE_TOKEN",
    );
  }

  return {
    schemaVersion: 1,
    mode,
    codexCommand:
      typeof config.codexCommand === "string" && config.codexCommand.trim().length > 0
        ? config.codexCommand.trim()
        : "codex",
    profiles,
    cacheTtlMs,
    requestTimeoutMs,
    server: {
      host,
      port,
      bearerToken,
    },
  };
}

export async function loadConfig(configPath) {
  const absolutePath = path.resolve(configPath);
  const configDirectory = path.dirname(absolutePath);
  let parsed;
  try {
    parsed = JSON.parse(await readFile(absolutePath, "utf8"));
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error("Bridge config is not valid JSON", { cause: error });
    }
    throw error;
  }

  const config = validateConfig(parsed, { configDirectory });
  const projectRoot =
    path.basename(configDirectory) === "bridge" ? path.dirname(configDirectory) : configDirectory;
  await validateLiveProfileHomes(config, { projectRoot });
  return config;
}
