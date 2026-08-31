import assert from "node:assert/strict";
import { execFile } from "node:child_process";
import path from "node:path";
import { promisify } from "node:util";
import test from "node:test";

const execFileAsync = promisify(execFile);
const bridgeDirectory = path.resolve(import.meta.dirname, "..");

test("snapshot CLI works when its filesystem path contains spaces", async () => {
  const { stdout, stderr } = await execFileAsync(
    process.execPath,
    ["src/cli.js", "snapshot", "--config", "config.example.json"],
    { cwd: bridgeDirectory },
  );

  assert.equal(stderr, "");
  const snapshot = JSON.parse(stdout);
  assert.equal(snapshot.schemaVersion, 1);
  assert.equal(snapshot.accounts.length, 3);
  assert.deepEqual(
    snapshot.accounts.map((account) => account.remainingPercent),
    [68, 21, 7],
  );
});
