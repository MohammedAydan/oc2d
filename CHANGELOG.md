# Changelog

All notable changes to this project are documented here.

## [0.1.1] — 2026-10-05

Fixes a verification timing bug found on a host with a pre-existing on-demand
TLS wildcard (`*.example.com` with an `ask` policy).

### Fixed

- **HTTPS verification no longer races certificate provisioning.** On-demand TLS
  issues a certificate lazily, on the first request, so a single-shot probe could
  report a healthy stack as broken. `wait_https` now nudges the ACME HTTP-01
  challenge with a `:80` request and retries up to 24 times at 5s intervals
  (~120s), printing `[wait] HTTPS not ready yet (attempt N/24)...` each time. A
  5xx is reported from attempt 3 onward without aborting.
- **Certificate read retries too.** `wait_cert` polls for up to the same budget,
  so a lazily-issued certificate is no longer reported as missing.
- **HTTPS and certificate checks are now non-fatal.** They warn, print a
  follow-up command, and let the install succeed. Installation logic is unchanged.
- **Final failure classifies the cause** as `DNS`, `TCP`, `TLS` or an HTTP status,
  derived from curl's own error text, instead of a bare "unreachable".
- **Reboot resilience no longer depends on HTTPS.** The backend check on
  `127.0.0.1:$PORT` is the source of truth; the post-restart HTTPS probe is a
  single fast, non-fatal observation. This also removed a redundant second
  120-second retry loop.
- **Explicit pass/warn/fail tally.** The run ends with
  `[OK] N checks passed`, `[WARN] M checks warn`, `[FAIL] K checks failed
  (fatal)`. Only fatal failures abort.
- **Pre-existing site checks retry** (6 × 5s), so a lazily-provisioned on-demand
  certificate on someone else's site is not mistaken for damage we caused.
- **Harmless Caddy `Unnecessary header_up` warnings** from pre-existing site
  blocks are surfaced as a note and deliberately left untouched.

### Fatal vs non-fatal

Fatal (abort, exit 1): OpenCode unit not active; backend not answering on
loopback; Caddy not active; either unit not enabled; linger missing; backend
publicly bound; crash recovery failed; a pre-existing site down.

Non-fatal (warn, exit 0): HTTPS not yet ready; certificate not yet issued;
issuer not a recognised public CA; external reachability; HTTPS still
provisioning after restart.

## [0.1.0] — 2026-10-05

Initial production release. Installs OpenCode 2 behind a Caddy reverse proxy
with automatic HTTPS, and closes the project out as reboot-resilient.

### Added

- **OpenCode 2 + Caddy installer.** Official V2 installer only; V1 is never
  installed or kept, because V1 and V2 are not wire-compatible.
- **Automatic HTTPS** via Caddy with Let's Encrypt / ZeroSSL, including
  HTTP→HTTPS redirect, HTTP/2 and HTTP/3.
- **Smart merge with existing production Caddy.** The domain's site block is
  merged into `/etc/caddy/Caddyfile` after a timestamped backup, validated with
  `caddy validate` before any reload, and rolled back if validation fails. Other
  sites in the file are never touched.
- **On-demand TLS trap handling.** Detects an existing wildcard block using
  on-demand TLS and matches that policy; overlapping blocks with mismatched TLS
  policies otherwise fail the handshake with `tlsv1 alert internal error`.
- **Pre-flight detection** for Caddy (installed / running / absent), OpenCode 2
  (V2 / V1 / absent), the systemd user manager, linger, port availability and
  DNS, so the script adapts to a messy host instead of failing.
- **Reboot resilience.** Both units are `enable`d, linger is enabled for the
  user, and the OpenCode unit sets `StartLimitIntervalSec=0` so a crash loop can
  recover indefinitely instead of being rate-limited into a dead state.
- **Reboot simulation check.** Restarts both services, waits 10s, and re-probes
  the backend and HTTPS endpoint.
- **Stability audit.** Crash recovery (scoped `SIGKILL` to our own `MainPID`),
  pre-existing-site liveness, single-Caddy-block and single-unit invariants.
- **Self-verifying failure mode.** Any failed check prints the last 20 log lines
  of both services and exits non-zero.
- Idempotent re-runs: preserves the port and password, replaces rather than
  duplicates its own Caddy block.
- Clean uninstall, with `--purge` to remove the binary as well.

### Flags

`--domain` (required), `--port`, `--password`, `--cors`, `--skip-dns-check`,
`--upgrade`, `--strict-port`, `--uninstall`, `--purge`, `--help`.

### Security

- OpenCode binds to `127.0.0.1` only; Caddy is the sole public entry point.
- The password lives in `~/.config/opencode/env` (mode `0600`) and is injected
  via `EnvironmentFile`, keeping it out of `systemctl show` output.
- The unit uses systemd's `%h` specifier, so no path is hardcoded to
  `/home/<user>`.

### Known gaps

- The script is ~710 lines, above the original 400-line target. Kept readable
  rather than shrunk, since resilience checks are the point.
- The Caddy apt-install branch is untested on this host: Caddy was already
  installed and load-bearing for production, so it was never removed to test it.
  The repository and keyring present here were created by those same commands.
- No containerised test. `systemctl --user` cannot work in a bare Docker
  container, so that path is verified only by its failure branch.
- The crash-recovery check requires that the unit's `MainPID` owns the
  configured port; otherwise it warns and skips rather than risk killing an
  unrelated process.