#!/usr/bin/env node

import { once } from "node:events";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";

import { loadConfig } from "./config.js";
import { AccountAuthService } from "./auth-service.js";
import { startHttpServer } from "./http-server.js";
import { ProfileAppServerCoordinator } from "./profile-app-server-coordinator.js";
import { SnapshotService } from "./snapshot-service.js";

function usage() {
  return "Usage: node src/cli.js <snapshot|serve> --config <path>";
}

function parseArguments(arguments_) {
  const [command, ...rest] = arguments_;
  const configIndex = rest.indexOf("--config");
  const configPath =
    configIndex >= 0 ? rest[configIndex + 1] : process.env.WATCH_OVERLAY_BRIDGE_CONFIG;

  if (!new Set(["snapshot", "serve"]).has(command) || !configPath) {
    throw new Error(usage());
  }
  return { command, configPath };
}

async function closeServer(server) {
  server.close();
  await once(server, "close");
}

export async function main(arguments_ = process.argv.slice(2)) {
  const { command, configPath } = parseArguments(arguments_);
  const config = await loadConfig(configPath);
  const profileCoordinator = new ProfileAppServerCoordinator();
  const service = new SnapshotService(config, { profileCoordinator });

  if (command === "snapshot") {
    process.stdout.write(`${JSON.stringify(await service.getSnapshot({ force: true }), null, 2)}\n`);
    return;
  }

  const authService = new AccountAuthService(config, {
    profileCoordinator,
    onProfileAuthChanged: (profileId, authenticated) => {
      service.invalidateProfile(profileId, { signedOut: !authenticated });
    },
  });

  const server = await startHttpServer({
    service,
    authService,
    host: config.server.host,
    port: config.server.port,
    bearerToken: config.server.bearerToken,
  });

  const address = server.address();
  const boundPort = typeof address === "object" && address ? address.port : config.server.port;
  // Intentionally prints only bind metadata, never profile data or credentials.
  process.stdout.write(`CodexMeter bridge listening on ${config.server.host}:${boundPort}\n`);

  const stop = async () => {
    process.off("SIGINT", stop);
    process.off("SIGTERM", stop);
    await closeServer(server);
  };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch((error) => {
    // Only locally authored error messages are emitted. Upstream responses and
    // auth material are never interpolated into them.
    process.stderr.write(`${error.message}\n`);
    process.exitCode = 1;
  });
}
