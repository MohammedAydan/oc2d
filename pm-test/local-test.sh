#!/usr/bin/env bash
# pm local test suite — exercises the daemon and MCP server end to end without
# touching the host: systemd, Caddy and /etc are all faked inside this directory.
#
#   ./pm-test/local-test.sh
#
# Covers: HTTP surface + auth, the on_demand_tls gate (including delegation to a
# pre-existing gate), create/start/stop/restart/delete, Caddy route build + route
# removal, atomic rollback on failure, and the MCP handshake + tools.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PM="$(dirname "$HERE")"
WORK="$HERE/.work"
PARENT="pmtest.example.com"
TOKEN="testtoken-$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n')"
API="http://127.0.0.1:8391"

PASS=0; FAIL=0
pass() { printf '  \033[1;32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '      %s\n' "$2"; FAIL=$((FAIL + 1)); }
section() { printf '\n\033[1;36m%s\033[0m\n' "$1"; }

# assert_eq <label> <expected> <actual>
assert_eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "expected [$2] got [$3]"; }
assert_ne() { [ "$2" != "$3" ] && pass "$1" || fail "$1" "did not expect [$2]"; }
assert_has() { case "$3" in *"$2"*) pass "$1";; *) fail "$1" "[$3] does not contain [$2]";; esac; }

# api <method> <path> [body] -> "HTTP_CODE\n<body>"
api() {
	local m="$1" p="$2" b="${3:-}" code
	if [ -n "$b" ]; then
		code=$(curl -s -o "$WORK/body" -w '%{http_code}' -X "$m" "$API$p" \
			-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$b")
	else
		code=$(curl -s -o "$WORK/body" -w '%{http_code}' -X "$m" "$API$p" -H "Authorization: Bearer $TOKEN")
	fi
	printf '%s\n' "$code"
	cat "$WORK/body"
}
status_of() { api "$@" | head -1; }
jqf() { sed -n "$1p" "$WORK/body" | jq -r "$2" 2>/dev/null; }
routes_of() { curl -s http://127.0.0.1:8390/config/apps/http/servers/srv0/routes; }
cleanup_pid() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; }

# ------------------------------------------------------------------ set-up
rm -rf "$WORK"; mkdir -p "$WORK"/{bin,state,projects,units,run,logs}
printf '%s' "$TOKEN" > "$WORK/token"; chmod 600 "$WORK/token"
install -m 0755 "$HERE/fake-systemctl" "$WORK/bin/systemctl"
install -m 0755 "$HERE/fake-journalctl" "$WORK/bin/journalctl"

export PATH="$WORK/bin:$PATH"
export PM_TOKEN_FILE="$WORK/token" PM_PARENT="$PARENT" PM_PROJECTS_DIR="$WORK/projects"
export PM_UNITS_DIR="$WORK/units" PM_STATE="$WORK/state/state.json" PM_PORT=8391
export PM_PORT_RANGE=4500-4600 PM_RUN_USER="$(id -un)" PM_CADDY_ADMIN=http://127.0.0.1:8390
export PM_FALLBACK_ASKS=http://127.0.0.1:8399/internal/check-domain
export PM_ALLOW_DOMAINS="opencode-site.$PARENT"
export PM_TEST_RUNDIR="$WORK/run" PM_READY_TIMEOUT_MS=10000 PM_HTTPS_TIMEOUT_MS=1500

node "$HERE/fake-services.js" >"$WORK/logs/fakes.log" 2>&1 &
FAKES=$!
# The shim gives *.pmtest.example.com a loopback address and a real TLS endpoint,
# so the daemon's https:// readiness probe exercises a genuine TLS request.
NODE_OPTIONS="--require $HERE/fake-dns-tls.js" \
	node "$PM/daemon/index.js" >"$WORK/logs/pmd.log" 2>&1 &
PMD=$!
trap 'cleanup_pid $PMD; cleanup_pid $FAKES' EXIT

for _ in $(seq 1 40); do curl -fsS --max-time 1 "$API/health" >/dev/null 2>&1 && break; sleep 0.25; done

printf '\033[1m pm local test suite\033[0m  (parent=%s, everything inside %s)\n' "$PARENT" "$WORK"

# ----------------------------------------------------------------- health
section "health + auth"
assert_eq "GET /health is 200" 200 "$(status_of GET /health)"
assert_eq "health reports the parent" "$PARENT" "$(jqf 1 .parent)"
assert_ne "daemon logged a Caddy route sync" 0 \
	"$(grep -c 'pmd listening' "$WORK/logs/pmd.log")"
assert_eq "GET /projects without a token is 401" 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' "$API/projects")"
assert_eq "GET /projects with a bad token is 401" 401 \
	"$(curl -s -o /dev/null -w '%{http_code}' -H 'Authorization: Bearer nope' "$API/projects")"

# ------------------------------------------------------- the TLS auth gate
section "on_demand_tls authorization gate"
gate() { curl -s -o "$WORK/body" -w '%{http_code}' "$API/internal/check-domain?domain=$1"; }
assert_eq "unknown domain is refused (403, no ACME burn)" 403 "$(gate random-$RANDOM.example.com)"
assert_eq "domain outside the parent is refused" 403 "$(gate evil.com)"
assert_eq "pre-existing gate still authorizes its own domain" 200 "$(gate legacy.example.com)"
# PM_ALLOW_DOMAINS: pmd is Caddy's whole gate once installed, so a host's own
# OpenCode site must be authorized explicitly or its certificate stops issuing.
assert_eq "PM_ALLOW_DOMAINS host is authorized (the OpenCode site)" 200 "$(gate opencode-site.$PARENT)"
assert_eq "gate also accepts POST {domain}" 200 \
	"$(curl -s -o /dev/null -w '%{http_code}' -X POST "$API/internal/check-domain" -H 'Content-Type: application/json' -d '{"domain":"legacy.example.com"}')"

# ------------------------------------------------------------- validation
section "create: validation"
assert_eq "bad name is 400" 400 "$(status_of POST /projects '{"name":"Bad_Name"}')"
assert_has "bad name explains the rule" 'want ^[a-z][a-z0-9-]{1,30}$' "$(jqf 1 .error)"
assert_eq "subdomain outside the parent is 400" 400 \
	"$(status_of POST /projects '{"name":"stray","subdomain":"stray.evil.com"}')"

# ------------------------------------------------------------------ create
section "create: blog"
assert_eq "POST /projects is 201" 201 "$(status_of POST /projects "{\"name\":\"blog\",\"subdomain\":\"blog.$PARENT\"}")"
BLOG_PORT="$(jqf 1 .port)"
assert_ne "a port was assigned from the range" "" "$BLOG_PORT"
case "$BLOG_PORT" in 4[56]??) pass "port $BLOG_PORT is inside PM_PORT_RANGE";; *) fail "port inside range" "got $BLOG_PORT";; esac
assert_eq "status is running" running "$(jqf 1 .status)"
# The point of the fake TLS endpoint: this must be TRUE, not merely present.
# A plain http.get against an https:// URL fails forever, so this is the
# assertion that catches a broken readiness probe.
assert_eq "httpsReady is true (real TLS request succeeded)" true "$(jqf 1 .httpsReady)"
assert_eq "https URL is reported back" "https://blog.$PARENT" "$(jqf 1 .https)"
assert_eq "unit file was written" "pm-blog.service" "$(ls "$WORK/units")"
assert_has "unit runs as an unprivileged user" "User=$(id -un)" "$(cat "$WORK/units/pm-blog.service")"
assert_has "unit is bound to loopback only" 'bind 127.0.0.1' "$(cat "$WORK/units/pm-blog.service")"
assert_eq "project dir was scaffolded" "index.html" "$(ls "$WORK/projects/blog")"
# pmd runs as root here (User= in the unit is the harness user), so without an
# explicit chown the tree would be root-owned and the unit could not read it.
assert_eq "project dir is owned by the unit's run user" "$(id -u)" \
	"$(stat -c '%u' "$WORK/projects/blog")"
assert_eq "the port really serves" "200" \
	"$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$BLOG_PORT/")"
assert_eq "it is persisted in state.json" "blog" "$(jq -r '.projects[0].name' "$WORK/state/state.json")"
assert_eq "GET /projects lists it" 1 "$(status_of GET /projects >/dev/null; jq '.projects | length' "$WORK/body")"
assert_eq "GET /projects/blog is 200" 200 "$(status_of GET /projects/blog)"
assert_eq "GET /projects/nope is 404" 404 "$(status_of GET /projects/nope)"
assert_eq "duplicate name is 409" 409 "$(status_of POST /projects '{"name":"blog"}')"
assert_has "duplicate subdomain is 409" "already in use" \
	"$(status_of POST /projects '{"name":"other","subdomain":"blog.'"$PARENT"'"}' >/dev/null; jqf 1 .error)"

section "caddy: route injection"
assert_has "exact-host route was added" "\"blog.$PARENT\"" "$(routes_of)"
assert_has "route dials the project port" "127.0.0.1:$BLOG_PORT" "$(routes_of)"
assert_eq "pre-existing route was preserved" 1 "$(routes_of | grep -c somebody-elses)"
assert_eq "exact-host route sorts before the wildcard" "blog.$PARENT" \
	"$(routes_of | jq -r '.[] | select(.match[0].host != null) | .match[0].host[0]' | grep -v somebody-elses | head -1)"
assert_eq "gate authorizes blog now" 200 "$(gate blog.$PARENT)"

section "create: a second project, then delete it"
assert_eq "POST /projects (second) is 201" 201 "$(status_of POST /projects '{"name":"second"}')"
assert_eq "second project got its own subdomain" "second.$PARENT" "$(jqf 1 .subdomain)"
assert_eq "gate authorizes the default subdomain" 200 "$(gate second.$PARENT)"
assert_eq "DELETE /projects/second is 200" 200 "$(status_of DELETE /projects/second)"
assert_eq "its unit file is gone" "" "$(ls "$WORK/units" | grep second || true)"
assert_eq "its route is gone from caddy" 0 "$(routes_of | grep -c "second.$PARENT")"
assert_eq "the gate refuses it again" 403 "$(gate second.$PARENT)"
assert_eq "state.json no longer lists it" 0 "$(jq '[.projects[] | select(.name=="second")] | length' "$WORK/state/state.json")"

# --------------------------------------------------------------- lifecycle
section "lifecycle: stop / start / restart"
assert_eq "POST stop is 200" 200 "$(status_of POST /projects/blog/stop)"
assert_eq "status becomes stopped" stopped "$(jqf 1 .status)"
assert_eq "the port stops answering" "000" "$(curl -s -o /dev/null -m 2 -w '%{http_code}' "http://127.0.0.1:$BLOG_PORT/")"
assert_eq "route survives a stop (TLS stays valid)" 1 "$(routes_of | grep -c "blog.$PARENT")"
assert_eq "POST start is 200" 200 "$(status_of POST /projects/blog/start)"
assert_eq "status is running again" running "$(jqf 1 .status)"
assert_eq "the port answers again" "200" "$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:$BLOG_PORT/")"
assert_eq "POST restart is 200" 200 "$(status_of POST /projects/blog/restart)"
assert_eq "still running after restart" running "$(jqf 1 .status)"
assert_eq "GET /projects/blog/logs is 200" 200 "$(status_of GET /projects/blog/logs?lines=20)"
assert_has "logs carry the unit's output" 'GET /' "$(jqf 1 .logs)"
assert_eq "logs of an unknown project is 404" 404 "$(status_of GET /projects/ghost/logs)"
assert_eq "stop/start of an unknown project is 404" 404 "$(status_of POST /projects/ghost/start)"

# ---------------------------------------------------------------- rollback
section "create: atomic rollback when a step fails"
# The fake systemctl fails on `enable --now`, so the create must unwind itself.
: > "$WORK/run/fail-systemctl"
ROLLBACK_ERR="$(status_of POST /projects '{"name":"doomed"}' | tail -1)$(jqf 1 .error)"
rm -f "$WORK/run/fail-systemctl"
assert_eq "no unit file survives" "" "$(ls "$WORK/units" | grep doomed || true)"
assert_eq "no project dir survives" "" "$(ls "$WORK/projects" | grep doomed || true)"
assert_eq "state.json is clean" 0 "$(jq '[.projects[] | select(.name=="doomed")] | length' "$WORK/state/state.json")"
assert_eq "no caddy route survives" 0 "$(routes_of | grep -c doomed || true)"
assert_eq "the gate refuses it" 403 "$(gate doomed.$PARENT)"
assert_has "the failed step is named" 'step "write systemd unit" failed' "$ROLLBACK_ERR"
assert_eq "blog is untouched by the failed create" "blog" \
	"$(jq -r '.projects[] | select(.name=="blog") | .name' "$WORK/state/state.json")"

# ------------------------------------------------------------ restart test
section "stale state entries are reconciled on daemon start"
assert_eq "blog is in state before the test" "blog" \
	"$(jq -r '.projects[] | select(.name=="blog") | .name' "$WORK/state/state.json")"
# Simulate an interrupted uninstall: the unit file disappears but state.json and
# the Caddy route remain. The next daemon start must drop the stale entry.
rm -f "$WORK/units/pm-blog.service"
cleanup_pid $PMD
node "$PM/daemon/index.js" >"$WORK/logs/pmd3.log" 2>&1 & PMD=$!
for _ in $(seq 1 40); do curl -fsS --max-time 1 "$API/health" >/dev/null 2>&1 && break; sleep 0.25; done
assert_eq "stale project dropped from state.json" 0 \
	"$(jq '[.projects[] | select(.name=="blog")] | length' "$WORK/state/state.json")"
assert_eq "its Caddy route was released" 0 "$(routes_of | grep -c "blog.$PARENT")"
assert_eq "the gate refuses its subdomain" 403 "$(gate blog.$PARENT)"
assert_has "the reason is logged" "no longer exists" "$(cat "$WORK/logs/pmd3.log")"

section "daemon restart re-asserts caddy routes from state.json"
# Recreate the project so there is something to rebuild.
assert_eq "recreate blog is 201" 201 "$(status_of POST /projects '{"name":"blog"}')"
BLOG_PORT="$(jqf 1 .port)"
cleanup_pid $PMD
node "$PM/daemon/index.js" >"$WORK/logs/pmd2.log" 2>&1 & PMD=$!
for _ in $(seq 1 40); do curl -fsS --max-time 1 "$API/health" >/dev/null 2>&1 && break; sleep 0.25; done
assert_eq "blog survived in state.json" "blog" "$(jq -r '.projects[0].name' "$WORK/state/state.json")"
assert_has "route was rebuilt after the restart" "\"blog.$PARENT\"" "$(routes_of)"
assert_has "route still dials the same port" "127.0.0.1:$BLOG_PORT" "$(routes_of)"
assert_eq "pre-existing route still preserved" 1 "$(routes_of | grep -c somebody-elses)"

# --------------------------------------------------------------- mcp server
section "MCP server (stdio)"
node "$HERE/mcp-client.js" "$PM/mcp/index.js" "$TOKEN" "$API" >"$WORK/logs/mcp.log" 2>&1
MCP_RC=$?
if [ "$MCP_RC" -eq 0 ]; then
	while IFS= read -r line; do
		case "$line" in
			"OK "*)   pass "${line#OK }" ;;
			"FAIL "*) fail "${line#FAIL }" ;;
			*)        printf '      %s\n' "$line" ;;
		esac
	done < "$WORK/logs/mcp.log"
else
	fail "mcp client exited $MCP_RC" "$(tail -3 "$WORK/logs/mcp.log" | paste -sd' ' -)"
fi

# ------------------------------------------------------------------ delete
section "delete: with and without purge"
assert_eq "POST /projects/shed is 201" 201 "$(status_of POST /projects '{"name":"shed"}')"
assert_eq "DELETE without purge keeps the files" 200 "$(status_of DELETE /projects/shed)"
assert_eq "project dir is still on disk" "index.html" "$(ls "$WORK/projects/shed")"
assert_eq "POST /projects/gone is 201" 201 "$(status_of POST /projects '{"name":"gone"}')"
assert_eq "DELETE purge=1 is 200" 200 "$(status_of DELETE '/projects/gone?purge=1')"
assert_eq "project dir is gone" "" "$(ls "$WORK/projects" | grep gone || true)"
assert_eq "state.json is back to just blog" "blog" \
	"$(jq -r '.projects | map(.name) | join(",")' "$WORK/state/state.json")"
assert_eq "no route remains for the deleted projects" 0 \
	"$(routes_of | grep -cE 'shed|gone' || true)"
assert_eq "blog's route is still in place" 1 "$(routes_of | grep -c "blog.$PARENT")"
assert_eq "DELETE of an unknown project is 404" 404 "$(status_of DELETE /projects/ghost)"

# ----------------------------------------------------------------- verdict
printf '\n\033[1m %d passed, %d failed\033[0m\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
