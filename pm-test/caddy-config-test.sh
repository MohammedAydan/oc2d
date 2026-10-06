#!/usr/bin/env bash
# Verifies the two Caddyfile shapes install-pm.sh can produce actually load in
# Caddy. Read-only: it never writes to /etc/caddy.
set -uo pipefail
PASS=0; FAIL=0
pass() { printf '  \033[1;32m✓\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf '  \033[1;31m✗\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

command -v caddy >/dev/null || { echo "caddy not installed — skipping"; exit 0; }

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
ASK="http://127.0.0.1:8300/internal/check-domain"; PARENT="pmtest.example.com"; PREFIX="# pm-managed"

valid() { caddy validate --adapter caddyfile --config "$1" >/dev/null 2>&1; }

# Case A — host already has on_demand_tls (what this machine looks like).
cat > "$W/A" <<EOF
# an existing site
{
	on_demand_tls {
		ask http://127.0.0.1:8000/internal/check-domain
	}
}
keep.example.org {
	reverse_proxy 127.0.0.1:8000
}
EOF
OLD="$(grep -E '^[[:space:]]*ask[[:space:]]' "$W/A" | sed -E 's#^[[:space:]]*ask[[:space:]]+##; s#[{].*##' | grep -v "$ASK" | paste -sd, -)"
[ "$OLD" = "http://127.0.0.1:8000/internal/check-domain" ] \
  && pass "the pre-existing ask endpoint is captured for delegation" \
  || fail "captures old ask" "got [$OLD]"

sed -i -E "s#^([[:space:]]*ask[[:space:]]+).*#\\1$ASK#" "$W/A"
{ printf '\n%s — projects on *.%s\n' "$PREFIX" "$PARENT"
  printf '*.%s {\n\ttls {\n\t\ton_demand\n\t}\n\trespond "pm: no project" 404\n}\n' "$PARENT"; } >> "$W/A"
valid "$W/A" && pass "case A: repointed on_demand_tls + wildcard block is valid Caddy" \
  || fail "case A valid" "$(caddy validate --adapter caddyfile --config "$W/A" 2>&1 | tail -1)"
[ "$(grep -c 'on_demand_tls {' "$W/A")" = "1" ] \
  && pass "case A: exactly one on_demand_tls block remains" \
  || fail "case A: single on_demand_tls" "found $(grep -c 'on_demand_tls {' "$W/A")"

# Idempotency: re-running must not add a second block or site.
sed -i -E "s#^([[:space:]]*ask[[:space:]]+).*#\\1$ASK#" "$W/A"
grep -q "$PREFIX" "$W/A" || { printf '\n%s\n' "$PREFIX"; printf '*.%s {\n\ttls {\n\t\ton_demand\n\t}\n}\n' "$PARENT"; } >> "$W/A"
[ "$(grep -c 'on_demand_tls {' "$W/A")" = "1" ] && [ "$(grep -c "$PREFIX" "$W/A")" = "1" ] \
  && pass "case A: re-running is idempotent (no duplicates)" \
  || fail "case A idempotent" "on_demand_tls=$(grep -c 'on_demand_tls {' "$W/A") marker=$(grep -c "$PREFIX" "$W/A")"

# Case B — fresh host with no on_demand_tls at all.
printf '# leading comment\nexample.com {\n\trespond "hi"\n}\n' > "$W/B"
{ printf '{\n\ton_demand_tls {\n\t\task %s\n\t}\n}\n\n' "$ASK"; cat "$W/B"; } > "$W/B2"
{ printf '\n%s — projects on *.%s\n' "$PREFIX" "$PARENT"
  printf '*.%s {\n\ttls {\n\t\ton_demand\n\t}\n\trespond "pm: no project" 404\n}\n' "$PARENT"; } >> "$W/B2"
valid "$W/B2" && pass "case B: global block + wildcard block is valid Caddy" \
  || fail "case B valid" "$(caddy validate --adapter caddyfile --config "$W/B2" 2>&1 | tail -1)"
head -1 "$W/B2" | grep -q '^{' && pass "case B: the global block is the very first line" \
  || fail "case B: global block first" "starts with: $(head -1 "$W/B2")"

# Regression: two global blocks must NOT validate (this is why pm repoints
# instead of appending when one already exists).
{ printf '{\n\ton_demand_tls {\n\t\task %s\n\t}\n}\n' "$ASK"; cat "$W/A"; } > "$W/BAD"
valid "$W/BAD" || pass "regression: appending a second on_demand_tls is correctly rejected"
valid "$W/BAD" && fail "regression: double global block should not validate" "it validated"

printf '\n\033[1m %d passed, %d failed\033[0m\n\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
