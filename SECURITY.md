# Security policy

## Supported versions

CodexMeter is currently a development preview. Security fixes are applied to
the latest commit on `main`; there is no supported App Store or TestFlight
release yet.

## Reporting a vulnerability

Please use GitHub's private vulnerability reporting for this repository. If
that option is unavailable, contact the maintainer through the GitHub profile
without including exploit details or authentication material in a public
issue.

Do not post tokens, cookies, device codes, ChatGPT account identifiers,
`auth.json`, bridge bearer tokens, private configuration, or raw upstream
responses. A useful report contains the affected revision, environment,
reproduction steps with sanitized fixtures, impact, and a suggested mitigation
when available.

Ordinary bugs and feature requests that do not contain sensitive information
may be filed as public GitHub issues.

## Security boundaries

- iPhone account sessions stay in Keychain and are never sent to the watch.
- WatchConnectivity carries only the sanitized snapshot contract.
- The direct usage endpoint is not a stable documented public API.
- Trusted-LAN HTTP bridge traffic is not confidential; use TLS or a private
  tunnel outside a fully trusted network.
