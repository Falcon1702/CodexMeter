import assert from "node:assert/strict";
import { chmod, mkdir, mkdtemp, rm, symlink, unlink, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

import { validateLiveProfileHomes } from "../src/profile-home-validator.js";

async function makePrivateHome(base, name = "account-a") {
  const codexHome = path.join(base, "profiles", name);
  await mkdir(codexHome, { recursive: true, mode: 0o700 });
  await chmod(codexHome, 0o700);
  const configPath = path.join(codexHome, "config.toml");
  await writeFile(configPath, 'cli_auth_credentials_store = "file"\n', { mode: 0o600 });
  await chmod(configPath, 0o600);
  return codexHome;
}

function configFor(codexHome) {
  return {
    mode: "live",
    profiles: [{ id: "account-a", displayName: "A", codexHome }],
  };
}

test("accepts a private external CODEX_HOME with isolated file credentials", async (t) => {
  const base = await mkdtemp(path.join(os.tmpdir(), "watch-overlay-profile-"));
  t.after(() => rm(base, { recursive: true, force: true }));
  const projectRoot = path.join(base, "project");
  await mkdir(projectRoot);
  const codexHome = await makePrivateHome(base);
  const authPath = path.join(codexHome, "auth.json");
  await writeFile(authPath, '{"tokens":"must-never-be-read"}\n', { mode: 0o600 });
  await chmod(authPath, 0o600);

  await validateLiveProfileHomes(configFor(codexHome), { projectRoot });
});

test("rejects insecure, project-local, cloud-synced, and keyring-backed homes", async (t) => {
  const base = await mkdtemp(path.join(os.tmpdir(), "watch-overlay-profile-"));
  t.after(() => rm(base, { recursive: true, force: true }));
  const projectRoot = path.join(base, "project");
  await mkdir(projectRoot);

  const insecure = await makePrivateHome(base, "insecure");
  await chmod(insecure, 0o755);
  await assert.rejects(validateLiveProfileHomes(configFor(insecure), { projectRoot }), /0700/);

  const inProject = await makePrivateHome(projectRoot, "in-project");
  await assert.rejects(
    validateLiveProfileHomes(configFor(inProject), { projectRoot }),
    /outside the project/,
  );

  const cloudBase = path.join(base, "Library", "Mobile Documents");
  const inCloud = await makePrivateHome(cloudBase, "in-cloud");
  await assert.rejects(validateLiveProfileHomes(configFor(inCloud), { projectRoot }), /cloud-synced/);

  const keyring = await makePrivateHome(base, "keyring");
  await writeFile(
    path.join(keyring, "config.toml"),
    'cli_auth_credentials_store = "auto"\n',
    { mode: 0o600 },
  );
  await assert.rejects(
    validateLiveProfileHomes(configFor(keyring), { projectRoot }),
    /cli_auth_credentials_store = "file"/,
  );

  const looseConfig = await makePrivateHome(base, "loose-config");
  await chmod(path.join(looseConfig, "config.toml"), 0o644);
  await assert.rejects(
    validateLiveProfileHomes(configFor(looseConfig), { projectRoot }),
    /config.toml must be a private 0600 file/,
  );
});

test("never accepts a loose or linked auth.json", async (t) => {
  const base = await mkdtemp(path.join(os.tmpdir(), "watch-overlay-profile-"));
  t.after(() => rm(base, { recursive: true, force: true }));
  const projectRoot = path.join(base, "project");
  await mkdir(projectRoot);
  const codexHome = await makePrivateHome(base);
  const authPath = path.join(codexHome, "auth.json");
  await writeFile(authPath, "secret\n", { mode: 0o644 });
  await chmod(authPath, 0o644);

  await assert.rejects(
    validateLiveProfileHomes(configFor(codexHome), { projectRoot }),
    /auth.json must be a private 0600 file/,
  );

  await unlink(authPath);
  const outsideAuth = path.join(base, "outside-auth.json");
  await writeFile(outsideAuth, "secret\n", { mode: 0o600 });
  await symlink(outsideAuth, authPath);
  await assert.rejects(
    validateLiveProfileHomes(configFor(codexHome), { projectRoot }),
    /auth.json must be a private 0600 file/,
  );
});
