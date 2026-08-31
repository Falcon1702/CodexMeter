# CodexMeter roadmap

CodexMeter is an early development preview. This roadmap lists product work,
not private test history or release evidence.

## Reliability

- [ ] Mark snapshots as stale after a configurable period without a successful
  network refresh.
- [ ] Add deterministic integration coverage for foreground refresh,
  background refresh, WatchConnectivity retry, and event deduplication.
- [ ] Request a fresh phone snapshot when the Watch app becomes active.
- [ ] Improve local scheduling for known reset times without claiming exact
  background-delivery guarantees.
- [ ] Evaluate an optional push-assisted refresh path as a separate design.

## Release readiness

- [ ] Add final iPhone and Apple Watch app icons.
- [ ] Add continuous integration for tests, project generation, and unsigned
  native builds.
- [ ] Complete accessibility and layout checks across supported complication
  sizes, color modes, and Dynamic Type settings.
- [ ] Document a reproducible archive and TestFlight candidate process.
- [ ] Replace development-only diagnostics with bounded, privacy-preserving
  troubleshooting information.

## Compatibility

- [ ] Keep the optional local bridge compatible with the supported Codex App
  Server contract.
- [ ] Detect upstream response changes without exposing raw responses or
  authentication data.
- [ ] Preserve forward-compatible decoding for the sanitized snapshot format.

## Privacy guardrails

- Never commit or publish tokens, cookies, account identifiers, device codes,
  signing data, local paths, private infrastructure details, or raw upstream
  responses.
- Never include personal device inventories or private testing timelines in
  public release documentation.
