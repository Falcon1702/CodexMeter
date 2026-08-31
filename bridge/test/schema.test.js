import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import test from "node:test";

test("snapshot schema uses JSON numbers for UsageCore percentage doubles", async () => {
  const schemaPath = path.resolve(import.meta.dirname, "../schema/snapshot.schema.json");
  const schema = JSON.parse(await readFile(schemaPath, "utf8"));
  const accountProperties = schema.properties.accounts.items.properties;

  assert.equal(accountProperties.remainingPercent.type, "number");
  assert.equal(accountProperties.usedPercent.type, "number");
  assert.equal(accountProperties.windowDurationMinutes.type, "integer");
  assert.equal(accountProperties.resetCredits.type, "integer");
  assert.equal(schema.properties.accounts.minItems, 0);
  assert.equal(schema.properties.accounts.maxItems, 3);
});
