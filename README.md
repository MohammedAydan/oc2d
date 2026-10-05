# oc2d — OpenCode 2 + Caddy installer

Installs the official **OpenCode 2** CLI and serves it over **HTTPS via Caddy**
as persistent, auto-restarting systemd services. Built to run once on a messy
host and survive reboots, crashes and re-runs without intervention.

```bash
./install-opencode.sh --domain example.com
```

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

## Flags

| Flag | Default | Notes |
|---|---|---|
| `--domain <d>` | **required** | Domain to serve with automatic HTTPS |
| `--port <n>` | `4096` | Internal OpenCode port. Busy → auto-shifts |
| `--password <pw>` | generated | Persisted, so restarts don't invalidate your session |
| `--cors <origin>` | served domain | Extra allowed CORS origin; repeatable |
| `--skip-dns-check` | off | Proceed even if the A record doesn't point here |
| `--upgrade` | off | Reinstall OpenCode even if already current |
| `--strict-port` | off | Abort on a busy port instead of auto-shifting |
| `--uninstall` | | Remove the user unit and the domain's Caddy block |
| `--purge` | | With `--uninstall`, also delete the binary and password |
| `-h`, `--help` | | Usage |

Env: `OPENCODE_PASSWORD` sets the password when `--password` is absent.

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

```bash
# OpenCode
systemctl --user status  opencode.service
systemctl --user restart opencode.service
systemctl --user stop     opencode.service
journalctl --user -u opencode.service -f

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
- The password is stored `0600` in `~/.config/opencode/env` and passed through
  `EnvironmentFile`, so it does not appear in `systemctl show` output.
- The unit uses systemd's `%h`, so nothing is hardcoded to `/home/<user>`.

## Uninstall

```bash
./install-opencode.sh --uninstall          # unit + this domain's Caddy block
./install-opencode.sh --uninstall --purge  # also the binary and password
```

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

## Troubleshooting

```bash
journalctl --user -u opencode.service -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
sudo caddy validate --config /etc/caddy/Caddyfile
ls -1 /etc/caddy/Caddyfile.bak.*        # merge backups
```

## License

MIT — see [LICENSE](LICENSE). History in [CHANGELOG.md](CHANGELOG.md).