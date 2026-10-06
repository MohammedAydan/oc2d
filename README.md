# oc2d — Vibecoding Platform installer

**Stable release: v1.0.0** (pm daemon: v0.2.5). MIT licensed.

One command installs **OpenCode 2** behind **HTTPS via Caddy** and the **Project
Manager (pm)**, then wires pm into OpenCode as an MCP server. After that, the
agent inside the OpenCode chat can create and manage sites on subdomains of
your parent domain, each with its own valid certificate.

```bash
./install-opencode.sh --domain example.com
```

Then open `https://example.com`, log in, and type:

```
Create a project called blog at blog.example.com
```

There is no separate dashboard. OpenCode's built-in web UI *is* the interface;
the `pm_*` tools are how the agent gets that power.

## How the two halves fit

```
OpenCode 2 (web UI, the interface you use)
   │  MCP over stdio
   ▼
pm MCP server  ──HTTP──▶  pm daemon (pmd)
                             │
             ┌───────────────┴───────────────┐
             ▼                               ▼
     systemd unit per project        Caddy on_demand_tls gate
     (unprivileged user `pm`)        (issues one cert per subdomain)
```

`pmd` is also Caddy's TLS authorization gate. Caddy will not issue a
certificate for a name the gate refuses, which is what stops a stranger from
burning your Let's Encrypt quota. Because that makes pm the *whole* gate, the
installer tells it to authorize the OpenCode site itself as well.

## Requirements

- Ubuntu 22.04+ (or any systemd Linux), `systemd`
- `curl`, `dig`, `openssl`, `ss`, `loginctl`
- `sudo` (or root) — needed for Caddy and for enabling linger
- A domain whose **A/AAAA record already points at this host**, with **ports 80
  and 443 reachable from the internet**. Let's Encrypt validates over the public
  internet, so certificates cannot be issued otherwise. The script checks DNS
  and tells you exactly what to fix.

Run as your **normal user**, not root — the OpenCode service must read your own
config and credentials.

## DNS setup

Exactly two records are needed. Both must point at this host's **public** IP,
and ports 80 and 443 must be reachable from the internet, because Let's Encrypt
validates over the public internet.

| Type | Name | Value |
|------|------|-------|
| `A` | `example.com` | this host's public IP |
| `A` | `*.example.com` | this host's public IP |

Where `example.com` is your parent domain — the domain under which pm may expose
`blog.example.com`, `api.example.com`, and so on.

Check before installing:

```bash
dig +short example.com A
dig +short blog.example.com A     # the wildcard must answer for any name
```

If the wildcard is missing, every new project will be created but fail its HTTPS
readiness check, and pm's create call will roll the project back. The installer
verifies this itself and refuses to continue with the records to add if it does
not match, so you can also just run it and read the error.

---

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--domain <d>` | **required** | Domain to serve with automatic HTTPS |
| `--port <n>` | `4096` | Internal OpenCode port. Busy → auto-shifts |
| `--password <pw>` | see [Password](#password) | Use it verbatim; skips the prompt |
| `--generate-password` | off | Skip the prompt, generate a random password |
| `--cors <origin>` | served domain | Extra allowed CORS origin; repeatable |
| `--skip-dns-check` | off | Proceed even if the A record doesn't point here |
| `--upgrade` | off | Reinstall OpenCode even if already current |
| `--strict-port` | off | Abort on a busy port instead of auto-shifting |
| `--with-pm` | auto | Always install pm, never prompt |
| `--without-pm` | auto | Never install pm |
| `--pm-parent <d>` | detected, else prompted | Parent domain pm may expose subdomains under. Never guessed from `--domain` |
| `--skip-pm-smoke` | off | Let pm skip its own smoke test; the combined one still runs |
| `--uninstall` | | Remove the user unit and the domain's Caddy block |
| `--purge` | | With `--uninstall`, also delete the binary and password |
| `-h`, `--help` | | Usage |

Env: `OPENCODE_PASSWORD` sets the password when no password flag is given.

## Project Manager (pm)

You are asked once whether to install pm, unless `--with-pm` / `--without-pm`
says so. If `pmd.service` already exists it is re-verified, never reinstalled.

### The parent domain is not derived from `--domain`

These are independent, and conflating them is the single most common way to get a
failed install:

- `--domain code.example.com` — the one host serving OpenCode
- pm's **parent** — a domain with a wildcard record, whose *subdomains* pm hands out

The parent is often somewhere else entirely (OpenCode on `oc2d.example.com`
while pm serves `blog.apps.example.com`). So it is resolved in this order, never
guessed:

1. `--pm-parent`, if given
2. `PM_PARENT` from an already-running `pmd.service`
3. a `*.` block already in the Caddyfile whose wildcard resolves to this host
4. an interactive prompt explaining exactly what it is — the prompt is left empty
   on purpose, since any value pre-filled from `--domain` would be a parent you
   never chose. **Press Enter to skip pm**; the install still succeeds.
5. otherwise pm is **skipped** with the records to add — OpenCode still installs

A parent you supply yourself (`--pm-parent`, or typed at the prompt) is a
*request*, so if its wildcard does not point here the installer stops with exit 1
and tells you what it resolved to — before touching the filesystem. A parent pm
merely *detected* is only a guess, so that one skips quietly instead.

A parent needs a wildcard DNS record pointing here:

```
A    apps.example.com     -> this server
A    *.apps.example.com   -> this server
```

If the wildcard is missing the installer says so and tells you the exact records,
rather than failing an install that already succeeded. Exit status stays 0: pm is
optional, OpenCode 2 is the component that must not be broken.

| Tool the agent can call | Effect |
|---|---|
| `pm_create({name, subdomain?})` | scaffold, start, route, wait for HTTPS |
| `pm_list()` | every project with status, port, subdomain |
| `pm_status({name})` | one project's state |
| `pm_start` / `pm_stop` / `pm_restart` | control a project |
| `pm_delete({name, purge?})` | remove unit + route; `purge` deletes files |
| `pm_logs({name, lines?})` | recent journal output |

### Try these in the OpenCode chat

```
Create a static site called portfolio at portfolio.example.com
List all my projects
Stop the blog project
Delete the demo project and clean up its files
```

Each project becomes a systemd service running as the unprivileged `pm` user,
bound to loopback, reachable only through its subdomain.

## Password

The login user is always `opencode`. The password is chosen at install time and
can be changed afterwards without reinstalling anything.

### Choosing it during install

| How you run it | What happens |
|---|---|
| `./install-opencode.sh --domain d` in a terminal | **Interactive prompt** — hidden input, confirmed twice |
| the same, but piped or in CI (`echo "" \| ./install-opencode.sh …`) | **No prompt.** Reuses the stored password, or generates one |
| `… --password 'MyStrongPass123!'` | Uses it verbatim, no prompt |
| `… --generate-password` | Generates a strong random password, printed once |

```bash
# Install with interactive prompt (recommended)
./install-opencode.sh --domain example.com

# Install with a specific password
./install-opencode.sh --domain example.com --password 'MyStrongPass123!'

# Install with auto-generated password
./install-opencode.sh --domain example.com --generate-password
```

A prompt is shown **only when stdin is a terminal**, so piped runs, `systemd`
units and CI never block waiting for input.

An existing install **keeps its stored password** unless you pass `--password` or
`--generate-password`. Re-running the installer to upgrade something else
therefore never silently logs you out.

### Strength rules

Rejected outright, on every input path including `--password`: `password`,
`123456`, `admin`, `opencode`, `changeme`, `letmein`, `qwerty`, and anything
equal to the username.

Warned about but allowed after an explicit `y` at the prompt: shorter than 12
characters, or a single character class (all digits, all lowercase, all
uppercase, only symbols).

### Changing it later

```bash
# Change the password interactively (recommended)
./change-password.sh

# Change the password non-interactively
./change-password.sh --password 'NewStrongPass456!'

# Auto-generate a new password
./change-password.sh --generate
```

`change-password.sh` stops `opencode.service`, rewrites the single
`OPENCODE_PASSWORD=` line — any other lines in the file are preserved — starts
the service again and waits for the backend to answer on loopback.

**If the service does not come back, the previous password is restored
automatically**, so a failed change can never leave you locked out. The script
refuses to run if `~/.config/opencode/env` or `opencode.service` is missing, and
tells you to run the installer first.

### Where it is stored

`~/.config/opencode/env`, mode `0600`, in a `0700` directory:

```
OPENCODE_PASSWORD=…
```

The unit passes it in through `EnvironmentFile`, so it never appears in
`systemctl show` output. Interactive entry uses `read -s`, so the password is
not echoed and never reaches your shell history. A password you typed is not
printed back; only an auto-generated one is shown, and only once.

### If you lose the password

Run `./change-password.sh` **on the host** — it needs no login and no old
password.

If you cannot run it (no SSH access, for instance), edit the file by hand and
restart the service:

```bash
nano ~/.config/opencode/env            # set OPENCODE_PASSWORD=…
systemctl --user restart opencode.service
```

## Pre-flight detection

The script inspects the host before changing anything and adapts:

- **Caddy** — installed and running is reused untouched; installed but stopped
  is started and enabled; absent is installed from the official repository. A
  failed install aborts with the exact failing command and its real output.
- **OpenCode** — an existing V2 is kept (no reinstall) unless `--upgrade`; a V1
  binary is replaced, and `ExecStart` always uses the resolved absolute path so a
  distro V1 at `/usr/bin/opencode` can't shadow it on `PATH`.
- **systemd** — if `systemctl --user` has no user bus (containers, minimal
  images), it aborts *before* installing anything.
- **Linger** — enabled if missing; if it cannot be enabled (no sudo/polkit) it
  warns and continues, since the running stack is still valid.
- **Port** — free is used as-is; occupied by our own instance is reused;
  otherwise it shifts to the next free port, or aborts under `--strict-port`.
- **DNS** — compared against this host's public IP; mismatch aborts with
  instructions unless `--skip-dns-check`.

## Reboot resilience

- `opencode.service` is **enabled** (`systemctl --user enable`) *and* linger is
  enabled for your user, so it starts at boot with no login.
- The unit sets `Restart=always`, `RestartSec=5`, and
  `StartLimitIntervalSec=0` — the last one prevents systemd from rate-limiting a
  crash loop into a permanently dead unit.
- `caddy` is enabled via `sudo systemctl enable caddy`.
- The installer restarts both services, waits 10 seconds, and re-probes the
  backend and the HTTPS endpoint before reporting success.

### Verify reboot resilience yourself

```bash
systemctl --user is-enabled opencode.service   # enabled
sudo systemctl is-enabled caddy                # enabled
loginctl show-user "$USER" | grep Linger=yes   # Linger=yes
sudo systemctl restart opencode.service && sudo systemctl restart caddy
sleep 10
systemctl --user is-active opencode.service    # active
sudo systemctl is-active caddy                 # active
curl -s -o /dev/null -w '%{http_code}\n' https://example.com/
```

## Access and operations

Open the printed URL and log in with user `opencode` and the printed password.
If you chose the password yourself the installer prints
`Password: (as configured by user)` instead of echoing it back.

```bash
# OpenCode
systemctl --user status  opencode.service
systemctl --user restart opencode.service
systemctl --user stop     opencode.service
journalctl --user -u opencode.service -f

# Change the password (see the Password section)
./change-password.sh

# Caddy
sudo systemctl status  caddy
sudo systemctl restart caddy
sudo systemctl reload  caddy
journalctl -u caddy -f
```

Certificate renewal is automatic; Caddy reloads certs roughly 30 days before
expiry.

## Security notes

- **OpenCode binds to `127.0.0.1` only.** Caddy is the sole public-facing entry
  point. The installer actively verifies the backend is not bound to a public
  address.
- **Caddy handles public TLS** via Let's Encrypt / ZeroSSL. The installer checks
  the issuer is a real public CA.
- **Smart merge.** An existing `/etc/caddy/Caddyfile` is backed up to a timestamped
  `.bak` and merged into — never overwritten — and validated before reload, with
  rollback on failure. Pre-existing sites are probed after the run to prove they
  were not broken.
- The password is stored `0600` in `~/.config/opencode/env` (in a `0700`
  directory) and passed through `EnvironmentFile`, so it does not appear in
  `systemctl show` output. Neither script echoes it into logs or shell history.
- **Avoid backslashes and edge spaces in your password.** systemd's
  `EnvironmentFile` treats a backslash as an escape character and trims leading
  and trailing whitespace, so those would be stored but not received exactly as
  typed. Both scripts warn if your password contains either.
- The unit uses systemd's `%h`, so nothing is hardcoded to `/home/<user>`.

### Accepted risks

These are deliberate. Each is listed with what it would take to close it, so the
trade-off is visible rather than implied.

1. **`PM_TOKEN` reaches the MCP server through its environment.** A process
   running as the same user can read it from `/proc/<pid>/environ`. This is how
   MCP stdio servers receive configuration; there is no handshake that avoids it.
   To close it, hand the token to the MCP server on a file descriptor it opens
   itself, which would mean replacing stdio configuration.
2. **`/health` needs no token** and returns the parent domain and the project
   count. The daemon binds `127.0.0.1`, so this is only visible to processes on
   the host, and a project count is not sensitive. To close it, require the token
   — but Caddy and monitoring would then need credentials.
3. **A project unit is lightly sandboxed.** `NoNewPrivileges=true` and the
   process runs as the unprivileged `pm` user, but there is no `ProtectSystem` or
   `PrivateTmp`, so a project can read and write anything the `pm` user can —
   which is everything under `/srv/pm`. To close it, add the systemd sandbox
   directives; this was considered and deferred as a feature rather than a fix,
   because it can break legitimate projects that need to write elsewhere.
4. **A project is arbitrary code from the chat.** Whoever can use the OpenCode UI
   can have the agent create a project, and that project runs as `pm` on a public
   subdomain. This is the product's purpose, not a defect; the containment
   boundary is the `pm` user, not a container.
5. **The installer fetches and runs the official OpenCode installer** over the
   network. To close it, vendor and pin a checksum, at the cost of tracking
   upstream releases manually.
6. **`pmd` runs as root**, because it must drive `systemctl` and write
   `/etc/systemd/system`. Project code never does. Splitting the privileged
   control plane from the serving path would remove the need, but would also
   split pm into two services.

## Uninstall

```bash
./install-opencode.sh --uninstall                # unit + this domain's Caddy block
./install-opencode.sh --uninstall --purge        # also the binary and password
./install-opencode.sh --uninstall --with-pm      # also removes pm entirely
./install-opencode.sh --uninstall --with-pm --purge   # and all project data
```

Uninstalling with pm removes `pmd.service` and every project unit, deletes the
`pm` entry from `opencode.json` while leaving any other MCP server intact, and
**restores the `on_demand_tls` gate that pm took over** — so a pre-existing
installation that was sharing the gate keeps working. Project files and
`state.json` survive unless you add `--purge`.

Caddy itself is left installed, since other sites may depend on it. Linger is
left enabled; remove it with `sudo loginctl disable-linger "$USER"`. `--purge`
keeps `~/.config/opencode` (your projects and history); delete it by hand to
erase everything.

## Verification

The installer ends with an explicit tally:

```
[OK]   N checks passed
[WARN] M checks warn (see above)
[FAIL] K checks failed (fatal)
```

Only **fatal** failures abort the install (exit 1). Fatal checks are: the OpenCode
unit being active, the backend answering on loopback, Caddy active, both units
enabled at boot, linger enabled, and the backend not being publicly bound.

Non-fatal (warn, exit 0): HTTPS not yet ready, certificate not yet issued,
certificate issuer not recognised, external reachability, and HTTPS still
provisioning after a restart.

**HTTPS and certificate checks are non-fatal on purpose.** With on-demand TLS
Caddy issues a certificate lazily, on the first request, so the certificate is
routinely absent seconds after install. The installer nudges the ACME HTTP-01
challenge with a `:80` request and then retries HTTPS for up to ~120 seconds
(24 attempts, 5s apart), reporting `[wait] HTTPS not ready yet (attempt N/24)...`.

Reboot resilience is judged on the backend's loopback health, never on HTTPS, so a
pending certificate can never be mistaken for a reboot failure.

## When the Domain Uses On-Demand TLS

If your host's Caddy already serves a wildcard block with on-demand TLS, you need
to understand one external dependency before running the installer.

**What on-demand TLS is.** Normally Caddy issues a certificate for every name it
is configured to serve, at startup. With `tls { on_demand }`, Caddy issues a
certificate **only when a name is first requested**, and only if an authorization
endpoint approves it. A typical host config looks like this:

```caddyfile
{
    on_demand_tls {
        ask http://127.0.0.1:8000/internal/check-domain
    }
}

*.example.com {
    tls { on_demand }
    reverse_proxy 127.0.0.1:8000
}
```

The `ask` endpoint is a gate owned by **whatever application backs that control
plane** — not by `oc2d`.

**What the installer does about it.** It detects the wildcard and `on_demand`
policy, and emits a matching `tls { on_demand }` block for your domain so the two
agree on how TLS is obtained. Without this, overlapping blocks disagree and the
handshake fails with `tlsv1 alert internal error`. The installer **never modifies
the wildcard block or the `ask` endpoint.**

**What the installer cannot do.** It cannot register your subdomain in that
control plane. If the gate does not approve the name, **no certificate will ever
be issued for it, no matter how long anyone waits.** This is an authorization
decision in another system, and it is **not an `oc2d` responsibility or bug**.

### Check whether your subdomain is registered

Run this **before** installing:

```bash
curl -H "Host: code.example.com" http://127.0.0.1:8000/internal/check-domain
```

| Response | Meaning |
|---|---|
| `200` | Registered — the installer can obtain a certificate for it. |
| `404` | **Not registered.** Caddy will refuse to issue, forever. |
| `403` | Registered but explicitly denied. |
| `422` | The name is not a valid subdomain for this gate. |
| Connection refused | The control plane is down, or there is no `ask` gate here. |

A `404` from this endpoint is the single most useful thing to check when HTTPS
does not come up. It is authoritative: no amount of retrying will change it.

To find the real gate on your host:

```bash
grep -A3 'on_demand_tls' /etc/caddy/Caddyfile
```

### If the gate returns 404

Three options, in order of preference:

**Option A — Register the subdomain in the control plane.** Ask whoever owns the
application on `127.0.0.1:8000` to register the name, then re-run the
installer. This keeps one wildcard and one certificate strategy.

**Option B — Use a subdomain that is already registered.** If one exists, use it:

```bash
./install-opencode.sh --domain already-registered.example.com
```

**Option C — Serve a separate domain directly, outside the on-demand gate.** Add
its own explicit block so Caddy uses ordinary automatic HTTPS for it. Only do this
if you own the DNS for that domain, and note it must not overlap the wildcard:

```caddyfile
other.example.net {
    reverse_proxy 127.0.0.1:4096
}
```

After registering, re-run the installer — it merges, does not duplicate, and will
confirm HTTPS within its retry window.

### Worked example from testing

On the host this project was validated against, `opencode.r.example` returned `200`
from the gate and serves HTTPS with a valid Let's Encrypt certificate, while
`opencode2.r.example` returned `404` and could never obtain one. Both installs
completed with **exit 0**: the first with all checks passing, the second with the
certificate checks correctly reported as warnings. The installer was correct in
both cases; only the second name lacked external authorization.

## Diagnostics

```bash
DOMAIN=code.example.com

# Watch Caddy provision certificates (the message you want is
# "certificate obtained successfully" or "enabling automatic TLS certificate management")
journalctl -u caddy -f

# Watch the OpenCode server itself
journalctl --user -u opencode.service -f

# Verify the HTTP -> HTTPS redirect (expect 308/301 to https://)
curl -v http://$DOMAIN/

# Verify the TLS handshake and the served content
curl -v https://$DOMAIN/

# Certificate validity dates
echo | openssl s_client -connect $DOMAIN:443 -servername $DOMAIN 2>/dev/null \
  | openssl x509 -noout -dates

# Is the domain authorized for on-demand TLS? (see above)
curl -H "Host: $DOMAIN" http://127.0.0.1:8000/internal/check-domain

# Which names does Caddy think it manages?
sudo journalctl -u caddy --since '-10 min' --no-pager | grep 'automatic TLS certificate management'
```

Interpreting the common outcomes:

| Symptom | Likely cause |
|---|---|
| `tlsv1 alert internal error` | `ask` gate denied the name (404/403), or a block needs `tls { on_demand }` |
| `502` from Caddy | OpenCode backend is down — check `systemctl --user status opencode.service` |
| `308` to HTTPS on port 80 | Correct; the redirect is working |
| `Cannot complete TLS handshake` | Certificate still provisioning, or no certificate issued |

### pm and MCP

| Symptom | Likely cause |
|---|---|
| Agent says it has no `pm_*` tools | The MCP entry is missing or OpenCode never restarted |
| `pm_create` fails with "port did not answer" | The project's unit failed to start — `pm_logs({name})` |
| A subdomain 404s with "no project assigned" | In `state.json` but its Caddy route is gone; `sudo systemctl restart pmd` rebuilds all routes |
| HTTPS fails on the OpenCode site after installing pm | The gate stopped authorizing it; check `PM_ALLOW_DOMAINS` in `pmd.service` |
| `TLS gate refuses <your domain>` | `pmd` owns `on_demand_tls` and was not told about your site — reinstall with `--with-pm` |

Verify the wiring yourself:

```bash
jq '.mcp.pm' ~/.config/opencode/opencode.json      # entry present
curl -su "opencode:$(cut -d= -f2 ~/.config/opencode/env)" \
  http://127.0.0.1:4096/api/mcp | jq                # pm status: connected
curl -s "http://127.0.0.1:8300/internal/check-domain?domain=your.domain"  # 200
```

The middle one is the authoritative answer: it is OpenCode's own view of its
MCP servers, not a guess from the config file.

## Troubleshooting

Start with the logs:

```bash
journalctl --user -u opencode.service -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
sudo journalctl -u pmd -n 50 --no-pager      # when pm is installed
sudo caddy validate --config /etc/caddy/Caddyfile
ls -1 /etc/caddy/Caddyfile.bak.*        # merge backups
```

### The ten failure modes worth knowing

1. **The project is created, then immediately rolled back, with a port error.**
   Ports 80 and 443 are not reachable from the internet, so Let's Encrypt cannot
   validate. Fix: open both in the firewall and at the security group. Confirm
   with `curl -s -o /dev/null -w '%{http_code}\n' http://<subdomain>` from another
   network.

2. **`pm_create` fails and the subdomain stays 404.** The TLS gate refused the
   name. Ask it directly:
   `curl -s "http://127.0.0.1:8300/internal/check-domain?domain=<sub>"`.
   A `403` means pm does not own that name — it must be under the parent, or
   listed with `--allow-domain`.

3. **A subdomain returns 404 but the project is listed.** Its route was released
   because the project is no longer in `state.json`, or the unit is missing. pm
   logs `dropping "<name>" — …` at startup; that line names the reason.

4. **The OpenCode site lost TLS after an installer re-run.** The allowlist that
   authorizes the apex was emptied. It is now merged across runs, but if you ever
   see it, re-run with `--allow-domain example.com` and check
   `sudo grep PM_ALLOW_DOMAINS /etc/systemd/system/pmd.service`.

5. **Every project 404s after a restart, with no pm error.** `state.json` could
   not be read. pm now says so explicitly and refuses to sync routes; the damaged
   file is kept as `state.json.unreadable.<timestamp>` next to it. Repair the
   permissions, then restart.

6. **A project exists on disk but pm does not list it.** Its `state.json` entry
   was dropped for a stale path or subdomain, or its unit file is gone. Restore
   the unit, or recreate the project.

7. **The agent says `pm is not configured`.** `PM_TOKEN` is empty in
   `opencode.json`. Re-run `install-pm.sh`; it rewrites the `mcp.pm` entry with
   the current token.

8. **`systemctl --user` fails with "Interactive authentication required".**
   Linger is off, so there is no user session bus. Fix:
   `sudo loginctl enable-linger "$USER"`, then log out and back in.

9. **Caddy refuses to start after an install.** The installer validates before
   reloading and restores automatically, so this means something outside the
   installer edited the Caddyfile. Restore the newest backup:
   `sudo cp /etc/caddy/Caddyfile.bak.<timestamp> /etc/caddy/Caddyfile && sudo systemctl reload caddy`.

10. **`pm_create` answers `no free port in 4096-5000`.** Every port in the range
    is in use, usually by a leftover process. Find them with
    `sudo ss -ltnp | grep -E ':(409[6-9]|[45][0-9]{3})'`, or widen the range with
    `PM_PORT_RANGE` in the unit.

### Rollback

Both installers are idempotent and re-runnable, so the first response to a bad
upgrade is to re-run the previous release over the top. If a re-run is not
possible, restore from the backups the installer left behind:

```bash
TS=<timestamp of the backup>
sudo systemctl stop pmd.service
sudo rm -rf /opt/pm
sudo cp -r /opt/pm.pre-v02$TS /opt/pm
sudo cp /var/lib/pm/state.json.pre-v02$TS /var/lib/pm/state.json
sudo cp /etc/caddy/Caddyfile.pre-v02$TS /etc/caddy/Caddyfile
sudo systemctl daemon-reload
sudo systemctl start pmd.service
sudo systemctl reload caddy
curl -s -o /dev/null -w '%{http_code}\n' https://example.com/    # expect 200
```

The files are named `.pre-v023-<ts>`, `.pre-v024-<ts>` and `.pre-v025-<ts>` for
the releases that took them; `ls -1 /opt/pm.pre-v02* /var/lib/pm/*.pre-v02*` shows
what is available. Then verify the pre-existing projects still answer over HTTPS
before declaring the rollback good.

## Repository layout

```
install-opencode.sh   the platform installer (this is the entry point)
install-pm.sh         pm installer, called by the above; also runnable alone
daemon/               pm daemon (pmd)
mcp/                  pm MCP server
pm-test/              pm's test suite (89 + 7 assertions, no root needed)
pm-test/README.md     pm documentation and design notes
```

## License

MIT — see [LICENSE](LICENSE). History in [CHANGELOG.md](CHANGELOG.md).