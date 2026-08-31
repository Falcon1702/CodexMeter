# Contributing to CodexMeter

Thanks for helping improve CodexMeter.

## Before opening a change

1. Check `docs/TODO.md` and existing issues for related work.
2. Keep credentials and private account data outside the repository.
3. For security-sensitive findings, follow `SECURITY.md` instead of opening a
   public issue.

## Development setup

Requirements are macOS with Xcode 26, Node.js 20 or newer, and XcodeGen.

```sh
make project
make test
make build
```

`project.yml` is the source for the committed Xcode project. Run
`make project` after changing targets, build settings, entitlements, or source
membership, and include the generated project update in the same change.

Use your own Apple Development Team, bundle identifiers, and App Group for
device builds. Never commit signing material, provisioning profiles, tokens,
cookies, account IDs, `auth.json`, local bridge configuration, or raw account
responses.

## Pull requests

- Keep each pull request focused on one outcome.
- Describe user-visible behavior and important compatibility decisions.
- Add or update focused tests for behavior changes.
- Run the relevant focused check and, before requesting merge, `make test` and
  `make build` when the change affects the native app or shared contracts.
- State clearly when a check was not run or requires physical-device evidence.

Local green checks do not prove TestFlight, App Store, background-delivery, or
production readiness. iOS and watchOS retain control over background scheduling
and WidgetKit budgets.
