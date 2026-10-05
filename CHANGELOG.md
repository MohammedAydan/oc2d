# Changelog

All notable changes to this project are documented here.

## [0.1.2] — 2026-10-05

Fixes an installation failure on fresh Ubuntu servers. Reproduced and verified
against a pristine Ubuntu 24.04 rootfs (empty `/var/lib/apt/lists`, `curl`,
`debian-keyring` and `apt-transport-https` absent), not a host where Caddy was
already present.

### Fixed

- **`apt-get update` now runs before any `apt-get install`.** This was the
  blocking bug. On a fresh server the package lists are empty, so
  `apt-get install -y curl` fails with `E: Unable to locate package curl`
  (exit **100**). The update is still skipped when nothing is missing.
- **Wrong exit code in error messages.** `rc=$?` was read *inside* an `if ! cmd`
  block, where `$?` reflects the negation and is therefore always `0`. Every
  failure was reported as `command failed (exit 0)`. The code is now captured as
  `cmd || rc=$?`, which yields the real status (verified: exit 7 and exit 100
  both reported correctly).
- **Temp file path leaked to output.** `root_or_die` printed the *path* returned
  by `mktemp` instead of the captured output, so every failure began with a bare
  `/tmp/tmp.XXXXXXXX`. It now prints the command's real output.
- **Real error context.** Failures show a `--- output of: sudo … ---` banner and
  the last 20 lines of the command's own output, which is where the actual apt
  error lives.
- **Temp files registered for cleanup.** `root_or_die`'s capture file was never
  added to `TMPDIRS`, so it leaked on every call, including failures.
- **Prerequisites are checked before installing.** `missing_packages` uses
  `dpkg-query -f='${db:Status-Status}'` to test each of `debian-keyring`,
  `debian-archive-keyring`, `apt-transport-https` and `curl`, and the script
  installs only what is actually absent.
- **Caddy install is idempotent.** An installed, running Caddy skips the entire
  apt block. `--upgrade` now upgrades Caddy via `apt-get install --only-upgrade`
  instead of being a silent no-op for the proxy.

### Verified

- Old `v0.1.1` code on a pristine Ubuntu 24.04 rootfs reproduces the report
  exactly: a leaked `/tmp/tmp.*` path followed by
  `error command failed (exit 0): sudo apt-get install -y debian-keyring …`.
- Fixed code on the same pristine rootfs completes with exit 0 and installs
  Caddy v2.11.7, with `apt-get update` visibly preceding the prerequisite
  install.
- Package check returns empty on a host where all four are present, so no
  `apt-get` call is made on re-run.
- Two consecutive full runs leave zero `/tmp/tmp.*` behind and print no temp
  paths.
- Full stack still green on the production host: 14 passed / 0 warn / 0 failed,
  HTTPS 200.

## [0.1.1] — 2026-10-05 (final)

Fixes a verification timing bug found on a host with a pre-existing on-demand
TLS wildcard. Documentation-only changes after this point; no further installer
changes.

### Fixed

- **HTTPS verification no longer races certificate provisioning.** On-demand TLS
  issues a certificate lazily, on the first request, so a single-shot probe raced
  that issuance and reported a healthy stack as `NOT healthy` (exit 1).
  `wait_https` now nudges the ACME HTTP-01 challenge with a `:80` request and
  retries up to 24 times at 5s intervals (~120s), printing
  `[wait] HTTPS not ready yet (attempt N/24)...` each time. A 5xx is reported from
  attempt 3 onward without aborting.
- **ACME HTTP-01 nudge.** Before polling HTTPS, a request is sent to port 80 for
  the domain, which starts the challenge and usually speeds up provisioning.
- **Certificate read retries too.** `wait_cert` polls for up to the same budget,
  so a lazily-issued certificate is no longer reported as missing.
- **Fatal vs non-fatal separation.** HTTPS and certificate checks are now
  non-fatal: they warn with a follow-up command and let the install succeed.
  Final failure classifies the cause as `DNS`, `TCP`, `TLS` or an HTTP status,
  derived from curl's own error text, instead of a bare "unreachable".
- **Reboot resilience uses the backend HTTP check as source of truth.** The
  backend on `127.0.0.1:$PORT`, not HTTPS, decides whether the stack came back,
  so a pending certificate can never look like a reboot failure. This also
  removed a redundant second 120-second retry loop.
- **Explicit pass/warn/fail tally.** The run ends with
  `[OK] N checks passed`, `[WARN] M checks warn`, `[FAIL] K checks failed
  (fatal)`. Only fatal failures abort.
- **Pre-existing site checks retry** (6 × 5s), so a lazily-provisioned on-demand
  certificate on someone else's site is not mistaken for damage we caused.
- **Harmless Caddy `Unnecessary header_up` warnings** from pre-existing site
  blocks are surfaced as a note and deliberately left untouched.

### On-demand TLS gates are detected and respected, never modified

The installer detects a pre-existing wildcard block using `tls { on_demand }` and
emits a matching policy for the new domain, so overlapping blocks agree on how TLS
is obtained. It **never edits the wildcard block and never touches the `ask`
endpoint**, which is owned by another application. Registering subdomains in that
control plane is deliberately out of scope.

### Root cause clarification (external, not an installer bug)

A `404` from the `ask` endpoint means the subdomain is **not registered** in the
control plane that backs the wildcard. Caddy will then never issue a certificate
for that name, regardless of retries. This was observed during testing on
`opencode2.r.mohammed-aydan.site`: the gate returned `404`, HTTPS returned `000`,
and the installer correctly completed with **exit 0** and the certificate checks
reported as warnings. A registered sibling domain completed with every check
passing and a valid Let's Encrypt certificate.

The install itself was healthy in both cases. Documented in the README with three
remediation options (register the name, use an already-registered subdomain, or
serve a separate domain outside the gate) and the one-line diagnostic:

```bash
curl -H "Host: code.example.com" http://127.0.0.1:8000/internal/check-domain
```

### Verification

Fatal behaviour confirmed by stopping `opencode.service` (2 fatal, exit 1) and by
simulating `Linger=no` (1 fatal, exit 1). Retry-with-recovery confirmed by
breaking the upstream mid-run and repairing it while `wait_https` was polling: it
observed `502` on attempts 3–7, kept retrying, and returned `HTTP 200` once the
upstream was repaired.

### Documentation

Added README sections for on-demand TLS (including the external dependency, the
`ask` diagnostic and its response codes, and the three options) and for
Diagnostics (log tailing, HTTP→HTTPS redirect check, TLS handshake check,
certificate dates, and symptom-to-cause table).

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