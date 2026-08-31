#!/usr/bin/env node

import { spawn } from "node:child_process";
import { randomBytes } from "node:crypto";
import {
  chmod,
  lstat,
  mkdir,
  open,
  readFile,
} from "node:fs/promises";
import { homedir } from "node:os";
import path from "node:path";
import process from "node:process";

import { main as bridgeMain } from "../src/cli.js";

const baseDirectory = process.env.CODEXMETER_HOME
  ? path.resolve(process.env.CODEXMETER_HOME)
  : path.join(homedir(), "Library", "Application Support", "CodexMeter");
const bridgeDirectory = path.join(baseDirectory, "Bridge");
const profilesDirectory = path.join(baseDirectory, "Profiles");
const configPath = path.join(bridgeDirectory, "bridge-config.json");
const profileSpecs = [
  { id: "account-a", displayName: "A" },
  { id: "account-b", displayName: "B" },
  { id: "account-c", displayName: "C" },
];

function usage() {
  return "Usage: node scripts/local-setup.mjs <provision|copy-token|serve|snapshot>";
}

async function ensurePrivateDirectory(directory) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const stats = await lstat(directory);
  if (!stats.isDirectory() || stats.isSymbolicLink()) {
    throw new Error(`Refusing non-directory path: ${directory}`);
  }
  if (typeof process.getuid === "function" && stats.uid !== process.getuid()) {
    throw new Error(`Refusing directory owned by another user: ${directory}`);
  }
  await chmod(directory, 0o700);
}

async function requirePrivateFile(file) {
  const stats = await lstat(file);
  if (!stats.isFile() || stats.isSymbolicLink()) {
    throw new Error(`Refusing non-regular file: ${file}`);
  }
  if (typeof process.getuid === "function" && stats.uid !== process.getuid()) {
    throw new Error(`Refusing file owned by another user: ${file}`);
  }
  if ((stats.mode & 0o777) !== 0o600) {
    throw new Error(`Private file must have mode 0600: ${file}`);
  }
}

async function writeExclusivePrivateFile(file, contents) {
  let handle;
  try {
    handle = await open(file, "wx", 0o600);
    await handle.writeFile(contents, "utf8");
  } finally {
    await handle?.close();
  }
  await chmod(file, 0o600);
}

async function ensureProfile(profile) {
  const codexHome = path.join(profilesDirectory, profile.id);
  await ensurePrivateDirectory(codexHome);
  const profileConfigPath = path.join(codexHome, "config.toml");
  try {
    await writeExclusivePrivateFile(
      profileConfigPath,
      'cli_auth_credentials_store = "file"\n',
    );
  } catch (error) {
    if (error?.code !== "EEXIST") throw error;
    await requirePrivateFile(profileConfigPath);
    const existing = await readFile(profileConfigPath, "utf8");
    if (!existing.split(/\r?\n/).some((line) =>
      /^\s*cli_auth_credentials_store\s*=\s*(["'])file\1\s*(?:#.*)?$/.test(line),
    )) {
      throw new Error(`Existing config does not enforce file credentials: ${profileConfigPath}`);
    }
  }
  return { ...profile, codexHome };
}

function validateExistingBridgeConfig(config, profiles) {
  const expectedHomes = profiles.map((profile) => profile.codexHome);
  const actualHomes = config?.profiles?.map((profile) => profile.codexHome);
  if (
    config?.mode !== "live"
    || config?.server?.host !== "0.0.0.0"
    || config?.server?.port !== 8787
    || typeof config?.server?.bearerToken !== "string"
    || config.server.bearerToken.length < 16
    || JSON.stringify(actualHomes) !== JSON.stringify(expectedHomes)
  ) {
    throw new Error(`Existing bridge config does not match the managed local setup: ${configPath}`);
  }
  return config;
}

async function provision() {
  await ensurePrivateDirectory(baseDirectory);
  await ensurePrivateDirectory(bridgeDirectory);
  await ensurePrivateDirectory(profilesDirectory);
  const profiles = [];
  for (const profile of profileSpecs) {
    profiles.push(await ensureProfile(profile));
  }

  let config;
  try {
    await requirePrivateFile(configPath);
    config = validateExistingBridgeConfig(
      JSON.parse(await readFile(configPath, "utf8")),
      profiles,
    );
  } catch (error) {
    if (error?.code !== "ENOENT") throw error;
    config = {
      mode: "live",
      cacheTtlMs: 60_000,
      requestTimeoutMs: 10_000,
      profiles,
      server: {
        host: "0.0.0.0",
        port: 8787,
        bearerToken: randomBytes(32).toString("base64url"),
      },
    };
    await writeExclusivePrivateFile(configPath, `${JSON.stringify(config, null, 2)}\n`);
  }

  // Never print the bearer token. This output is safe to keep in a terminal log.
  process.stdout.write(`Private Bridge-Konfiguration bereit: ${configPath}\n`);
  process.stdout.write(`Account-Slots bereit: ${profiles.map((profile) => profile.displayName).join(", ")}\n`);
  return config;
}

async function loadPrivateConfig() {
  await requirePrivateFile(configPath);
  return JSON.parse(await readFile(configPath, "utf8"));
}

async function copyToken() {
  const config = await loadPrivateConfig();
  const token = config?.server?.bearerToken;
  if (typeof token !== "string" || token.length < 16) {
    throw new Error("Private bridge config does not contain a valid bearer token");
  }

  const child = spawn("/usr/bin/pbcopy", [], {
    stdio: ["pipe", "ignore", "inherit"],
  });
  child.stdin.end(token);
  const exitCode = await new Promise((resolve, reject) => {
    child.once("error", reject);
    child.once("close", resolve);
  });
  if (exitCode !== 0) {
    throw new Error("Could not copy the bridge token to the macOS pasteboard");
  }
  process.stdout.write("Bridge-Token wurde in die Zwischenablage kopiert.\n");
}

async function run() {
  const command = process.argv[2];
  switch (command) {
    case "provision":
      await provision();
      return;
    case "copy-token":
      await copyToken();
      return;
    case "serve":
    case "snapshot":
      await bridgeMain([command, "--config", configPath]);
      return;
    default:
      throw new Error(usage());
  }
}

run().catch((error) => {
  // All messages above are locally authored and never interpolate secret data.
  process.stderr.write(`${error.message}\n`);
  process.exitCode = 1;
});
