import { lstat, readFile, realpath } from "node:fs/promises";
import path from "node:path";

function isInside(candidate, root) {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith(`..${path.sep}`) && relative !== "..");
}

function looksCloudSynced(candidate) {
  const normalized = candidate.toLowerCase().split(path.sep).join("/");
  return (
    normalized.includes("/library/mobile documents/") ||
    normalized.includes("/icloud drive/") ||
    normalized.includes("/library/cloudstorage/")
  );
}

function ownedByCurrentUser(stats) {
  return typeof process.getuid !== "function" || stats.uid === process.getuid();
}

function hasTopLevelFileCredentialStore(configText) {
  for (const line of configText.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    if (trimmed.startsWith("[")) return false;
    const match = /^cli_auth_credentials_store\s*=\s*(["'])([^"']+)\1\s*(?:#.*)?$/.exec(
      trimmed,
    );
    if (match) return match[2] === "file";
  }
  return false;
}

async function validateProfileHome(profile, forbiddenRoots) {
  let homeStats;
  let resolvedHome;
  try {
    homeStats = await lstat(profile.codexHome);
    resolvedHome = await realpath(profile.codexHome);
  } catch {
    throw new Error(`Live profile ${profile.id} CODEX_HOME is not prepared`);
  }

  if (
    !homeStats.isDirectory() ||
    homeStats.isSymbolicLink() ||
    !ownedByCurrentUser(homeStats) ||
    (homeStats.mode & 0o777) !== 0o700
  ) {
    throw new Error(`Live profile ${profile.id} CODEX_HOME must be a private 0700 directory`);
  }
  if (looksCloudSynced(resolvedHome)) {
    throw new Error(`Live profile ${profile.id} CODEX_HOME must not be cloud-synced`);
  }
  if (forbiddenRoots.some((root) => isInside(resolvedHome, root))) {
    throw new Error(`Live profile ${profile.id} CODEX_HOME must be outside the project`);
  }

  const configPath = path.join(resolvedHome, "config.toml");
  let configStats;
  let configText;
  try {
    configStats = await lstat(configPath);
    configText = await readFile(configPath, "utf8");
  } catch {
    throw new Error(`Live profile ${profile.id} requires a private config.toml`);
  }
  if (
    !configStats.isFile() ||
    configStats.isSymbolicLink() ||
    !ownedByCurrentUser(configStats) ||
    (configStats.mode & 0o777) !== 0o600
  ) {
    throw new Error(`Live profile ${profile.id} config.toml must be a private 0600 file`);
  }
  if (!hasTopLevelFileCredentialStore(configText)) {
    throw new Error(
      `Live profile ${profile.id} config.toml must set cli_auth_credentials_store = "file"`,
    );
  }

  const authPath = path.join(resolvedHome, "auth.json");
  try {
    const authStats = await lstat(authPath);
    if (
      !authStats.isFile() ||
      authStats.isSymbolicLink() ||
      !ownedByCurrentUser(authStats) ||
      (authStats.mode & 0o777) !== 0o600
    ) {
      throw new Error(`Live profile ${profile.id} auth.json must be a private 0600 file`);
    }
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
  }
}

export async function validateLiveProfileHomes(config, { projectRoot } = {}) {
  if (config.mode !== "live") return;

  const forbiddenRoots = [];
  if (projectRoot) {
    try {
      forbiddenRoots.push(await realpath(projectRoot));
    } catch {
      forbiddenRoots.push(path.resolve(projectRoot));
    }
  }

  await Promise.all(
    config.profiles.map((profile) => validateProfileHome(profile, forbiddenRoots)),
  );
}
