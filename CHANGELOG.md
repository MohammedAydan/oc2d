# Changelog

All notable changes to this project are documented here.

## [0.2.5] — 2026-10-06

Two findings from the release audit, both reproduced before being fixed. Both are
about state.json: it is the only record of what pm manages, and both bugs came
from trusting it after it should have been questioned.

### Fixed

- **A stored `path` could turn a delete into an arbitrary `rm -rf` as root.**
  `deleteProject(purge)` passed `state.json`'s `path` straight to
  `fs.rmSync(..., { recursive: true, force: true })`. `createProject` always
  writes `<projectsDir>/<name>`, but nothing re-checked it, and `reconcileState`
  — which drops entries whose unit vanished — validated `subdomain` but not
  `path`. Reproduced: a `state.json` whose `path` named a directory outside the
  projects dir had that directory destroyed by `DELETE /projects/x?purge=1`.
  A project's directory is now always exactly `path.join(projectsDir, name)`.
  Reconciliation drops an entry that says otherwise, and a purge that is handed
  one deletes the record but **not** the files, answering `purged: false` rather
  than claiming a purge that did not happen. This was the same class of bug as
  the v0.2.3 wildcard: one field on that path was hardened and the more dangerous
  one was left alone.
- **An unreadable registry was silently treated as an empty one.** `readState()`
  swallowed every read and parse failure and answered `{ projects: [] }` with no
  log line at all. A registry that cannot be read is not a registry with nothing
  in it, and the difference matters: `GET /projects` reported no projects, and
  the next state write replaced the file with that empty list — turning a
  transient read failure (a permission or I/O error, while the bytes on disk were
  perfectly fine) into permanent loss of every project record. `readState` now
  distinguishes a missing file, which is a legitimate first run, from a file it
  cannot read, logs the path and the error loudly, and declines to sync Caddy
  while the registry is unknown. Writing now copies the damaged file to
  `state.json.unreadable.<timestamp>` first, so the records can be recovered by
  hand.

  **A correction to an earlier claim in this changelog's own audit:** the first
  version of this finding said a corrupt registry would delete every Caddy route
  and take all projects offline. That was wrong, and testing it disproved it.
  `caddySync` keeps every route whose host is not in the set of subdomains pm
  claims, so an empty registry keeps everything. The routes were never at risk.
  What was real is the silent invisibility and the destructive overwrite, which
  is what is fixed here.

### Tests

`local-test.sh` 114 → **133**. New coverage: a sentinel directory outside the
projects dir must survive both the reconcile drop and a `purge=1` delete; the
purge response must say it did not purge; an unreadable registry must be logged
as unknown-not-empty, must skip the route sync, must leave a live project's route
in place, and must leave a byte-identical salvage copy. Every one of these was
confirmed to fail against the unfixed daemon.

Two test-hygiene bugs surfaced while doing it, both fixed:

- **The suite leaked its fake project servers on exit.** The exit trap killed the
  daemon and the fake Caddy but not the `python3 -m http.server` processes the
  fake `systemctl` really starts. One per run survived, so after enough runs the
  whole 4500-4600 range was occupied and every later run failed with `no free
  port` — dozens of failures that had nothing to do with the code under test.
  The trap now stops them, matching only servers serving out of this run's own
  directory. Three consecutive runs now leave nothing behind.
- **A first draft of the new route assertion passed vacuously.** It compared the
  route set before and after the corruption, but at that point in the suite no pm
  route existed to lose, so it also passed against the unfixed daemon. It now
  creates a project first and asserts that project's route specifically survives.

Deploying v0.2.5 caught a regression in the fix above before it shipped anywhere:
`deleteProject` set `purged = false` on the refusal branch but never set it back
to `true` on the success branch, so a perfectly legitimate purge reported
`purged: false` even though it had removed the files. The `purge=1` verification
step caught it on the live install, not the test suite — and the reason the suite
had missed it is the same trap as above: the new test asserted only the refusal
case, so a deleteProject that removed nothing passed it. There is now a
symmetric assertion that a legitimate purge reports `purged: true` and really
removes the directory, confirmed to fail against the broken version.

`caddy-config-test.sh` unchanged at 7.

## [0.2.4] — 2026-10-06

Final release before v1.0.0. Two installer/test defects found by deploying
v0.2.3 to production, one of which could have taken the platform's own site
offline.

### Fixed

- **`install-pm.sh` erased `PM_ALLOW_DOMAINS` on every re-run.** The unit was
  written with `Environment="PM_ALLOW_DOMAINS=$ALLOW_DOMAINS"`, taken straight
  from the `--allow-domain` flag, with no recovery from the installed unit — even
  though `PM_FALLBACK_ASKS` has exactly that recovery a few lines earlier. So
  `install-pm.sh --domain D --parent D` on an existing install emptied the
  allowlist. `checkDomain` tests the allowlist *before* it refuses the apex as a
  reserved name, so the apex then failed the gate, Caddy stopped renewing that
  certificate, and the OpenCode site lost TLS. The value the caller passed is now
  merged with whatever the installed unit already carries, read from the running
  unit and, if systemd reports nothing, from the unit file being overwritten.
  Neither a plain re-run nor an unrelated `--allow-domain` can drop a host that
  is already trusted.
- **`pm-test/mcp-client.js` asserted a fixture name that only exists in the mock
  suite.** `pm_list` was checked with `/blog/.test(...)`, so the check failed
  against a real install, whose projects are named differently. The check now
  proves what it can actually prove — that the call reached the daemon and
  rendered a status per project — and asserts the `blog` fixture only when
  `PM_MOCK_TEST=1`, which `local-test.sh` now sets.

### Notes

- The merge pipeline ends in `grep -v '^$' | sort -u | paste`. Under
  `set -o pipefail`, `grep` exits 1 when it filters out *everything*, which is
  exactly the both-sources-empty case of a first install. Without the `|| true`
  now on that pipeline, a fresh install would have aborted. Caught before
  deployment by exercising the merge directly rather than only on production.
- Deployed and verified against a live install: 2 projects preserved
  byte-identically, apex/wildcard/empty subdomains rejected, a legitimate
  subdomain still reaching HTTPS 200, OpenCode UI unaffected.

### Tests

`local-test.sh` 112 → **114** (the `pm_list` check split into environment-
agnostic and mock-only assertions). `caddy-config-test.sh` unchanged at 7. The
`PM_ALLOW_DOMAINS` merge is exercised directly, all seven cases: first install,
re-run without the flag, re-run with it, adding a second domain, deduplication,
stray whitespace, and flag-before-first-install.

## [0.2.3] — 2026-10-06

Restricts what a pm project may claim. A subdomain becomes a Caddy `host`
matcher verbatim, so anything that is not a real DNS name — or is the apex — was
written straight into the proxy configuration.

### Fixed

- **A project could claim the apex domain.** `createProject` explicitly allowed
  `subdomain === PM_PARENT`, so a project could take the hostname where the
  platform's own OpenCode site lives and shadow it. The apex is now reserved and
  returns `400`.
- **`subdomain` had no character validation at all.** Only the `.parent` suffix
  was checked, so `*.example.com` was accepted and became a wildcard Caddy host
  matcher that shadows every sibling project. Subdomains are now validated as
  real DNS names: dot-separated labels of `[a-z0-9-]` starting and ending
  alphanumeric, no `*`, no empty or doubled labels, at most 253 characters.
- **An empty `subdomain` silently became the default.** `subdomain || default`
  treated `""` as absent, so a caller sending `subdomain: ""` got
  `<name>.<parent>` and no indication that its input was ignored. Only an absent
  (`undefined`/`null`) subdomain now defaults; `""` is a `400`.
- **The `on_demand_tls` gate validated independently.** `checkDomain` now
  rejects empty, over-long, malformed and apex names before they can reach a
  fallback gate, so a future caller cannot bypass the `createProject` checks.
  Explicitly authorised names (`PM_ALLOW_DOMAINS`) are still answered first, so
  the OpenCode site keeps its certificate.
- **`state.json` was trusted on startup.** `reconcileState` dropped entries whose
  unit file was missing but passed any stored `subdomain` through unchecked, and
  `caddySync` writes it to Caddy verbatim. Since that file is restored from
  backups and edited by hand, a stored wildcard would have been injected as a
  host matcher. Reconciliation now re-validates what it reads, using the same
  definition as `createProject`.
- **A malformed JSON body blamed the wrong field.** `readBody` resolved `{}` when
  parsing failed, so `POST /projects` answered `invalid name` for a body the
  caller had never sent a name in. It now answers `request body is not valid
  JSON`. An empty body still means `{}`. Oversized bodies return `413` instead of
  resetting the connection, which previously left the client with no status at
  all.

### Lessons

- **Do not use `pkill -f` with a broad pattern during cleanup.** A `pkill -f` of a
  test process name matched an unrelated process on the host and sent it SIGTERM.
  Match precisely and signal the PID: `pgrep -f '<exact pattern>' | xargs -r
  kill <pid>`, then confirm the intended PID only.
- **A passing assertion is not evidence until its precondition is checked.** The
  first version of the `state.json` wildcard test mapped over a project list that
  an earlier step had emptied, so it never created the entry it claimed to test
  and passed vacuously. It now asserts the entry exists before the restart, and
  the whole set was re-verified to fail against the unfixed daemon.
- **Three claims from an earlier audit of this codebase were wrong and are
  retracted.** `caddySync` is not "non-atomic" in a way that needs fixing: the
  `DELETE` + `POST` sequence is required by Caddy and is what puts exact-host
  routes ahead of the `*.parent` wildcard, which a per-route rewrite would
  invert and break. Rate limiting is not missing in a way that matters — the
  daemon binds `127.0.0.1`, so a per-IP limit is a global one that throttles
  legitimate bursts. And `deleteProject` does not need to poll for the unit to
  stop, because `systemctl disable --now` already waits.

### Tests

`local-test.sh` grows from 89 to 112 assertions. New coverage: malformed, empty
and oversized request bodies; wildcard, apex, empty, dot-only, double-dot and
trailing-dot subdomains; a positive control that an ordinary child is still
accepted; gate-level refusal of the same malformed shapes; and a startup
reconcile case where `state.json` holds a wildcard that must never reach Caddy.
`caddy-config-test.sh` is unchanged at 7.

## [0.2.2] — 2026-10-06

Fixes two regressions in `0.2.1`: the parent prompt could confirm the wrong answer
by default, and the installer died creating its service directories.

### Fixed

- **`/srv/pm` was chowned before it existed.** `useradd --home-dir` does not
  create the directory, so `chown pm:pm /srv/pm` failed with `cannot access
  '/srv/pm': No such file or directory` and aborted the install. A `mkdir -p
  /srv/pm` now precedes it.
- **The parent prompt offered a default the operator never chose.** `--domain`
  was echoed into the prompt, so pressing Enter accepted a parent that had nothing
  to do with pm's wildcard. The prompt is now empty and states plainly that the
  parent is independent of `--domain`.
- **Pressing Enter could no longer skip pm.** An empty answer warned and
  re-prompted forever. It is now a decision: pm is optional, so an empty answer
  prints `Skipping pm install.` and continues with exit 0.
- **An explicitly named parent that fails its wildcard check now exits 1.** A
  parent given via `--pm-parent` or typed at the prompt is a request, and silently
  downgrading it to a skip hides the fact it was not honoured. This is checked
  before any filesystem change. A parent that pm *detected* on its own still skips
  quietly, since a guess never became an instruction.

## [0.2.1] — 2026-10-06

Fixes four bugs in the unified installer, all reported from a fresh host. The
pm parent domain is no longer derived from `--domain`, a missing wildcard skips pm
cleanly instead of failing the install, and `as_root` no longer re-runs failing
commands.

### Fixed

- **pm's parent is no longer derived from `--domain`.** `--domain
  oc2d.example.com` produced parent `example.com`, a domain the operator never
  configured, and the install then failed on a wildcard check for a record that
  could not exist. The two are independent: `--domain` is the single host serving
  OpenCode, while pm hands out subdomains of a separate parent. Resolution is now
  `--pm-parent`, then `PM_PARENT` from a running `pmd`, then a `*.` Caddyfile block
  that already resolves here, then an interactive prompt. Never guessed.
- **A missing wildcard skips pm instead of failing the install.** The parent is
  resolved and its wildcard verified *before* the "install pm?" question, so the
  operator is not walked into a failure. When the records are absent the installer
  prints exactly what to add, how to re-run, and continues — exit status 0, since
  OpenCode 2 succeeded and pm is optional.
- **`as_root` ran failing commands twice.** `sudo -n "$@" 2>/dev/null || sudo "$@"`
  cannot tell "sudo needed a password" from "the command exited non-zero", so
  every failing root command executed a second time. The duplicate `install-pm.sh`
  output in the report was this, not a double invocation — and it also meant any
  failing (or destructive) root command could run twice. Now the retry happens
  only on a genuine authentication failure.
- **A duplicate wildcard block could not be detected.** `grep -q "^[[:space:]]*\*.$P"`
  matched nothing, because the unescaped `.` and `*` made the pattern a regex that
  never hit. pm therefore appended `*.parent` to a file that already had one, and
  Caddy rejected the whole config with "ambiguous site definition". Matching is
  now `-F`, and an existing wildcard is reused after verifying it uses on-demand
  TLS.
- **Password handling.** Non-ASCII input is rejected with a specific message
  instead of being reported as "shorter than 12 characters" (a single Arabic
  character is 2 bytes, so the length check was measuring the wrong thing); the
  weak-password grammar is corrected to "it is shorter than 12 characters"; length
  is counted in characters rather than bytes; and the retry counter now counts
  *rejected* passwords, so a confirmation typo no longer burns an attempt.

### Added

- `--pm-parent` is documented as required-when-undetectable, with the resolution
  order spelled out and the reason it is never derived.
- A distinct message when this host's public IP cannot be determined, instead of
  claiming "DNS is not configured" when the truth is "unknown".

## [0.2.0] — 2026-10-06

Unifies OpenCode 2 and the Project Manager into a single installer. One command
now produces a complete platform: OpenCode behind HTTPS, the pm daemon, and the
pm MCP server registered inside OpenCode, so the agent in the chat can create
and manage sites on subdomains of your parent domain with valid certificates.

### Added

- **Single-command install.** `./install-opencode.sh --domain example.com` now
  installs both halves. pm is auto-detected: an existing `pmd.service` is
  re-verified rather than reinstalled, a missing one triggers a one-time prompt,
  and `--with-pm` / `--without-pm` skip the prompt entirely. With no TTY (CI) the
  install proceeds, so the platform is never silently incomplete.
- **`--pm-parent <d>`** for when the parent is not the last two labels of
  `--domain`, plus `--skip-pm-smoke` to let pm skip its own smoke test.
- **MCP verification against OpenCode's own API.** After writing the config the
  installer restarts OpenCode and polls `/api/mcp` until it reports the `pm`
  server as `connected`. A config file that is merely well-formed no longer counts
  as proof.
- **Combined smoke test**: pmd active and boot-enabled, daemon healthy, MCP entry
  present and connected, the TLS gate authorizing the OpenCode domain, a real
  project created over HTTPS and then removed, and OpenCode still serving.
- **`--uninstall --with-pm`** removes pm as well: stops and deletes `pmd.service`
  and every project unit, drops the `pm` entry from `opencode.json` while leaving
  other MCP servers intact, and **restores the `on_demand_tls` gate pm took
  over**. `--purge` additionally removes `/opt/pm`, `/etc/pm`, `/var/lib/pm` and
  `/srv/pm`.
- **`--allow-domain` on `install-pm.sh`**, used by the unified installer.
- **Unified summary** naming both components and the demo prompts to try.
- `pm-test/` — pm's suite, now 89 + 7 assertions.

### Fixed

- **pm's gate no longer breaks the OpenCode site.** pmd becomes Caddy's single
  `on_demand_tls` authorization gate, so the OpenCode domain — not a pm project —
  would be refused and its certificate would stop issuing. pm is now told to
  authorize it, and the combined verification fails loudly with the exact fix if
  that gate ever stops matching.
- **A refusing gate can no longer be silently ignored.** The installer previously
  mirrored an existing on-demand wildcard policy without checking whether the
  gate would actually issue for the new domain; it now probes the `ask` endpoint
  and refuses to continue on a policy conflict, explaining both remedies. A
  disagreement between an exact block and a matching wildcard block is what causes
  `tlsv1 alert internal error`.
- **Stale projects are reconciled at daemon start.** An interrupted uninstall, or
  a hand-deleted unit, left `state.json` describing projects that could never
  start; they kept their subdomain and Caddy route. `pmd` now drops such entries
  on boot and releases their routes. Files are left for manual recovery.
- The `pm` MCP entry is verified through OpenCode's API rather than assumed from
  the config file, and a `jq` quoting mistake that made every install report a
  false "MCP not connected" is fixed.

### Changed

- Repository layout: `install-pm.sh`, `daemon/` and `mcp/` moved from `pm/` to the
  repository root, so the two halves are one product. `pm/` docs moved to
  `pm-test/README.md`.
- README rewritten around the unified flow, with the demo prompt set and an
  MCP troubleshooting section.

## [0.1.3] — 2026-10-05

Lets the operator choose the OpenCode password at install time, and adds a
standalone script to change it later. The password used to be printed once at
install and never changeable.

### Added

- **Interactive password prompt during install.** With no password flag and a
  terminal on stdin, the installer asks for the password twice with hidden input
  (`read -s`), reports a mismatch and retries up to 3 times, and offers to
  generate a strong random password if the entry is left empty. The prompt is
  shown **only when stdin is a TTY**, so piped runs, CI and `systemd` units keep
  the previous non-interactive behaviour instead of blocking on input.
- **`change-password.sh`.** Changes the password of an existing install without
  reinstalling. It verifies the environment first (refusing with a clear error if
  `~/.config/opencode/env` or `opencode.service` is missing), stops the service,
  waits for it to actually stop, rewrites the single `OPENCODE_PASSWORD=` line
  **preserving any other lines in the file**, starts the service again, waits for
  it to become active, then verifies the unit is `active` and that the backend
  answers HTTP on loopback. Prints a success summary including the login URL,
  discovered from the Caddyfile by finding the site block that proxies to the
  backend port.
- **Atomic update with rollback.** The env file is copied to a temp backup
  before it is edited, and an `EXIT` trap restores it if the change does not
  complete. A failed change therefore leaves the **previous password working**
  rather than a service that is stopped or half-changed.
- **Password strength validation** on every input path, including `--password`:
  rejects `password`, `123456`, `admin`, `opencode`, `changeme`, `letmein`,
  `qwerty` and anything equal to the username `opencode`; warns (allowed after an
  explicit confirmation) below 12 characters or when the password uses a single
  character class (all digits, all lowercase, all uppercase, only symbols).
- **New flags:** `--generate-password` on the installer, `--password` and
  `--generate` on `change-password.sh`.
- The config directory is now created and enforced at mode `0700`.

### Changed

- A generated password is now 24 characters from base62 with a guaranteed
  lowercase, uppercase and digit, instead of an unvalidated random string.
- The install summary prints `Password: (as configured by user)` instead of
  echoing a password the operator typed, and points at `./change-password.sh`.
  The only case that still prints a password is `--generate-password`, where it
  is shown exactly once; a re-run that reuses the stored value no longer
  reprints it.
- The password is no longer reused from the stored file when the operator
  explicitly asked for a new one; a re-run without a password flag still reuses
  the stored value, so upgrading never silently invalidates live sessions.
- `--password` with an empty or missing value is now a clear error instead of
  silently installing an empty password.

### Security notes

- Passwords are never written to shell history (entry uses `read -s`) and never
  echoed in installer output or in the `journalctl` unit log.
- `change-password.sh` writes the new value through a shell redirect rather than
  a command line, so it cannot appear in `ps` output while the file is
  rewritten, and it truncates the file in place to avoid a window in which the
  password sits in a world-readable file.
- Verified against systemd 255 that `EnvironmentFile` preserves spaces, `#` and
  quotes, but consumes a backslash as an escape and trims leading/trailing
  whitespace. Both scripts warn when a password contains those, since it would
  be stored but not received exactly as typed.

### Verified

- 43 unit checks over the password helpers (generation, blocklist, strength
  warnings, and the full prompt loop: match, mismatch retry, give-up after 3
  attempts, empty → generate, short password confirmation).
- 25 checks driving both scripts on a **real pseudo-terminal**, confirming the
  typed password never appears on screen and that the TTY branch is taken.
- Non-interactive paths: `--password` (accepted verbatim), `--generate-password`,
  blocklisted values rejected with exit 1, and piped stdin producing no prompt
  and no change to the stored password.
- Rollback: with `ExecStart` deliberately broken, the change fails, the previous
  password is restored, the script exits 1, and the message reports honestly
  that the service did **not** come back.
- Full installer runs end to end for all four password modes, each exit 0, with
  the env file `0600` and its directory `0700`.

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

## [0.1.1-pm] — 2026-10-05

Tag `v0.1.1-pm`. The pm-only bug-fix release, shipped alongside `[0.1.1]` before
the two installers were unified. Four bugs found by live validation:

- Project creation reported success before the unit was actually running, so a
  failed `systemctl enable --now` still returned `httpsReady: true`.
- The Caddy route was published before the project answered on its port.
- A failed create left the unit file, the project directory and the Caddy route
  behind instead of unwinding.
- `PM_FALLBACK_ASKS` went stale on re-install, because `enable --now` is a no-op
  on an already-active unit, silently ignoring a changed `Environment=`. The
  installer now always restarts the unit.

The first three are covered by the atomic-rollback assertions in `local-test.sh`
(`create: atomic rollback when a step fails`); the fourth is why the installer
restarts rather than enables.

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

## [0.1.0-pm] — 2026-10-05

Tag `v0.1.0-pm`. First release of the Project Manager as a standalone component,
before it was folded into the single installer of `[0.2.0]`.

### Added

- **`pmd`, a root daemon on `127.0.0.1`** with a bearer-token API: create, list,
  status, start, stop, restart, delete, logs. State in `state.json`, written
  atomically.
- **One systemd unit per project**, running as the unprivileged `pm` user and
  bound to loopback, so project code never runs as root.
- **Caddy `on_demand_tls` gate.** `pmd` becomes the authorization endpoint, so a
  name it does not own never gets a certificate — this is what protects the
  Let's Encrypt quota. A pre-existing gate is recovered and delegated to, so
  other sites keep working.
- **pm MCP server**, exposing `pm_create`, `pm_list`, `pm_status`, `pm_start`,
  `pm_stop`, `pm_restart`, `pm_delete`, `pm_logs` over stdio, registered into
  `opencode.json`.
- **Atomic rollback on create**: any failed step unwinds the unit, the directory,
  the state entry and the route.

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