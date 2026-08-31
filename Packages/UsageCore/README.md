# UsageCore

`UsageCore` owns the token-free data contract shared by the local Codex bridge,
the iPhone companion, and the watch complication.

## V1 JSON contract

Dates are ISO-8601 strings. Percentages are JSON numbers and may contain
decimals; the watch rounds the remaining value to the nearest whole percent for
display. `UsageSnapshotCodec` accepts and emits schema version `1` only, so an
unknown contract version fails closed instead of being interpreted silently.

```json
{
  "schemaVersion": 1,
  "generatedAt": "2027-01-15T08:00:00.000Z",
  "accounts": [
    {
      "id": "account-a",
      "displayName": "A",
      "remainingPercent": 68.25,
      "usedPercent": 31.75,
      "resetsAt": "2027-01-15T09:42:00.000Z",
      "windowDurationMinutes": 300,
      "windowLabel": "5h",
      "resetCredits": 0,
      "stale": false,
      "serviceBrand": "codex"
    }
  ]
}
```

Normalization preserves configured order, removes invalid and duplicate account
IDs, clamps percentages, and caps the payload at three accounts. Empty names fall
back to `A`, `B`, or `C` according to their resulting position.

`serviceBrand` ist optionale Darstellungsmetadaten mit den Werten `codex`,
`hermes`, `openClaw` oder `buzz`. Fehlt das Feld oder ist ein Wert unbekannt,
bleibt es ungesetzt und die UI verwendet den Account-Namen als Fallback. Die
iPhone-App ergänzt die lokal gewählte Marke; die Bridge muss das Feld nicht
liefern.

Severity is based on remaining quota: `healthy` at 30% or higher, `warning` from
10% through 29.999%, and `critical` below 10%.

A quota reset is emitted only after corroborating signals: remaining quota rose,
used quota fell, the reset deadline advanced, and the new sample reached the old
deadline (with a small grace period for polling and clock skew). A reset-credit
increase is emitted separately. This keeps notification logic from treating a
simple usage correction as a confirmed reset.
