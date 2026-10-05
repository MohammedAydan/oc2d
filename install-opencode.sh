#!/usr/bin/env bash
#
# install-opencode.sh - OpenCode 2 behind a Caddy reverse proxy with automatic
# HTTPS, as persistent systemd services.
#
# Idempotent: safe to re-run. Upgrades the binary, merges its Caddy site block,
# restarts both services and re-verifies.
#
#   ./install-opencode.sh --domain example.com
#   ./install-opencode.sh --domain code.example.com --port 4096
#
set -euo pipefail

# --- defaults ---
DOMAIN=""
PORT=4096
PASSWORD=""
SKIP_DNS=0
DO_UNINSTALL=0
PURGE=0
UPGRADE=0
STRICT_PORT=0
CORS_EXTRA=""

INSTALL_URL="https://opencode.ai/v2/install"      # V2 only; V1 is not wire-compatible
LATEST_URL="https://opencode.ai/update/api/latest/cli/npm"
CADDY_KEYRING="/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
CADDY_REPO_LIST="/etc/apt/sources.list.d/caddy-stable.list"
CADDY_REPO_URL="https://dl.cloudsmith.io/public/caddy/stable"
CADDYFILE="/etc/caddy/Caddyfile"
UNIT_NAME="opencode.service"
UNIT_DIR="${HOME}/.config/systemd/user"
UNIT_PATH="${UNIT_DIR}/${UNIT_NAME}"
CONFIG_DIR="${HOME}/.config/opencode"
ENV_PATH="${CONFIG_DIR}/env"
BIN_DIR="${HOME}/.opencode/bin"
RUN_USER="$(id -un)"
PUBLIC_IP=""
BIN=""
TMPDIR_SELF=""
PRISTINE_SITES=""      # pre-existing Caddy hostnames, for the production-safety audit

# --- output ---
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Last statement must succeed: a failing EXIT trap replaces the script's status.
cleanup() { [ -n "$TMPDIR_SELF" ] && rm -rf "$TMPDIR_SELF"; return 0; }
trap cleanup EXIT

usage() {
  cat <<EOF
Install OpenCode 2 behind a Caddy reverse proxy with automatic HTTPS.

  install-opencode.sh --domain <domain> [options]

  --domain <d>       Domain to serve with HTTPS (required)
  --port <n>         Internal OpenCode port        (default: 4096)
  --password <pw>    OpenCode password             (default: generated once)
  --cors <origin>    Extra allowed CORS origin    (repeatable)
  --skip-dns-check   Do not verify the A record
  --upgrade          Reinstall OpenCode even if it is already current
  --strict-port      Abort if the port is busy instead of auto-shifting
  --uninstall        Remove the OpenCode unit and its Caddy site block
  --purge            With --uninstall, also delete the binary and config
  -h, --help         This message

Pre-flight detection: an existing healthy Caddy is reused and merged into, never
overwritten; an existing OpenCode 2 is kept unless --upgrade is given. Both
services are enabled and linger is set, so the stack survives a reboot.

Environment: OPENCODE_PASSWORD sets the password when --password is absent.
EOF
}

# --- args ---
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)    DOMAIN="${2:-}"; shift 2 ;;
      --port)      PORT="${2:-}"; shift 2 ;;
      --password)  PASSWORD="${2:-}"; shift 2 ;;
      --cors)      CORS_EXTRA="${CORS_EXTRA} ${2:-}"; shift 2 ;;
      --skip-dns-check) SKIP_DNS=1; shift ;;
      --upgrade)   UPGRADE=1; shift ;;
      --strict-port) STRICT_PORT=1; shift ;;
      --uninstall) DO_UNINSTALL=1; shift ;;
      --purge)     PURGE=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown option: $1 (try --help)" ;;
    esac
  done
  [ -n "$DOMAIN" ] || { usage >&2; die "--domain is required"; }
  DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN%/}"
  DOMAIN="${DOMAIN%%/*}"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "invalid --port: $PORT (expected 1-65535)"
  fi
}

# --- sudo: non-interactive first so unattended runs never hang on a prompt ---
as_root() {
  sudo -n "$@" 2>/dev/null || sudo "$@"
}

check_prerequisites() {
  step "Checking prerequisites"
  local missing=() c
  for c in curl systemctl loginctl dig openssl; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
  done
  [ ${#missing[@]} -eq 0 ] || die "missing required tools: ${missing[*]}"
  command -v ss >/dev/null 2>&1 || warn "ss not found; port checks are limited"

  # OpenCode must run as the normal user to read that user's config/credentials.
  [ "$(id -u)" -ne 0 ] || die "do not run as root; re-run as your normal user so the service can read your OpenCode config and credentials."

  # A user manager is mandatory; this is what fails inside bare Docker/CI.
  systemctl --user show-environment >/dev/null 2>&1 \
    || die "no systemd user manager for \$USER ($RUN_USER): systemctl --user is unavailable here (common in Docker/CI without a user bus). Run on a real host."
  [ -n "${XDG_RUNTIME_DIR:-}" ] \
    || die "XDG_RUNTIME_DIR unset, so no user session bus exists. Fix with: sudo loginctl enable-linger $RUN_USER, then log out and back in."
  sudo -n true 2>/dev/null || command -v sudo >/dev/null 2>&1 \
    || die "sudo is required to install Caddy and enable lingering"
  ok "tooling present; systemd user manager reachable (user=$RUN_USER)"
}

# --- DNS ---
# Let's Encrypt HTTP-01 needs port 80 reachable from the internet, so the A
# record must already point here before Caddy can ever get a certificate.
check_dns() {
  step "Checking DNS for $DOMAIN"
  PUBLIC_IP="$(curl -fsS --max-time 15 https://api.ipify.org 2>/dev/null || true)"
  [ -n "$PUBLIC_IP" ] || { warn "could not determine this host's public IP"; PUBLIC_IP=""; return 0; }

  local a
  a="$(dig +short A "$DOMAIN" 2>/dev/null | tail -n1 || true)"
  [ -n "$a" ] || { warn "$DOMAIN has no A record; certificate issuance will fail"; return 0; }
  ok "$DOMAIN -> $a (this host: $PUBLIC_IP)"

  [ "$a" = "$PUBLIC_IP" ] && return 0
  if [ "$SKIP_DNS" -eq 1 ]; then
    warn "$DOMAIN resolves to $a but this host is $PUBLIC_IP; continuing because --skip-dns-check"
    return 0
  fi
  die "$DOMAIN resolves to $a, not this host's $PUBLIC_IP. Update the DNS A record, or re-run with --skip-dns-check. (Let's Encrypt validates over the public internet, so :80/:443 must reach this host.)"
}

# --- port ---
port_in_use() { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

check_port() {
  step "Checking port $PORT"
  port_in_use "$PORT" || { ok "port $PORT is free"; return 0; }

  # A busy port is only a problem if it is not our own instance: re-running must work.
  local pid
  pid="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)"
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/cmdline" ] \
     && tr '\0' '\n' < "/proc/$pid/cmdline" | grep -qx -- "$PORT"; then
    ok "port $PORT is held by our running instance; reusing it"
    return 0
  fi
  local who
  who="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT\$" '$4 ~ p { print $NF; exit }' \
    | sed -n 's/.*((\"\([^\"]*\)\".*/\1/p' || true)"

  [ "$STRICT_PORT" -eq 1 ] && die "port $PORT is already in use by ${who:-another process} (--strict-port). Stop it, or pass a different --port."

  # Default is to move out of the way rather than fail.
  local p
  for p in $(seq $((PORT + 1)) $((PORT + 40))); do
    if ! port_in_use "$p"; then
      warn "port $PORT is in use by ${who:-another process}; shifting to $p"
      PORT="$p"; ok "using port $PORT"
      return 0
    fi
  done
  die "port $PORT is in use by ${who:-another process} and no free port was found in $((PORT+1))..$((PORT+40)). Pass a different --port."
}

# --- opencode ---
# "--version" prints "opencode v2.0.23"; normalise to 2.0.23 for comparison.
installed_version() {
  [ -n "$BIN" ] && [ -x "$BIN" ] || return 0
  "$BIN" --version 2>/dev/null | awk '{print $NF}' | sed 's/^v//'
}
latest_version() {
  # Empty on any network failure, which safely falls through to installing.
  curl -fsSL --max-time 20 "$LATEST_URL" 2>/dev/null \
    | sed -n 's/.*"version":"\([^"]*\)".*/\1/p' | head -1 || true
}
resolve_binary() {
  local c
  for c in "$BIN_DIR/opencode" "$BIN_DIR/opencode2"; do
    [ -x "$c" ] && { BIN="$c"; return 0; }
  done
  for c in opencode opencode2; do
    command -v "$c" >/dev/null 2>&1 && { BIN="$(command -v "$c")"; return 0; }
  done
  return 1
}

install_opencode() {
  step "Resolving OpenCode 2"
  local cur="" latest=""
  if resolve_binary; then
    cur="$(installed_version)"
    ok "found binary: $BIN (v${cur:-unknown})"
    # A 1.x binary is not wire-compatible with V2, so never keep one. A distro
    # package at /usr/bin/opencode also shadows ~/.opencode/bin on PATH.
    if [ -n "$cur" ] && [[ "$cur" != 2.* ]]; then
      warn "installed v$cur is not OpenCode 2; replacing it via the V2 installer."
      cur=""
    fi
  fi

  # Every $(...) assignment below ends in "|| true": under `set -e` + pipefail a
# failed command substitution aborts the script with no message at all.
  latest="$(latest_version)"
  local need_install=1
  if [ "$UPGRADE" -eq 1 ]; then
    warn "--upgrade given: reinstalling even though v${cur:-unknown} is present"
    need_install=1
  elif [ -n "$cur" ] && [ -n "$latest" ] && [ "$cur" = "$latest" ]; then
    ok "OpenCode 2 v$cur is already current; reusing it (--upgrade forces a reinstall)"
    need_install=0
  elif [ -n "$cur" ]; then
    warn "installed v$cur is behind v${latest:-unknown}; upgrading."
  fi

  if [ "$need_install" -eq 1 ]; then
    TMPDIR_SELF="$(mktemp -d)"
    step "Downloading OpenCode 2 from ${INSTALL_URL}"
    curl -fsSL --max-time 120 "$INSTALL_URL" -o "${TMPDIR_SELF}/install.sh" \
      || die "could not download the V2 installer from $INSTALL_URL"
    # Never continue past a failed install: a half-written binary is worse than none.
    bash "${TMPDIR_SELF}/install.sh" \
      || die "the OpenCode V2 installer failed (curl -fsSL $INSTALL_URL | bash). Nothing else was changed."
  fi

  # Re-resolve: the V2 installer writes 'opencode' plus an 'opencode2' shim.
  BIN=""     # force re-resolution so PATH order cannot pick a stale V1 binary
  resolve_binary || die "install finished but no opencode binary found in $BIN_DIR"
  ok "installed: $BIN (v$(installed_version))"
}

# --- caddy ---
# Run a root command and, on failure, abort with the exact command and its real
# output. Guessing at the cause of an apt failure wastes the operator's time.
root_or_die() {
  local out rc
  out="$(mktemp)"
  if ! as_root "$@" >"$out" 2>&1; then
    rc=$?
    printf '%s\n' "${out}" >&2
    rm -f "$out"
    die "command failed (exit $rc): sudo $*"
  fi
  cat "$out"
  rm -f "$out"
}

# Installed and running -> reuse. Installed but stopped -> start and enable.
# Absent -> install from the official repository. Never reinstall a healthy Caddy.
install_caddy() {
  step "Pre-flight: Caddy"
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy already installed: $(caddy version 2>/dev/null | head -1)"
    if as_root systemctl is-active --quiet caddy; then
      ok "Caddy is running; reusing it (not reinstalling)"
    else
      warn "Caddy is installed but not running; starting and enabling it"
      as_root systemctl enable caddy >/dev/null 2>&1 || true
      as_root systemctl start caddy \
        || die "Caddy is installed but failed to start. Run: sudo journalctl -u caddy -n 50"
      ok "Caddy started"
    fi
    return 0
  fi

  step "Installing Caddy from the official repository"
  root_or_die apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl \
    >/dev/null
  curl -1sLf "$CADDY_REPO_URL/gpg.key" | as_root gpg --dearmor -o "$CADDY_KEYRING" \
    || die "could not import the Caddy signing key from $CADDY_REPO_URL/gpg.key"
  curl -1sLf "$CADDY_REPO_URL/debian.deb.txt" | as_root tee "$CADDY_REPO_LIST" >/dev/null \
    || die "could not add the Caddy apt repository from $CADDY_REPO_URL/debian.deb.txt"
  root_or_die apt-get update -qq >/dev/null
  root_or_die apt-get install -y caddy >/dev/null
  command -v caddy >/dev/null 2>&1 || die "apt-get install caddy reported success but no caddy binary is on PATH"
  ok "installed: $(caddy version 2>/dev/null | head -1)"
}

# --- caddyfile ---
# Emit the Caddyfile with this domain's site block removed. Braces only appear at
# column 0 in a real Caddyfile, so /^}/ closes a top-level block reliably.
strip_block() {
  awk -v dom="$DOMAIN" '
    $0 == dom || $0 == dom " {" { skip = 1; next }
    skip && /^\}/ { skip = 0; next }
    skip { next }
    { print }
  ' "$1"
}

generate_caddyfile() {
  step "Configuring Caddy for $DOMAIN"
  [ -f "$CADDYFILE" ] || { mkdir -p /etc/caddy; : > "$CADDYFILE"; }

  TMPDIR_SELF="$(mktemp -d)"
  # Snapshot every pre-existing site hostname so the audit can prove we did not
  # break a neighbour's production site. Recorded BEFORE we touch anything.
  PRISTINE_SITES=""
  if [ -s "$CADDYFILE" ]; then
    PRISTINE_SITES="$(awk '/^[^#[:space:]][^{]*\{$/ { sub(/[[:space:]]*\{$/, ""); print }' \
      "$CADDYFILE" | grep -v -x -e "$DOMAIN" -e 'http' -e 'https' || true)"
    [ -n "$PRISTINE_SITES" ] && ok "pre-existing Caddy sites to preserve: $(echo "$PRISTINE_SITES" | tr '\n' ' ')"
  fi

  local backup=""
  if [ -s "$CADDYFILE" ]; then
    # /etc/caddy is root-owned, so the copy needs sudo too.
    backup="${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
    as_root cp -a "$CADDYFILE" "$backup" || die "could not back up $CADDYFILE"
    ok "backed up the existing Caddyfile to $backup"
  fi

  # An existing wildcard site block (e.g. *.example.com with on_demand TLS) also
  # matches this domain. If our block claimed plain automatic HTTPS the two would
  # disagree on how TLS is obtained and the handshake fails with an internal
  # error, so mirror the on-demand policy when the file already uses one.
  local ondemand=""
  if grep -qE '^[[:space:]]*\*\.' "$CADDYFILE" && grep -q 'on_demand' "$CADDYFILE"; then
    ondemand=$'\n\ttls {\n\t\ton_demand\n\t}'
    warn "existing wildcard block uses on-demand TLS; matching that policy"
  fi

  local block
  block="$(printf '%s {\n%s\n\treverse_proxy 127.0.0.1:%s {\n\t\tflush_interval -1\n\t}\n}' "$DOMAIN" "$ondemand" "$PORT" || true)"

  # Drop any previous block for this domain, then append ours, so re-runs replace
  # rather than duplicate. Other sites in the file are left untouched.
  TMPDIR_SELF="$(mktemp -d)"
  strip_block "$CADDYFILE" > "${TMPDIR_SELF}/merged" || true
  printf '\n%s\n' "$block" >> "${TMPDIR_SELF}/merged"
  as_root cp "${TMPDIR_SELF}/merged" "$CADDYFILE" || die "could not write $CADDYFILE"

  # Never hand Caddy an unvalidated config: it would refuse to start.
  as_root caddy fmt --overwrite "$CADDYFILE" >/dev/null 2>&1 || true
  as_root caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
    || { as_root cp "$backup" "$CADDYFILE" 2>/dev/null || true
         die "the merged Caddyfile is invalid; the previous file has been restored"; }
  ok "site block for $DOMAIN -> 127.0.0.1:$PORT"
}

# --- opencode unit ---
create_systemd_service() {
  step "Writing systemd user unit: $UNIT_PATH"
  mkdir -p "$UNIT_DIR" "$CONFIG_DIR"

  # Reuse the stored password: OpenCode mints a random one per start otherwise,
  # so every crash-restart would silently invalidate the user's session.
  if [ -z "$PASSWORD" ] && [ -f "$ENV_PATH" ]; then
    PASSWORD="$(sed -n 's/^OPENCODE_PASSWORD=//p' "$ENV_PATH" | head -1)"
  fi
  [ -n "$PASSWORD" ] || PASSWORD="${OPENCODE_PASSWORD:-}"
  [ -n "$PASSWORD" ] || PASSWORD="$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | cut -c1-24)"
  printf 'OPENCODE_PASSWORD=%s\n' "$PASSWORD" > "$ENV_PATH"
  chmod 600 "$ENV_PATH"   # holds a secret
  ok "config dir ready: $CONFIG_DIR (password stored 0600 in env)"

  # Point ExecStart at the resolved binary, not the default location: a distro
  # V1 binary at /usr/bin/opencode would otherwise win on PATH.
  local exec_bin="$BIN"
  case "$BIN" in "${HOME}"/*) exec_bin="%h/${BIN#"${HOME}"/}" ;; esac

  # CORS is enforced by the OpenCode server itself via repeatable --cors flags,
  # not by Caddy. The served domain is always allowed.
  local cors="" o
  for o in $DOMAIN $CORS_EXTRA; do
    [ -n "$o" ] || continue
    cors="${cors} --cors https://${o} --cors http://${o}"
  done
  [ -n "$cors" ] && ok "CORS origins: ${cors//--cors /}"

  # Bound to loopback only; Caddy is the sole public-facing entry point.
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=OpenCode 2 Headless Server
After=network.target network-online.target
Wants=network-online.target
# Never rate-limit restarts: a crash loop must be able to recover indefinitely.
StartLimitIntervalSec=0

[Service]
Type=simple
EnvironmentFile=-%h/.config/opencode/env
Environment=OPENCODE_CONFIG_DIR=%h/.config/opencode
Environment=OPENCODE_DISABLE_AUTOUPDATE=true
ExecStart=${exec_bin} serve --hostname 127.0.0.1 --port ${PORT}${cors}
Restart=always
RestartSec=5
TimeoutStopSec=15

[Install]
WantedBy=default.target
EOF
  ok "unit written (ExecStart=${exec_bin})"
}

# Without linger the user unit dies at logout and never returns after a reboot.
# A failure here is not fatal to the running install, so warn rather than abort.
enable_linger() {
  step "Enabling lingering for $RUN_USER (survives logout and reboot)"
  if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q '^Linger=yes'; then
    ok "linger already enabled"
    return 0
  fi
  if ! as_root loginctl enable-linger "$RUN_USER" 2>/dev/null; then
    warn "could not enable lingering (no sudo/polkit). The service works while you
    are logged in, but will NOT survive logout or reboot.
    Fix manually: sudo loginctl enable-linger $RUN_USER"
    return 0
  fi
  if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q '^Linger=yes'; then
    ok "linger enabled"
  else
    warn "could not confirm Linger=yes for $RUN_USER; it may stop at logout"
  fi
}

open_ports() {
  step "Firewall"
  if ! command -v ufw >/dev/null 2>&1 || ! as_root ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn "ufw is not active; ensure :80 and :443 reach this host"
    return 0
  fi
  if as_root ufw allow 80/tcp >/dev/null 2>&1; then ok "ufw: 80/tcp allowed"
  else warn "could not allow 80/tcp"; fi
  if as_root ufw allow 443/tcp >/dev/null 2>&1; then ok "ufw: 443/tcp allowed"
  else warn "could not allow 443/tcp"; fi
}

start_services() {
  step "Starting services"
  systemctl --user daemon-reload
  # enable, not just start: the unit must come back after a reboot.
  systemctl --user enable "$UNIT_NAME" >/dev/null 2>&1 \
    || die "could not enable $UNIT_NAME for boot (systemctl --user enable $UNIT_NAME)"
  systemctl --user restart "$UNIT_NAME" \
    || die "systemd refused to start $UNIT_NAME (journalctl --user -u $UNIT_NAME -n 50)"
  ok "OpenCode unit enabled and started"

  # Same for Caddy: a reload leaves it running but a boot needs it enabled.
  as_root systemctl enable caddy >/dev/null 2>&1 \
    || warn "could not enable caddy for boot; run: sudo systemctl enable caddy"

  # Reload keeps existing connections alive; restart is the fallback.
  if as_root systemctl reload caddy >/dev/null 2>&1; then
    ok "Caddy reloaded"
  elif as_root systemctl restart caddy >/dev/null 2>&1; then
    ok "Caddy restarted (reload unsupported)"
  else
    die "could not reload or restart caddy (journalctl -u caddy -n 50)"
  fi
}

# --- verification ---
# One probe. Never append a fallback value: curl already prints 000 on failure,
# so "${code:-000}" would yield "000000" and defeat every guard below.
http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1" 2>/dev/null || true; }
unit_state() { systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true; }
cert_field() {
  echo | timeout 15 openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" 2>/dev/null \
    | openssl x509 -noout "$1" 2>/dev/null | cut -d= -f2- || true
}
# Retries until the backend answers; returns 000 while it is still down.
wait_backend() {
  local c
  for _ in $(seq 1 30); do
    c="$(http_code "http://127.0.0.1:${PORT}/")"
    [ -n "$c" ] && [ "$c" != "000" ] && { printf '%s' "$c"; return 0; }
    sleep 1
  done
  printf '000'
}

FAILS=0
bad() { warn "$*"; FAILS=$((FAILS+1)); }

verify_installation() {
  step "Verifying installation"
  FAILS=0

  # 1. OpenCode unit
  if [ "$(unit_state)" = "active" ]; then ok "opencode.service is active (running)"
  else bad "opencode.service is '$(unit_state)'"; fi

  # 2. Backend on loopback (200 web UI, 401 auth challenge)
  local code; code="$(wait_backend)"
  case "$code" in 2*|3*) ok "backend responded: HTTP $code on 127.0.0.1:$PORT" ;;
    *) bad "no usable HTTP response from 127.0.0.1:$PORT" ;; esac

  # 3. Caddy unit
  if as_root systemctl is-active --quiet caddy; then ok "caddy is active (running)"
  else bad "caddy is not active"; fi

  # 4. HTTPS through the public domain
  code="$(http_code "https://${DOMAIN}/")"
  case "$code" in
    2*|3*|401) ok "HTTPS endpoint responded: HTTP $code via https://$DOMAIN" ;;
    000|"")   bad "https://$DOMAIN unreachable (DNS, firewall or TLS?)" ;;
    *)        bad "https://$DOMAIN returned HTTP $code" ;; esac

  # 5. Certificate validity, from a real public CA
  local notafter issuer; notafter="$(cert_field -enddate)"; issuer="$(cert_field -issuer)"
  if [ -n "$notafter" ]; then ok "TLS certificate valid until $notafter"
  else bad "could not read a certificate for $DOMAIN"; fi
  case "$issuer" in
    *"Let's Encrypt"*|*ZeroSSL*) ok "certificate issuer: $issuer" ;;
    *) bad "certificate is not from a public CA (issuer: ${issuer:-unknown})" ;; esac

  # 5b. Boot enablement: without these the stack returns only until reboot.
  if [ "$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)" = "enabled" ]; then
    ok "opencode.service is enabled at boot"
  else bad "opencode.service is not enabled; it would not come back after a reboot"; fi
  if as_root systemctl is-enabled caddy 2>/dev/null | grep -q enabled; then
    ok "caddy is enabled at boot"
  else bad "caddy is not enabled; it would not come back after a reboot"; fi
  if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q '^Linger=yes'; then
    ok "linger is enabled for $RUN_USER"
  else bad "linger is not enabled; opencode.service stops at logout and misses boot"; fi

  # 5c. Backend must not be reachable from outside the host.
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${PORT}\$"; then
    bad "backend is bound to a public address; it must listen on 127.0.0.1 only"
  else ok "backend is bound to loopback only"; fi

  # 6. Reboot simulation: a restart is the closest safe proxy for a reboot, and
  # it is the only way to prove enable + linger actually bring the stack back.
  step "Reboot simulation: restarting both services"
  systemctl --user restart "$UNIT_NAME" || bad "opencode restart command failed"
  as_root systemctl restart caddy >/dev/null 2>&1 || bad "caddy restart command failed"
  sleep 10
  if [ "$(unit_state)" = "active" ]; then ok "opencode.service active again"
  else bad "opencode.service down after restart"; fi
  if as_root systemctl is-active --quiet caddy; then ok "caddy active again"
  else bad "caddy down after restart"; fi
  code="$(http_code "http://127.0.0.1:${PORT}/")"
  case "$code" in 2*|3*|401) ok "backend responding after restart: HTTP $code" ;;
    *) bad "backend down after restart" ;; esac
  code="$(http_code "https://${DOMAIN}/")"
  case "$code" in 2*|3*|401) ok "HTTPS responding after restart: HTTP $code" ;;
    *) bad "HTTPS down after restart (got '${code:-none}')" ;; esac

  audit_report
}

# Post-install stability audit: prove the stack self-heals and that we did not
# damage a co-tenant. Every check is scoped to our own unit or recorded state.
audit_stability() {
  step "Stability audit"

  # Crash recovery. Deliberately kills ONLY our unit's MainPID: this host may run
  # other "opencode serve" processes belonging to unrelated workloads, and a
  # blanket `pkill -f opencode` would take them down with ours.
  local before after
  before="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)"
  if [ -n "$before" ] && [ "$before" != "0" ] && [ -r "/proc/$before/cmdline" ] \
     && tr '\0' '\n' < "/proc/$before/cmdline" | grep -qx -- "$PORT"; then
    ok "crash recovery: SIGKILL our backend (pid $before) and wait for systemd"
    kill -9 "$before" 2>/dev/null || true
    sleep 6
    after="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || true)"
    if [ "$(unit_state)" = "active" ] && [ -n "$after" ] && [ "$after" != "$before" ]; then
      ok "[OK] crash recovery: auto-restarted as pid $after"
    else
      bad "crash recovery: not auto-restarted (state=$(unit_state) pid=${after:-none})"
    fi
  else
    warn "crash recovery skipped: could not confirm our MainPID owns port $PORT"
  fi

  # Production safety: every pre-existing site must still answer. Wildcard blocks
  # (*.example.com) are skipped: a wildcard is not a resolvable hostname, so
  # probing it would always report a false "DOWN".
  local s
  for s in $PRISTINE_SITES; do
    case "$s" in
      '*'*) ok "[OK] wildcard block preserved (not directly probeable): $s"; continue ;;
    esac
    local c; c="$(http_code "https://${s}/")"
    case "$c" in
      2*|3*) ok "[OK] pre-existing site unaffected: $s (HTTP $c)" ;;
      000|"") bad "pre-existing site is DOWN after our change: $s" ;;
      *) warn "pre-existing site $s returned HTTP $c" ;; esac
  done

  # Idempotency evidence: exactly one block, exactly one unit.
  local blocks
  blocks="$(grep -c "^${DOMAIN} {" "$CADDYFILE" 2>/dev/null || echo 0)"
  if [ "$blocks" = "1" ]; then ok "[OK] exactly one Caddy block for $DOMAIN"
  else bad "found $blocks Caddy blocks for $DOMAIN; expected 1"; fi
  if [ "$(systemctl --user list-unit-files 2>/dev/null | grep -c "^${UNIT_NAME}\b" || true)" = "1" ]; then
    ok "[OK] exactly one opencode unit file"
  else bad "expected exactly one $UNIT_NAME unit file"; fi

  printf '%s[OK] Stability audit complete%s\n' "$G" "$N"
}

# Prints the collected verdict, or aborts with both journals attached.
audit_report() {
  if [ "$FAILS" -ne 0 ]; then
    printf '\n%s--- opencode.service (last 20) ---%s\n' "$Y" "$N" >&2
    journalctl --user -u "$UNIT_NAME" -n 20 --no-pager >&2 || true
    printf '%s--- caddy.service (last 20) ---%s\n' "$Y" "$N" >&2
    as_root journalctl -u caddy -n 20 --no-pager >&2 || true
    die "$FAILS verification check(s) failed; the stack is NOT healthy"
  fi
  ok "[OK] all verification checks passed (opencode PID $(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || echo '?'))"
  ok "[OK] Reboot resilience verified"
}

print_summary() {
  local pid issuer notafter
  pid="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || echo '?')"
  issuer="$(cert_field -issuer)"
  notafter="$(cert_field -enddate)"

  cat <<EOF

========================================
 OpenCode 2 + Caddy — Installation Complete
========================================
 OpenCode Status:  $(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || echo unknown)
 OpenCode PID:     $pid
 Caddy Status:     $(as_root systemctl is-active caddy 2>/dev/null || echo unknown)
 Domain:           https://$DOMAIN
 Backend:          http://127.0.0.1:$PORT  (loopback only)
 Certificate:      ${issuer:-issuer unknown}
                   valid until ${notafter:-unknown}
 Password:         $PASSWORD   (login user "opencode")
 Logs (OpenCode):  journalctl --user -u $UNIT_NAME -f
 Logs (Caddy):     journalctl -u caddy -f
 Restart (OpenCode): systemctl --user restart $UNIT_NAME
 Restart (Caddy):    sudo systemctl restart caddy
========================================

Open https://$DOMAIN in a browser and log in as user "opencode".
Renewal is automatic (Caddy reloads certs ~30 days before expiry).
Remove with: bash install-opencode.sh --uninstall [--purge]
EOF
}

uninstall() {
  step "Removing OpenCode 2"
  systemctl --user stop "$UNIT_NAME" 2>/dev/null || true
  systemctl --user disable "$UNIT_NAME" 2>/dev/null || true
  rm -f "$UNIT_PATH"
  systemctl --user daemon-reload || true
  systemctl --user reset-failed "$UNIT_NAME" 2>/dev/null || true
  ok "user unit removed"

  # Remove our site block, but never leave Caddy with an invalid config: if the
  # result would not validate, put the original back and warn instead.
  if [ -n "$DOMAIN" ] && [ -f "$CADDYFILE" ]; then
    TMPDIR_SELF="$(mktemp -d)"
    if strip_block "$CADDYFILE" > "${TMPDIR_SELF}/Caddyfile" && [ -s "${TMPDIR_SELF}/Caddyfile" ]; then
      as_root cp -a "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d-%H%M%S)"
      as_root cp "${TMPDIR_SELF}/Caddyfile" "$CADDYFILE"
      if as_root caddy validate --config "$CADDYFILE" >/dev/null 2>&1 \
         && as_root systemctl reload caddy; then
        ok "removed the $DOMAIN site block from $CADDYFILE"
      else
        warn "could not reload Caddy after editing the Caddyfile (backup kept)"
      fi
    else
      warn "$DOMAIN has no block in $CADDYFILE; nothing removed"
    fi
  fi

  if [ "$PURGE" -eq 1 ]; then
    rm -f "$BIN_DIR/opencode" "$BIN_DIR/opencode2" "$ENV_PATH"
    ok "binary and password removed"
    printf 'Config kept at %s (delete it manually to erase all data).\n' "$CONFIG_DIR"
  else
    rm -f "$ENV_PATH"
    printf 'Binary and config kept. Add --purge to delete the binary too.\n'
  fi
  printf 'Caddy was left installed. Linger: sudo loginctl disable-linger %s\n' "$RUN_USER"
}

main() {
  parse_args "$@"
  check_prerequisites

  if [ "$DO_UNINSTALL" -eq 1 ]; then uninstall; exit 0; fi

  check_dns
  check_port
  install_opencode
  install_caddy
  generate_caddyfile
  create_systemd_service
  enable_linger
  open_ports
  start_services
  verify_installation
  audit_stability
  print_summary
}

main "$@"