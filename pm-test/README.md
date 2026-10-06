# pm — Project Manager

A daemon plus MCP server that lets an AI agent (OpenCode2) create, run, control
and expose projects on subdomains of a parent domain, with valid TLS
certificates, automatically.

```bash
sudo ./install-pm.sh --domain example.com
```

Then, from OpenCode2:

```
pm_create({ name: "blog", subdomain: "blog.example.com" })
→ within 60s, https://blog.example.com returns 200 with a valid certificate
```

## How it works

Three moving parts, no orchestration:

```
OpenCode2 ──MCP/stdio──▶ pm MCP server ──HTTP──▶ pm daemon (pmd)
                                                       │
                                    ┌──────────────────┴──────────────────┐
                                    ▼                                      ▼
                            systemd units                        Caddy admin API
                            (one per project)                     (one route per project)
```

Wildcard DNS already resolves `anything.example.com` to the server. Caddy's
`on_demand_tls` will issue a certificate for a subdomain, but only if something
**authorizes** it. `pmd` is that gate: it answers Caddy's `ask` endpoint with
200 for subdomains that belong to a pm project and 404/403 for everything else.
That refusal is what stops a stranger from burning your Let's Encrypt quota by
opening TLS connections to random labels.

Creating a project is one flow with a hard guarantee: if any step fails, pm
unwinds everything it did (unit, files, state entry, Caddy route) and returns
the exact step that failed.

## Requirements

- Ubuntu 22.04+ (any systemd Linux), `root`, and internet access
- `node` ≥ 18, `npm`, `systemctl`, `caddy`, `dig`, `curl`, `jq`, `python3`,
  `openssl`
- **Ports 80 and 443 open to the internet.** Let's Encrypt validates over the
  public internet, so certificates cannot be issued otherwise.
- A parent domain with these two A records already pointing at this host:

  ```
  A    example.com     -> <server-ip>
  A    *.example.com   -> <server-ip>
  ```

The installer verifies the wildcard record and prints exactly what to add if it
is missing. `--skip-dns-check` bypasses this.

## Install

```bash
sudo ./install-pm.sh --domain example.com
```

| Flag | Default | Notes |
|---|---|---|
| `--domain <d>` | **required** | Domain to serve. Parent is its last two labels (`blog.example.com` → `example.com`) |
| `--parent <d>` | from `--domain` | Parent domain whose wildcard subdomains pm may expose |
| `--skip-dns-check` | off | Proceed even if the wildcard A record is not live yet |
| `-h`, `--help` | | Usage |

The installer creates the `pm` user, writes `/opt/pm/{daemon,mcp}`, generates a
token in `/etc/pm/token`, installs and starts the `pmd` systemd unit, wires
Caddy, registers the MCP server in OpenCode2's config, and then runs a **smoke
test**: it creates a real project at `smoke.<parent>`, waits for HTTPS, and
deletes it. If the smoke test fails the installer dumps `pmd` and Caddy logs and
exits non-zero, so a green run means the whole path works.

Re-running is safe. Existing state, units and projects are left alone; the
Caddyfile and `opencode.json` are merged, not overwritten.

## Where things live

| Path | What |
|---|---|
| `/opt/pm/daemon/index.js` | the daemon (`pmd`) |
| `/opt/pm/mcp/index.js` | the MCP server |
| `/etc/pm/token` | bearer token, mode `0600` |
| `/var/lib/pm/state.json` | all state, one JSON file, atomic writes |
| `/srv/pm/projects/<name>` | project files, owned by `pm` |
| `/etc/systemd/system/pm-<name>.service` | one unit per project |
| `~/.config/opencode/opencode.json` | MCP registration under `.mcp.pm` |

## MCP tools

| Tool | Does |
|---|---|
| `pm_create({name, subdomain?})` | scaffold, start, route, and wait for HTTPS |
| `pm_list()` | every project with status, port, subdomain |
| `pm_status({name})` | one project's state |
| `pm_start({name})` | start the unit |
| `pm_stop({name})` | stop the unit |
| `pm_restart({name})` | restart the unit |
| `pm_delete({name, purge?})` | stop, remove unit + route; `purge` deletes files |
| `pm_logs({name, lines?})` | recent journal output |

`subdomain` defaults to `<name>.<parent>`. Names must match
`^[a-z][a-z0-9-]{1,30}$`.

## HTTP API

The daemon listens on `127.0.0.1:8300` and requires
`Authorization: Bearer $(cat /etc/pm/token)` on everything except `/health` and
the Caddy gate.

```bash
TOKEN=$(cat /etc/pm/token)
curl -s -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8300/projects | jq
```

| Method | Path | |
|---|---|---|
| `POST` | `/projects` | create + start (`{name, subdomain?}`) |
| `GET` | `/projects` | list |
| `GET` | `/projects/:name` | status |
| `POST` | `/projects/:name/start` `/stop` `/restart` | control |
| `DELETE` | `/projects/:name` | remove (`?purge=1` deletes files) |
| `GET` | `/projects/:name/logs` | `?lines=N` |
| `GET`/`POST` | `/internal/check-domain` | Caddy's authorization gate |
| `GET` | `/health` | liveness |

## Templates

`static` only, for now: a scaffolded `index.html` served by
`python3 -m http.server`. Adding another template means writing a directory of
files and an `ExecStart` — see `scaffold()` in `daemon/index.js`.

## Tests

```bash
./test/local-test.sh        # daemon + MCP, no root, no host changes
./test/caddy-config-test.sh # the Caddyfile shapes the installer produces
```

`local-test.sh` runs the real daemon against fake `systemctl`/`journalctl` and a
fake Caddy admin API, all inside `test/.work/`. It covers the auth gate
(including delegation to a pre-existing gate), the full project lifecycle, Caddy
route injection and removal, atomic rollback, restart recovery, and the MCP
handshake. It never touches the host.

## Troubleshooting

**`wildcard DNS is not configured`** — add both A records and wait for
propagation. Verify with `dig +short x.example.com`.

**Smoke test fails with "not reachable over HTTPS"** — almost always ports
80/443 blocked. Confirm with `curl -I http://<ip>` from another machine, and
check that Caddy is listening: `ss -tlnp | grep -E ':(80|443)'`.

**`tlsv1 alert internal error`** — the handshake was refused by the gate. Check
`curl -s "http://127.0.0.1:8300/internal/check-domain?domain=<sub>"` returns 200,
and that `PM_PARENT` in the unit matches the domain you asked for:
`systemctl show pmd -p Environment`.

**A project returns 502** — the unit is not listening. `pm_logs({name})`, then
`journalctl -u pm-<name> -f`.

**Subdomain returns "pm: no project is assigned"** — the project exists in state
but its Caddy route is missing. Restart the daemon to rebuild every route from
`state.json`: `systemctl restart pmd`.

**Routes disappear after a Caddy restart** — they shouldn't; `pmd` re-asserts
them on boot. If they do, Caddy is not reachable on `127.0.0.1:2019` and
`PM_CADDY_ADMIN` is wrong.

**Port already in use** — pm assigns the first free port in `4096-5000`. Change
the range with `PM_PORT_RANGE` in the unit and restart.

## Design notes

**Why the daemon runs as root.** It has to drive `systemctl` and write
`/etc/systemd/system`, both root-only. Project code does *not* run as root:
every `pm-<name>` unit runs as the unprivileged `pm` user with
`NoNewPrivileges=true`, bound to loopback only, with Caddy as the only public
door.

**Why the gate has no token.** Caddy calls `ask` without credentials, so that one
endpoint cannot require them. It is therefore loopback-only, and the daemon
itself binds `127.0.0.1`.

**Coexisting with an existing gate.** Caddy allows exactly one `on_demand_tls`
block per config. If one already exists, the installer repoints its `ask` at
`pmd` and records the old endpoint in `PM_FALLBACK_ASKS`; `pmd` then delegates
unknown domains to it, so pre-existing sites keep getting certificates. Verified
by the regression case in `test/caddy-config-test.sh`.

**Ordering matters for Caddy routes.** `pmd` writes exact-host routes *before*
the wildcard block so they win the match, and keeps every route it does not own.
Replacing that list takes `DELETE` then `POST`: against Caddy 2.11 a `PUT` to the
routes array answers 409 `key already exists`, and a `POST` of an array into an
existing list answers 500. `test/fake-services.js` reproduces all three
responses so the suite cannot pass on a fake again.

**Re-running the installer restarts `pmd`.** `systemctl enable --now` does
nothing when the unit is already active, which would leave the old process
running with a stale `Environment=` — the failure mode that once emptied
`PM_FALLBACK_ASKS` and broke oc2d's certificates. The installer now always
restarts, and recovers the previous fallback gate from the running unit when the
Caddyfile no longer names one.

## License

MIT — see `LICENSE`.
