# Changelog

All notable changes to this project are documented here.

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
