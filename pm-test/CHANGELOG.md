# Changelog

All notable changes to this project are documented here.

## [0.1.1] — 2026-10-05

Live-host validation on `apps.mohammed-aydan.site` exposed four bugs that the
local suite could not catch, all now fixed and covered by regression tests.

### Fixed

- **Caddy route replacement used the wrong HTTP verb.** Against Caddy 2.11 a
  `PUT` to `/config/apps/http/servers/srv0/routes` answers `409 key already
  exists`, and a `POST` of an array into an existing list answers `500`. Every
  project create therefore failed at the "caddy route" step. `pmd` now
  `DELETE`s the list and then `POST`s it, which is the only combination that
  both works and lets pm put its exact-host routes ahead of the wildcard block.
- **The HTTPS readiness probe could never succeed.** The probe used
  `http.get()` against an `https://` URL, which cannot speak TLS, so a project
  that was serving perfectly was still reported as `httpsReady: false` and the
  installer's smoke test always failed. The client is now chosen by scheme.
- **Project files were left root-owned.** `pmd` runs as root, so
  `mkdir(dir, {mode: 0750})` created the tree as `root:root` while the unit ran
  as `pm` — systemd failed with `200/CHDIR` and no project ever started.
  `scaffold()` now chowns the tree to the unit's run user.
- **Re-running the installer could break an existing install.** Two parts:
  `systemctl enable --now` is a no-op on an already-active unit, so a re-install
  left the old process running with a stale `Environment=`, and the second run
  found only pm's own `ask` in the Caddyfile and dropped
  `PM_FALLBACK_ASKS`. The result was `PM_FALLBACK_ASKS=` — oc2d's subdomains
  stopped being authorised and their TLS handshakes failed. The installer now
  always restarts the unit and recovers the previous fallback gate from it.

### Changed

- `/srv/pm` is chowned to `pm` after `useradd`; `--home-dir` does not chown it.
- `test/fake-services.js` reproduces the real Caddy admin API's 409/500
  responses instead of accepting anything, and `test/fake-dns-tls.js` gives the
  suite a real TLS endpoint so the HTTPS readiness probe is genuinely exercised.
  The suite is 88 assertions, and each fix is verified to turn the suite red
  when reverted.

### Verified live

Installer smoke test passes on `apps.mohammed-aydan.site`; `blog`, `demo` and
`mcptest` each received a Let's Encrypt certificate and served HTTPS 200;
`pm_create`/`pm_list`/`pm_status`/`pm_logs`/`pm_stop`/`pm_start`/`pm_restart`/
`pm_delete` all exercised through the MCP server from OpenCode2; `pm_delete
purge` removed the unit, directory, state entry and Caddy route; `pmd` and
`caddy` restart rebuilds every route from `state.json`; and oc2d's
`r.mohammed-aydan.site`, `opencode.r.mohammed-aydan.site` and
`test.r.mohammed-aydan.site` remained reachable throughout.

## [0.1.0] — 2026-10-05

First release. A daemon (`pmd`) plus MCP server that lets an AI agent create,
run, control and expose projects on subdomains of a parent domain with valid TLS
certificates.

### Added

- **`pmd` daemon** (`daemon/index.js`) on `127.0.0.1:8300`, bearer-token
  authenticated from `/etc/pm/token`. Nine endpoints: create, list, status,
  start, stop, restart, delete (with `?purge=1`), logs, and the on-demand TLS
  authorization gate, plus `/health`.
- **Atomic project creation.** Create scaffolds the project, writes the systemd
  unit, waits up to 15s for the port to answer, registers the subdomain, injects
  the Caddy route, then waits up to 90s for HTTPS. Any failure unwinds the whole
  thing — unit, files, state entry and Caddy route — and returns the exact step
  that failed.
- **MCP server** (`mcp/index.js`, stdio) exposing `pm_create`, `pm_list`,
  `pm_status`, `pm_start`, `pm_stop`, `pm_restart`, `pm_delete` and `pm_logs`.
  Each tool calls the daemon over HTTP and returns a one-line summary plus the
  raw JSON.
- **`install-pm.sh`** — one-shot installer: verifies wildcard DNS (with the exact
  records to add when it fails), creates the `pm` user, installs to `/opt/pm`,
  generates a token, installs and starts `pmd.service`, wires Caddy, registers
  the MCP server in OpenCode2's `opencode.json`, and finishes with a smoke test
  that creates a real project over HTTPS and deletes it. Re-running is safe.
- **Single-file state.** `/var/lib/pm/state.json`, written via atomic rename.
- **Dynamic Caddy routing** through the admin API on `127.0.0.1:2019`: one
  exact-host `reverse_proxy` route per project, inserted ahead of the wildcard
  block so the match wins, rebuilt from `state.json` on every daemon and Caddy
  restart, and removed on delete. Routes pm does not own are left untouched.
- **Tests** (`test/`). `local-test.sh` runs the real daemon against fake
  `systemctl`/`journalctl` and a fake Caddy admin API entirely inside
  `test/.work/`, covering the auth gate, the full lifecycle, route
  injection/removal, atomic rollback, restart recovery and the MCP handshake (78
  assertions). `caddy-config-test.sh` validates both Caddyfile shapes the
  installer can produce against the real `caddy` binary, including a regression
  case for the two-global-blocks mistake.

### Notes

- Caddy permits only one `on_demand_tls` block in a config, so the installer
  **repoints** an existing block's `ask` at `pmd` rather than appending a second
  one, and records the previous endpoint in `PM_FALLBACK_ASKS`. `pmd` delegates
  unknown domains to it so pre-existing sites keep working.
- The gate accepts both `GET ?domain=` and `POST {domain}`, since Caddy's
  default and the specification differ; it is loopback-only because Caddy cannot
  present a token.
- `pmd` runs as root (it must call `systemctl` and write `/etc/systemd/system`);
  each project's unit runs as the unprivileged `pm` user with
  `NoNewPrivileges=true`, bound to loopback.
- MCP registration goes in `~/.config/opencode/opencode.json` under `mcp.pm`,
  which is what OpenCode2 reads — not a separate `mcp.json` with `mcpServers`.
- Ships the `static` template only; more can be added in `scaffold()`.
