#!/usr/bin/env bash
# pm installer — installs the pm daemon + MCP server, wires Caddy's on-demand
# TLS authorization gate to the daemon, and smoke-tests the whole path.
set -euo pipefail

DOMAIN="" PARENT="" SKIP_DNS=0
PREFIX="# pm-managed"
UNIT_NAME="pmd.service"
CADDYFILE="/etc/caddy/Caddyfile"

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: install-pm.sh --domain <domain> [--parent <domain>] [--skip-dns-check]

  --domain <d>       Domain to serve. The parent is its last two labels
                     (blog.example.com -> example.com) unless --parent is given.
  --parent <d>       Parent domain whose wildcard subdomains pm may expose.
  --skip-dns-check   Don't verify the wildcard A record.
  -h, --help         This text.

Requires root. Idempotent: safe to re-run.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--domain)         DOMAIN="${2:-}"; shift 2 ;;
		--parent)         PARENT="${2:-}"; shift 2 ;;
		--skip-dns-check) SKIP_DNS=1; shift ;;
		-h|--help)        usage; exit 0 ;;
		*)                usage >&2; die "unknown argument: $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install-pm.sh --domain example.com)"
[ -n "$DOMAIN" ] || { usage >&2; die "--domain is required"; }

DOMAIN="${DOMAIN,,}"
DOMAIN="${DOMAIN#\*.}"   # accept a wildcard prefix
DOMAIN="${DOMAIN%.}"
# Parent defaults to the last two labels of --domain (blog.example.com -> example.com).
if [ -n "$PARENT" ]; then
	PARENT="${PARENT,,}"; PARENT="${PARENT%.}"
else
	PARENT="$(echo "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
fi
NODE_BIN="$(command -v node)"

# ---------------------------------------------------------------- 1. prereqs
say "Checking prerequisites"
for c in node npm systemctl caddy dig curl jq python3 openssl; do
	command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
done
command -v systemctl >/dev/null && [ -d /run/systemd/system ] || die "not a systemd host"
ok "node $(node -v), caddy $(caddy version | awk '{print $1}')"

# ------------------------------------------------------------- 2. dns check
if [ "$SKIP_DNS" -eq 0 ]; then
	say "Verifying wildcard DNS for *.$PARENT"
	TEST="pm-test-$(date +%s).$PARENT"
	RESOLVED="$(dig +short "$TEST" A 2>/dev/null | tail -1 || true)"
	EXPECTED="$(curl -fsS --max-time 10 ifconfig.me 2>/dev/null | tr -d '[:space:]' || true)"
	if [ -z "$EXPECTED" ]; then
		EXPECTED="$(dig +short myip.opendns.com @resolver1.opendns.com 2>/dev/null | tail -1 || true)"
	fi
	[ -n "$EXPECTED" ] || die "cannot determine this server's public IP (needed for the DNS check; re-run with --skip-dns-check)"

	if [ "$RESOLVED" != "$EXPECTED" ]; then
		die "wildcard DNS is not configured.
    $TEST resolved to '${RESOLVED:-nothing}', expected '$EXPECTED'.

    Add these two A records at your DNS provider:
      A    $PARENT     -> $EXPECTED
      A    *.$PARENT   -> $EXPECTED

    Wildcard DNS is what lets pm serve any <name>.$PARENT without you
    touching DNS again. Allow ~10min to propagate, then re-run."
	fi
	ok "*.$PARENT -> $EXPECTED"
fi

# ------------------------------------------------------------------ 3. user
say "Creating service user and directories"
id -u pm >/dev/null 2>&1 || useradd --system --home-dir /srv/pm --shell /usr/sbin/nologin pm
install -d -o pm -g pm -m 0750 /srv/pm/projects
install -d -m 0755 /opt/pm/daemon /opt/pm/mcp
install -d -o pm -g pm -m 0750 /var/lib/pm
install -d -m 0750 /etc/pm
ok "user pm, /srv/pm/projects, /var/lib/pm, /etc/pm"

# ----------------------------------------------------------------- 4. token
if [ ! -s /etc/pm/token ]; then
	openssl rand -hex 32 > /etc/pm/token
	chmod 0600 /etc/pm/token
	say "Generated API token"
else
	say "Reusing existing API token"
fi
TOKEN="$(tr -d '[:space:]' < /etc/pm/token)"
ok "/etc/pm/token ($(wc -c < /etc/pm/token) bytes)"

# ---------------------------------------------------------------- 5. sources
say "Installing daemon and MCP server"
SRC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
for f in daemon/index.js daemon/package.json mcp/index.js mcp/package.json; do
	install -m 0644 "$SRC/$f" "/opt/pm/$f"
done
(cd /opt/pm/daemon && npm install --omit=dev --silent) || die "npm install failed in /opt/pm/daemon (needs network access to the npm registry)"
(cd /opt/pm/mcp   && npm install --omit=dev --silent) || die "npm install failed in /opt/pm/mcp (needs network access to the npm registry)"
ok "node modules installed"

# ------------------------------------------------------------- 6. caddy gate
say "Configuring Caddy on-demand TLS gate"
[ -f "$CADDYFILE" ] || die "no Caddyfile at $CADDYFILE"
install -m 0644 "$CADDYFILE" "$CADDYFILE.bak.$(date +%Y%m%d-%H%M%S)"
CADDY_BAK="$(ls -t "$CADDYFILE".bak.* | head -1)"
restore_caddy() {
	say "Caddy config failed validation — restoring $CADDY_BAK"
	cp -f "$CADDY_BAK" "$CADDYFILE"
	systemctl reload caddy || true
}

# Caddy allows exactly ONE on_demand_tls block in the whole file. If one already
# exists we take over its `ask` and remember the old endpoint, so the daemon can
# delegate unknown domains to it and existing sites keep working.
ASK_URL="http://127.0.0.1:8300/internal/check-domain"
OLD_ASKS="$(grep -E '^[[:space:]]*ask[[:space:]]' "$CADDYFILE" 2>/dev/null |
	sed -E 's#^[[:space:]]*ask[[:space:]]+##; s#[{].*##' | grep -v "$ASK_URL" | paste -sd, - || true)"

if grep -qE '^[[:space:]]*on_demand_tls' "$CADDYFILE"; then
	sed -i -E "s#^([[:space:]]*ask[[:space:]]+).*#\\1$ASK_URL#" "$CADDYFILE"
	ok "repointed existing on_demand_tls ask -> $ASK_URL"
else
	# A keyless block is global config and must be the very first thing in the
	# file, ahead of any leading comment lines Caddy would otherwise read first.
	{
		printf '{\n\ton_demand_tls {\n\t\task %s\n\t}\n}\n\n' "$ASK_URL"
		cat "$CADDYFILE"
	} > "$CADDYFILE.new" && mv "$CADDYFILE.new" "$CADDYFILE"
	ok "added global on_demand_tls block"
fi

# The wildcard site block. Real upstreams are injected through Caddy's admin API
# per project; this block only serves the TLS policy and a sane 404 fallback.
if grep -q "$PREFIX" "$CADDYFILE"; then
	ok "wildcard site block already present"
else
	{
		printf '\n%s — projects on *.%s\n' "$PREFIX" "$PARENT"
		printf '*.%s {\n\ttls {\n\t\ton_demand\n\t}\n\trespond "pm: no project is assigned to this subdomain" 404\n}\n' "$PARENT"
	} >> "$CADDYFILE"
	ok "added *.$PARENT site block"
fi

if ! caddy validate --adapter caddyfile --config "$CADDYFILE" >/tmp/pm-caddy-validate.$$ 2>&1; then
	cat /tmp/pm-caddy-validate.$$ >&2; rm -f /tmp/pm-caddy-validate.$$; restore_caddy; die "Caddyfile is invalid"
fi
rm -f /tmp/pm-caddy-validate.$$
systemctl reload caddy || die "failed to reload caddy"
ok "Caddyfile valid, caddy reloaded"

# ---------------------------------------------------------------- 7. unit
say "Installing $UNIT_NAME"
cat > "/etc/systemd/system/$UNIT_NAME" <<UNIT
[Unit]
Description=Project Manager Daemon
After=network-online.target caddy.service
Wants=network-online.target

[Service]
Type=simple
# pm must drive systemctl and write /etc/systemd/system, so it runs as root.
# Project code does NOT: every pm-<name> unit runs as the unprivileged pm user.
ExecStart=$NODE_BIN /opt/pm/daemon/index.js
Restart=always
RestartSec=5
Environment="PM_TOKEN_FILE=/etc/pm/token"
Environment="PM_PARENT=$PARENT"
Environment="PM_PROJECTS_DIR=/srv/pm/projects"
Environment="PM_UNITS_DIR=/etc/systemd/system"
Environment="PM_STATE=/var/lib/pm/state.json"
Environment="PM_PORT_RANGE=4096-5000"
Environment="PM_RUN_USER=pm"
Environment="PM_FALLBACK_ASKS=$OLD_ASKS"

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable --now "$UNIT_NAME" >/dev/null
ok "unit enabled and started"

say "Waiting for the daemon to answer /health"
healthy=0
for i in $(seq 1 30); do
	if curl -fsS --max-time 2 http://127.0.0.1:8300/health >/dev/null 2>&1; then healthy=1; break; fi
	sleep 1
done
if [ "$healthy" -ne 1 ]; then
	systemctl status "$UNIT_NAME" --no-pager >&2 || true
	journalctl -u "$UNIT_NAME" -n 30 --no-pager >&2 || true
	die "daemon never answered /health within 30s"
fi
ok "daemon healthy: $(curl -fsS http://127.0.0.1:8300/health)"

# ------------------------------------------------------------- 8. mcp config
say "Configuring the pm MCP server for OpenCode2"
OWNER="${SUDO_USER:-root}"
OWNER_GRP="$(id -gn "$OWNER" 2>/dev/null || echo root)"
TARGET_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
TARGET_HOME="${TARGET_HOME:-$HOME}"
CONF="$TARGET_HOME/.config/opencode/opencode.json"
install -d -m 0700 -o "$OWNER" -g "$OWNER_GRP" "$TARGET_HOME/.config/opencode"
[ -f "$CONF" ] || printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$CONF"

# OpenCode2 reads MCP servers from opencode.json's "mcp" key, not a separate
# mcp.json/mcpServers file. Merge so other servers in the file survive.
tmp="$(mktemp)"; chmod 0600 "$tmp"
jq --arg tok "$TOKEN" --arg node "$NODE_BIN" '.mcp.pm = {
      type: "local",
      command: [$node, "/opt/pm/mcp/index.js"],
      environment: { PM_TOKEN: $tok },
      enabled: true
    }' "$CONF" > "$tmp"
install -m 0600 -o "$OWNER" -g "$OWNER_GRP" "$tmp" "$CONF"
rm -f "$tmp"
ok "$CONF (mcp.pm)"

# ------------------------------------------------------------- 9. smoke test
if [ "${PM_SKIP_SMOKE:-0}" = "1" ]; then
	say "Skipping smoke test (PM_SKIP_SMOKE=1)"
else
	say "Smoke test: creating 'smoke' project on smoke.$PARENT"
	CREATE_OUT="$(curl -fsS -m 180 -X POST http://127.0.0.1:8300/projects \
		-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
		-d "{\"name\":\"smoke\",\"subdomain\":\"smoke.$PARENT\"}" || true)"

	if echo "$CREATE_OUT" | jq -e '.httpsReady == true' >/dev/null 2>&1; then
		ok "https://smoke.$PARENT is live with a valid certificate"
	else
		echo "$CREATE_OUT" | jq . 2>/dev/null || echo "$CREATE_OUT" >&2
		journalctl -u pmd -n 40 --no-pager >&2 || true
		journalctl -u caddy -n 40 --no-pager >&2 || true
		curl -fsS -m 30 -X DELETE "http://127.0.0.1:8300/projects/smoke?purge=1" \
			-H "Authorization: Bearer $TOKEN" >/dev/null 2>&1 || true
		die "smoke test failed: 'smoke' was not reachable over HTTPS within 90s.
    Most common causes:
      - ports 80/443 not open to the internet (Let's Encrypt cannot validate)
      - the wildcard A record added but not yet propagated"
	fi

	say "Smoke test: removing 'smoke'"
	curl -fsS -X DELETE "http://127.0.0.1:8300/projects/smoke?purge=1" \
		-H "Authorization: Bearer $TOKEN" >/dev/null
	ok "cleaned up"
fi

# ------------------------------------------------------------ 10. summary
cat <<EOF

$(printf '\033[1;32m pm is installed.\033[0m')

  parent domain   $PARENT
  daemon          127.0.0.1:8300  (systemd: $UNIT_NAME)
  state           /var/lib/pm/state.json
  token           /etc/pm/token

$(printf '\033[1mTry it from OpenCode2:\033[0m')
  pm_create({ name: "blog", subdomain: "blog.$PARENT" })
  pm_list()

$(printf '\033[1mOr over HTTP:\033[0m')
  curl -s -H "Authorization: Bearer \$(cat /etc/pm/token)" http://127.0.0.1:8300/projects | jq

$(printf '\033[1mDNS reminder:\033[0m')   already verified, but keep these in place:
  A    $PARENT     -> this server
  A    *.$PARENT   -> this server

$(printf '\033[1mTroubleshooting:\033[0m')
  systemctl status $UNIT_NAME
  journalctl -u $UNIT_NAME -f
  journalctl -u pmd-blog -f
EOF
