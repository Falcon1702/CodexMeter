# CodexMeter Codex Bridge

This local, dependency-free Node bridge reads Codex quota windows for one to
three separately configured profiles and emits a deliberately small JSON
snapshot for the iPhone/Watch app. It does not call the OpenAI API directly,
consume reset credits, or expose raw Codex account/auth responses. In live mode
it can start and monitor the official Codex device-code login and log a
configured profile out through Codex app-server.

The implementation follows the current
[official Codex App Server documentation](https://learn.chatgpt.com/docs/app-server):
each live profile gets its own `codex app-server` stdio process, the client sends
`initialize`, then `initialized`, and uses the documented account methods. Every
child is started with `-c 'cli_auth_credentials_store="file"'` so credentials
remain inside that profile's separate `CODEX_HOME` instead of being merged in
the macOS Keychain.

## Quick fixture run

Node 20 or newer is required. No install step is needed.

```sh
cd bridge
npm test
npm run snapshot
npm run serve
```

The fixture server listens on `127.0.0.1:8787`:

```sh
curl http://127.0.0.1:8787/v1/snapshot
```

It returns the V1 contract documented in `schema/snapshot.schema.json`.
The example profiles use the fixture-only `fixtureResetAfterMinutes` option, so
their countdowns remain `1h 42`, `3h 18`, and `0h 27` relative to each refresh
instead of expiring with the static upstream-shaped fixture timestamps.

## Live profiles

The macOS helper creates a private standard structure without printing the
random bridge token:

```sh
npm run local:provision
npm run local:serve
```

The default location is `~/Library/Application Support/CodexMeter/`. Set
`CODEXMETER_HOME` to use another private directory. Three slots are prepared,
but only signed-in accounts appear in the app. `npm run local:copy-token` places
only the local bridge token on the macOS pasteboard and does not print it in the
terminal.

1. Create one separate Codex home directory per ChatGPT account, outside this
   repository and outside iCloud or another `~/Library/CloudStorage` location.
   Each directory must be owned by the current user with mode `0700`.
2. Put a mode-`0600` `config.toml` in every profile directory containing this
   top-level setting:

```toml
cli_auth_credentials_store = "file"
```

   The bridge validates these boundaries before starting. It does not create,
   replace, or loosen an existing profile configuration. Codex creates
   `auth.json` after login; the bridge never reads or logs that file and rejects
   it on a later start unless it is a regular, user-owned `0600` file. Treat it
   like a password and never commit, paste, or share it.
3. Enable device-code login in the ChatGPT account's security settings, or ask
   the workspace administrator to enable it in workspace permissions.
4. Copy `config.live.example.json` to the git-ignored `config.local.json`.
5. Replace each `codexHome` with an absolute profile directory. Keep one to
   three profiles, in the display order desired on the watch. Every normalized
   `codexHome` path must be unique so two labels cannot accidentally read the
   same signed-in account.
6. Start the bridge:

```sh
node src/cli.js snapshot --config config.local.json
node src/cli.js serve --config config.local.json
```

`codexCommand` can be set in the config if `codex` is not on `PATH`.

## Account and device-login HTTP contract

Account slots are the one to three profiles from the private bridge config;
HTTP never creates directories or edits the config. Authentication endpoints
are disabled unless the bridge has a bearer token, including on loopback.

```text
GET    /v1/accounts
POST   /v1/auth/device/start       {"accountId":"account-a"}
GET    /v1/auth/device/{loginId}
DELETE /v1/auth/device/{loginId}
DELETE /v1/accounts/{accountId}
```

Starting a device-code login returns status `201`:

```json
{
  "accountId": "account-a",
  "loginId": "opaque-login-id",
  "status": "pending",
  "expiresAt": "2030-01-15T08:10:00.000Z",
  "intervalSeconds": 2,
  "verificationUrl": "https://auth.openai.com/codex/device",
  "userCode": "ABCD-1234"
}
```

The iPhone opens the exact allowlisted HTTPS URL and polls the login id. Poll
status is `pending`, `succeeded`, `failed`, or `cancelled`. Success is reported
only after `account/login/completed` and a confirming `account/read` result.
Sessions expire after ten minutes and terminal results are retained briefly in
memory. A bridge restart therefore makes old login ids unknown.

`GET /v1/accounts` returns only configured ids/names, sanitized state,
`authMode`, optional `planType`, and an active `loginId`. It never returns an
email address, ChatGPT account id, token, raw upstream error, or `auth.json`
content. Logout calls `account/logout`; it does not remove `CODEX_HOME`.

Stable HTTP errors include `bad_request`, `unauthorized`, `account_not_found`,
`login_not_found`, `login_in_progress`, `already_signed_in`, and
`auth_unavailable`. Raw Codex errors are collapsed to these values.

## Limiting-window rule

Codex may return primary and secondary windows across multiple metered buckets.
The bridge selects the window with the highest `usedPercent`, so the displayed
`remainingPercent` is the most constrained quota. A usage tie selects the
earliest reset. This is a CodexMeter product rule, not a claim that Codex
defines one window as globally primary.

## HTTP and token safety

The default bind address is loopback only. A bearer token is optional on
loopback for the read-only snapshot endpoint and mandatory for any non-loopback
host. Every account/login/logout endpoint always requires one. Prefer the
environment so the token is not stored in JSON:

```sh
WATCH_OVERLAY_BRIDGE_TOKEN='replace-with-a-long-random-secret' \
  node src/cli.js serve --config config.local.json
```

Then send `Authorization: Bearer <token>` to `/v1/snapshot`. The same token may
instead be placed at `server.bearerToken`, but that config must remain private.
Leading and trailing whitespace is removed once during startup; the normalized
token must still contain at least 16 characters, and an empty or whitespace-only
value is rejected. The iPhone app should store it in Keychain. The server emits
no CORS headers, uses `Cache-Control: no-store`, and never puts the token in
snapshots or logs.

To reach the bridge from an iPhone on a trusted LAN, explicitly change
`server.host` to `0.0.0.0` and set the token. The config loader fails closed if
the non-loopback bind has no token. With plain HTTP, both the Codex usage
metadata and the bearer token travel in cleartext and can be observed by anyone
with visibility into that network traffic. The token restricts access but does
not provide confidentiality. Use trusted-LAN HTTP only on a network you trust;
otherwise use a private TLS endpoint or a trusted tunnel.

## Failure behavior

Successful sanitized account values are cached for `cacheTtlMs`. If a later
refresh for that profile fails, the last good value is returned with
`stale: true`. A profile with no prior good value is omitted. If all profiles
are unavailable, the HTTP endpoint returns only
`{"error":"snapshot_unavailable"}` with status 503—never an upstream error,
stderr, token, email, account id, or raw payload.

After an explicit logout, that profile's last-good usage value is invalidated
instead of being returned as stale. When every configured profile is signed
out, `/v1/snapshot` deliberately returns a valid V1 snapshot with
`"accounts": []` so the iPhone and Watch can clear previously displayed data.
