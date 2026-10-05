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

## Troubleshooting

```bash
journalctl --user -u opencode.service -n 50 --no-pager
sudo journalctl -u caddy -n 50 --no-pager
sudo caddy validate --config /etc/caddy/Caddyfile
ls -1 /etc/caddy/Caddyfile.bak.*        # merge backups
```

## License

MIT — see [LICENSE](LICENSE). History in [CHANGELOG.md](CHANGELOG.md).