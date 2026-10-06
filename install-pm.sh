#!/usr/bin/env bash
# pm installer — installs the pm daemon + MCP server, wires Caddy's on-demand
# TLS authorization gate to the daemon, and smoke-tests the whole path.
set -euo pipefail

DOMAIN="" PARENT="" SKIP_DNS=0
PREFIX="# pm-managed"
UNIT_NAME="pmd.service"
CADDYFILE="/etc/caddy/Caddyfile"
SKIP_SMOKE=0            # set by --skip-smoke, or when embedded in install-opencode.sh
DO_UNINSTALL=0
PURGE=0
ALLOW_DOMAINS=""        # extra hostnames pmd must authorize (comma-separated)

say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m warn:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
ok()   { printf '  \033[1;32m✓\033[0m %s\n' "$*"; }

usage() {
	cat <<EOF
Usage: install-pm.sh --domain <domain> [--parent <domain>] [--skip-dns-check] [--skip-smoke]

  --domain <d>       Domain to serve. The parent is its last two labels
                     (blog.example.com -> example.com) unless --parent is given.
  --parent <d>       Parent domain whose wildcard subdomains pm may expose.
  --skip-dns-check   Don't verify the wildcard A record.
  --skip-smoke       Don't create/verify/delete the smoke project.
  --allow-domain <d> Extra hostname pmd must authorize even though it is not a
                     pm project (repeatable, comma-separated). pmd is the whole
                     on_demand_tls gate once installed, so anything else needing
                     a certificate must be listed here.
  --uninstall        Remove the pm daemon, its files and the MCP entry.
  --purge            With --uninstall, also delete /var/lib/pm and /srv/pm.
  -h, --help         This text.

Requires root. Idempotent: safe to re-run.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--domain)         DOMAIN="${2:-}"; shift 2 ;;
		--parent)         PARENT="${2:-}"; shift 2 ;;
		--skip-dns-check) SKIP_DNS=1; shift ;;
		--skip-smoke)     SKIP_SMOKE=1; shift ;;
		--allow-domain)   ALLOW_DOMAINS="${ALLOW_DOMAINS:+$ALLOW_DOMAINS,}${2:-}"; shift 2 ;;
		--uninstall)      DO_UNINSTALL=1; shift ;;
		--purge)          PURGE=1; shift ;;
		-h|--help)        usage; exit 0 ;;
		*)                usage >&2; die "unknown argument: $1" ;;
	esac
done

[ "$(id -u)" -eq 0 ] || die "run as root (sudo ./install-pm.sh --domain example.com)"

# Uninstall needs no --domain: remove by whatever is on disk.
if [ "$DO_UNINSTALL" -eq 1 ]; then
	OWNER="${SUDO_USER:-root}"
	OWNER_GRP="$(id -gn "$OWNER" 2>/dev/null || echo root)"
	TARGET_HOME="$(getent passwd "$OWNER" | cut -d: -f6)"
	TARGET_HOME="${TARGET_HOME:-$HOME}"
	CONF="$TARGET_HOME/.config/opencode/opencode.json"

	say "Removing the pm daemon"
	systemctl stop "$UNIT_NAME" 2>/dev/null || true
	systemctl disable "$UNIT_NAME" 2>/dev/null || true
	rm -f "/etc/systemd/system/${UNIT_NAME}"
	systemctl daemon-reload || true
	systemctl reset-failed "$UNIT_NAME" 2>/dev/null || true
	ok "pmd.service stopped and removed"

	# Stop every project unit before deleting their state, so nothing is left
	# running against files that are about to disappear.
	if [ -s /var/lib/pm/state.json ]; then
		jq -r '.projects[]?.name' /var/lib/pm/state.json 2>/dev/null | while read -r n; do
			[ -n "$n" ] && systemctl disable --now "pm-${n}.service" >/dev/null 2>&1 || true
			rm -f "/etc/systemd/system/pm-${n}.service"
		done
		systemctl daemon-reload || true
		ok "project units stopped and removed"
	fi

	# Drop the MCP entry, leaving every other server in the file untouched.
	if [ -f "$CONF" ]; then
		tmp="$(mktemp)"; chmod 0600 "$tmp"
		if jq 'del(.mcp.pm)' "$CONF" > "$tmp" 2>/dev/null; then
			install -m 0600 -o "$OWNER" -g "$OWNER_GRP" "$tmp" "$CONF"
			ok "pm entry removed from $CONF"
		else
			warn "could not parse $CONF; left unchanged"
		fi
		rm -f "$tmp"
	fi

	# Restore the on_demand_tls ask endpoint pm replaced, if we recorded it.
	if [ -s /var/lib/pm/previous-ask ] && [ -f "$CADDYFILE" ]; then
		PREV="$(head -1 /var/lib/pm/previous-ask)"
		if [ -n "$PREV" ]; then
			cp -a "$CADDYFILE" "$CADDYFILE.bak.$(date +%Y%m%d-%H%M%S)"
			sed -i -E "s#^([[:space:]]*ask[[:space:]]+)http://127\\.0\\.0\\.1:8300/internal/check-domain#\\1$PREV#" "$CADDYFILE"
			if caddy validate --adapter caddyfile --config "$CADDYFILE" >/dev/null 2>&1; then
				systemctl reload caddy || true
				ok "restored the previous on_demand_tls ask endpoint: $PREV"
			else
				warn "revert would not validate; left $CADDYFILE alone (backup kept)"
			fi
		fi
	fi

	# The pm-managed wildcard site block, if we added it.
	if [ -f "$CADDYFILE" ] && grep -q "$PREFIX" "$CADDYFILE" && [ -n "$PARENT" ]; then
		say "Note: the '$PREFIX' block for *.$PARENT is left in $CADDYFILE;"
		say "      remove it by hand if you no longer want pm."
	fi

	rm -rf /opt/pm /etc/pm
	if [ "$PURGE" -eq 1 ]; then
		rm -rf /var/lib/pm /srv/pm
		ok "/opt/pm, /etc/pm, /var/lib/pm and /srv/pm removed"
	else
		rm -f /var/lib/pm/previous-ask
		printf 'Project data kept (/var/lib/pm, /srv/pm). Add --purge to delete it too.\n'
	fi
	ok "pm uninstalled. Caddy was left installed."
	systemctl --user restart opencode.service 2>/dev/null || true
	exit 0
fi

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
if id -u pm >/dev/null 2>&1; then
	say "User pm already exists"
else
	useradd --system --home-dir /srv/pm --shell /usr/sbin/nologin pm
fi
# useradd does NOT create or chown --home-dir, so /srv/pm does not exist at all.
# It must be created BEFORE the chown, or chown fails on a missing path and takes
# the whole install down with it.
mkdir -p /srv/pm
# Projects live under it and their units run as pm, which would otherwise fail to
# chdir into them.
chown pm:pm /srv/pm
chmod 0755 /srv/pm
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
	# Record what pm takes over, so --uninstall can hand the endpoint back.
	CUR="$(grep -E '^[[:space:]]*ask[[:space:]]' "$CADDYFILE" | head -1 |
		sed -E 's#^[[:space:]]*ask[[:space:]]+##; s#[{].*##' || true)"
	if [ -n "$CUR" ] && [ "$CUR" != "$ASK_URL" ]; then
		# Keep it on disk for --uninstall, and also print it: if this file is ever
		# lost, the operator still knows what to put back.
		install -d -m 0750 /var/lib/pm
		printf '%s\n' "$CUR" > /var/lib/pm/previous-ask
		say "noted the previous on_demand_tls gate: $CUR (--uninstall restores it)"
	fi
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

# Re-running must not forget an upstream gate. After the first install the only
# `ask` left in the Caddyfile is pm's own, so the fallback would be lost and
# pre-existing sites would start failing their TLS handshake. Recover it from
# the running unit when the Caddyfile no longer names one.
if [ -z "$OLD_ASKS" ] && systemctl is-active --quiet "$UNIT_NAME"; then
	PREV="$(systemctl show "$UNIT_NAME" -p Environment --value 2>/dev/null |
		sed -n 's/.*PM_FALLBACK_ASKS=\([^ ]*\).*/\1/p')"
	if [ -n "$PREV" ]; then
		OLD_ASKS="$PREV"
		say "recovered previous fallback gate(s): $OLD_ASKS"
	fi
fi

# The wildcard site block. Real upstreams are injected through Caddy's admin API
# per project; this block only serves the TLS policy and a sane 404 fallback.
#
# A wildcard block can only exist ONCE: Caddy rejects a second *.parent block
# with "ambiguous site definition". The parent may already be covered by a block
# this installer did not write (another tool, or a hand-written block), in which
# case adding ours would break the whole config.
WILDCARD_BLOCK="*.${PARENT} {"
if grep -qF "$PREFIX" "$CADDYFILE"; then
	ok "wildcard site block already present"
elif grep -qF "${WILDCARD_BLOCK}" "$CADDYFILE"; then
	# Already covered. Validate that the existing one keeps the on-demand policy
	# pm depends on; if not, say so rather than silently shipping a broken TLS
	# path for every pm subdomain.
	# -F and no ^ anchor: the pattern contains regex metacharacters (* . {) that
	# make an anchored pattern silently match nothing, which would report a false
	# "does not use on-demand TLS".
	if grep -F -A8 "${WILDCARD_BLOCK}" "$CADDYFILE" | grep -q 'on_demand'; then
		ok "wildcard *.$PARENT already exists (not pm's) with on-demand TLS; reusing it"
	else
		warn "*.$PARENT already exists but does NOT use on-demand TLS.
      pm needs on-demand TLS so certificates are issued per subdomain.
      Add 'tls { on_demand }' to that block, or pm subdomains will not get
      certificates."
	fi
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
Environment="PM_ALLOW_DOMAINS=$ALLOW_DOMAINS"

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable "$UNIT_NAME" >/dev/null
# `enable --now` is a NO-OP when the unit is already active, so a re-install
# would keep the old process and silently ignore a changed Environment= (which
# is how PM_FALLBACK_ASKS went stale and broke oc2d's TLS delegation).
# Always restart so the unit file just written is the one actually running.
systemctl restart "$UNIT_NAME"
ok "unit enabled and (re)started"

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
if [ "$SKIP_SMOKE" -eq 1 ]; then
	say "Skipping smoke test (--skip-smoke)"
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
