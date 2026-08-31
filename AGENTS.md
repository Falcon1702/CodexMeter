# CodexMeter contributor notes

`README.md` is the public entry point and `docs/TODO.md` is the public roadmap.

- `project.yml` is the source for the generated Xcode project. Run
  `make project` after changing targets, build settings, entitlements, or source
  membership, and commit the generated project update.
- Never commit credentials, account identifiers, device codes, signing
  material, local configuration, personal device details, absolute user paths,
  private service URLs, or raw upstream responses.
- Keep fixtures synthetic and keep logs and screenshots sanitized.
- Run a focused test for normal changes. Run `make test` and `make build` for a
  full local candidate.
- A successful local build is not App Store, TestFlight, production, or
  guaranteed background-delivery evidence.
- Treat the direct usage interface as unstable and keep the bridge fallback
  isolated from the watch snapshot contract.
- Review the security and persistence boundaries in `docs/architecture.md`
  before changing login, Keychain, WatchConnectivity, reset detection, or
  notifications.
