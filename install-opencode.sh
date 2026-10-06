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
PW_MODE="auto"        # auto | given | generate; auto prompts only on a TTY
PW_SOURCE=""          # user | generated | reused — decided once the value is final
WITH_PM=""            # "" = auto-detect/prompt, "yes" = force, "no" = skip
PM_PARENT=""          # parent domain pm may expose subdomains under
PM_SKIP_SMOKE=0       # pm's own smoke test; the combined one still runs
PM_INSTALLED=0        # set once pm is known to be present and wired

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
TMPDIRS=()            # every temp dir created, so the trap can remove all of them
PRISTINE_SITES=""      # pre-existing Caddy hostnames, for the production-safety audit
SERVER_USER="opencode" # the only login user OpenCode accepts
MIN_PASSWORD_LEN=12    # below this we warn and require an explicit confirmation
MAX_PROMPT_ATTEMPTS=3  # interactive entry attempts before giving up

# --- output ---
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
err()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; }   # not fatal on its own
die()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

# Last statement must succeed: a failing EXIT trap replaces the script's status.
# TMPDIR_SELF is reassigned by several steps, so remove every registered dir.
cleanup() {
  local d
  for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rm -rf "$d"; done
  return 0
}
trap cleanup EXIT

# Registering each dir (rather than overwriting one variable) is what guarantees
# no temp dir survives a partial run.
mktmp() {
  TMPDIR_SELF="$(mktemp -d)"
  TMPDIRS+=("$TMPDIR_SELF")
  printf '%s' "$TMPDIR_SELF"
}

usage() {
  cat <<EOF
Install OpenCode 2 behind a Caddy reverse proxy with automatic HTTPS.

  install-opencode.sh --domain <domain> [options]

  --domain <d>       Domain to serve with HTTPS (required)
  --port <n>         Internal OpenCode port        (default: 4096)
  --password <pw>    Use this password              (skips the prompt)
  --generate-password  Skip the prompt, generate a random password
  --cors <origin>    Extra allowed CORS origin    (repeatable)
  --skip-dns-check   Do not verify the A record
  --upgrade          Reinstall OpenCode even if it is already current
  --strict-port      Abort if the port is busy instead of auto-shifting
  --with-pm          Always install the Project Manager (pm), never prompt
  --without-pm       Never install pm
  --pm-parent <d>    Parent domain pm may expose subdomains under
                     (default: the last two labels of --domain)
  --skip-pm-smoke    Let pm skip its own smoke test; the combined one still runs
  --uninstall        Remove the OpenCode unit and its Caddy site block
  --purge            With --uninstall, also delete the binary and config
  -h, --help         This message

What you get by default: OpenCode 2 behind HTTPS, plus the Project Manager (pm),
so the agent inside the chat can create and manage sites on subdomains of your
parent domain with valid certificates. When pm is already installed it is
re-verified rather than reinstalled; when it is not, you are asked once.

Password selection, in order of precedence:
  --password <pw>      use it verbatim
  --generate-password  generate a strong random one
  neither, on a TTY    prompt (hidden input, confirmed twice)
  neither, no TTY      reuse the stored password, or generate one
                       (the safe default for CI and piped runs)

An existing install keeps its stored password unless you pass --password or
--generate-password, so re-running never silently invalidates live sessions.
Change it later with: ./change-password.sh

Pre-flight detection: an existing healthy Caddy is reused and merged into, never
overwritten; an existing OpenCode 2 is kept unless --upgrade is given. Both
services are enabled and linger is set, so the stack survives a reboot.

Environment: OPENCODE_PASSWORD sets the password when no password flag is given.
EOF
}

# --- args ---
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --domain)    DOMAIN="${2:-}"; shift 2 ;;
      --port)      PORT="${2:-}"; shift 2 ;;
      --password)
        # An empty value would leave OPENCODE_PASSWORD= empty, which makes
        # OpenCode mint a new random password on every start.
        [ $# -ge 2 ] || die "--password needs a value"
        [ -n "$2" ] || die "--password needs a non-empty value"
        PASSWORD="$2"; PW_MODE="given"; shift 2 ;;
      --generate-password) PW_MODE="generate"; shift ;;
      --cors)      CORS_EXTRA="${CORS_EXTRA} ${2:-}"; shift 2 ;;
      --skip-dns-check) SKIP_DNS=1; shift ;;
      --upgrade)   UPGRADE=1; shift ;;
      --strict-port) STRICT_PORT=1; shift ;;
      --with-pm)  WITH_PM="yes"; shift ;;
      --without-pm) WITH_PM="no"; shift ;;
      --pm-parent) PM_PARENT="${2:-}"; shift 2 ;;
      --skip-pm-smoke) PM_SKIP_SMOKE=1; shift ;;
      --uninstall) DO_UNINSTALL=1; shift ;;
      --purge)     PURGE=1; shift ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown option: $1 (try --help)" ;;
    esac
  done
  [ -n "$DOMAIN" ] || { usage >&2; die "--domain is required"; }
  if [ "$PW_MODE" = "given" ] && [ "${OPENCODE_PASSWORD:-}" != "" ] && [ "$OPENCODE_PASSWORD" != "$PASSWORD" ]; then
    warn "both --password and OPENCODE_PASSWORD are set; using --password"
  fi
  DOMAIN="${DOMAIN#https://}"; DOMAIN="${DOMAIN#http://}"; DOMAIN="${DOMAIN%/}"
  DOMAIN="${DOMAIN%%/*}"
  if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    die "invalid --port: $PORT (expected 1-65535)"
  fi
  # pm exposes subdomains of a PARENT; --domain is the OpenCode site itself.
  # blog.example.com -> example.com.
  if [ -z "$PM_PARENT" ]; then
    PM_PARENT="$(printf '%s' "$DOMAIN" | awk -F. '{print $(NF-1)"."$NF}')"
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
    mktmp >/dev/null
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
# Run a root command and, on failure, abort with the exact command, its REAL exit
# code and its output.
#
# The exit code must be captured as `cmd || rc=$?`. Reading $? inside an
# `if ! cmd` block reports the *negation*, which is always 0, so a genuine
# failure would be misreported as "exit 0".
root_or_die() {
  local out rc=0
  out="$(mktemp)"
  TMPDIRS+=("$out")           # register so the EXIT trap cleans it up
  as_root "$@" >"$out" 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '%s--- output of: sudo %s ---%s\n' "$Y" "$*" "$N" >&2
    tail -n 20 "$out" >&2     # the real apt error, not a temp path
    rm -f "$out"
    die "command failed (exit $rc): sudo $*"
  fi
  cat "$out"
  rm -f "$out"
}

# Echo any of the given packages that are not currently installed, one per line.
missing_packages() {
  local pkg
  for pkg in "$@"; do
    dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null | grep -qx installed \
      || printf '%s\n' "$pkg"
  done
  return 0
}

# Installed and running -> reuse. Installed but stopped -> start and enable.
# Absent -> install from the official repository. Never reinstall a healthy Caddy.
install_caddy() {
  step "Pre-flight: Caddy"
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy already installed: $(caddy version 2>/dev/null | head -1)"
    if [ "$UPGRADE" -eq 1 ]; then
      step "Upgrading Caddy (--upgrade)"
      root_or_die apt-get update -qq >/dev/null
      root_or_die apt-get install -y --only-upgrade caddy >/dev/null
      ok "upgraded: $(caddy version 2>/dev/null | head -1)"
    elif as_root systemctl is-active --quiet caddy; then
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

  # On a fresh server the package lists are empty or stale, so apt-get install
  # fails outright. Update first, but only when something is actually missing.
  # Word splitting is intended here: this is a package list for apt-get.
  local missing_pkgs=()
  mapfile -t missing_pkgs < <(missing_packages debian-keyring debian-archive-keyring apt-transport-https curl)
  if [ "${#missing_pkgs[@]}" -gt 0 ]; then
    step "Updating apt package lists (fresh images ship without them)"
    root_or_die apt-get update -qq >/dev/null
    step "Installing Caddy apt prerequisites: ${missing_pkgs[*]}"
    root_or_die apt-get install -y "${missing_pkgs[@]}" >/dev/null
  else
    ok "Caddy apt prerequisites already installed; skipping apt-get update"
  fi

  curl -1sLf "$CADDY_REPO_URL/gpg.key" | as_root gpg --dearmor -o "$CADDY_KEYRING" \
    || die "could not import the Caddy signing key from $CADDY_REPO_URL/gpg.key"
  curl -1sLf "$CADDY_REPO_URL/debian.deb.txt" | as_root tee "$CADDY_REPO_LIST" >/dev/null \
    || die "could not add the Caddy apt repository from $CADDY_REPO_URL/debian.deb.txt"

  # The new repository needs its own update before caddy becomes visible.
  step "Refreshing apt lists for the Caddy repository"
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

  mktmp >/dev/null
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
  #
  # But only when the on-demand gate will actually authorize THIS domain. An
  # on_demand block whose gate answers 403 can never obtain a certificate, so
  # mirroring the policy there would silently leave the site on plain HTTP. When
  # pm is installed it authorizes $DOMAIN explicitly; otherwise fall back to
  # ordinary automatic HTTPS.
  local ondemand="" ask_endpoint gate_ok=0
  if grep -qE '^[[:space:]]*\*\.' "$CADDYFILE" && grep -q 'on_demand' "$CADDYFILE"; then
    ask_endpoint="$(grep -E '^[[:space:]]*ask[[:space:]]' "$CADDYFILE" | head -1 |
      sed -E 's#^[[:space:]]*ask[[:space:]]+##; s#[{].*##' || true)"
    if [ -n "$ask_endpoint" ]; then
      # No -f here: a 403 is the answer we need, not an error to swallow. -sS
      # keeps the probe quiet, -o /dev/null discards the body.
      gate_ok="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "${ask_endpoint}?domain=${DOMAIN}" 2>/dev/null || echo 000)"
      [ "$gate_ok" = "000" ] && gate_ok=000
    fi
    # The wildcard already matches $DOMAIN, so this block MUST use the same TLS
    # policy or the handshake fails with an internal error. pm is about to be
    # installed with --allow-domain, which makes the gate authorize $DOMAIN, so
    # the on-demand policy is the correct choice even before pm is running.
    if [ "$gate_ok" = "200" ] || [ "$WITH_PM" = "yes" ] || pm_installed; then
      ondemand=$'\n\ttls {\n\t\ton_demand\n\t}'
      warn "existing wildcard block uses on-demand TLS; matching that policy"
    else
      die "the on-demand TLS gate at ${ask_endpoint:-unknown} refuses $DOMAIN
    (HTTP ${gate_ok:-000}), but an existing wildcard block already matches
    $DOMAIN and uses on-demand TLS. Adding a block with a different policy makes
    the TLS handshake fail with an internal error, so this cannot be installed
    safely as-is.

    Fix it with either:
      --with-pm    (pm authorizes $DOMAIN and serves subdomains; recommended)
      --without-pm and remove or rename the existing '*.' wildcard block in $CADDYFILE"
    fi
  fi

  local block
  block="$(printf '%s {\n%s\n\treverse_proxy 127.0.0.1:%s {\n\t\tflush_interval -1\n\t}\n}' "$DOMAIN" "$ondemand" "$PORT" || true)"

  # Drop any previous block for this domain, then append ours, so re-runs replace
  # rather than duplicate. Other sites in the file are left untouched.
  mktmp >/dev/null
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

# --- password ---
# Prompts go to stderr so that anything capturing stdout still gets clean output.
ask() { printf '%s' "$1" >&2; IFS= read -r reply || die "could not read from stdin"; printf '\n' >&2; }

# 21 random base62 characters (~125 bits) behind a fixed class prefix, so the
# result is guaranteed to contain a lowercase, an uppercase and a digit. `head`
# closes the pipe early, so tr dies of SIGPIPE: the `|| true` keeps pipefail from
# turning that into a fatal error inside the command substitution.
generate_password() {
  printf '%s' "aA1$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 21 || true)"
}

# Hard rejections, applied to every source (prompt, --password, env var): a
# password on this list, or one equal to the login user, is a public secret.
password_blocked() {
  local pw="${1,,}" b
  [ "$pw" = "$SERVER_USER" ] && return 0
  for b in password 123456 admin opencode changeme letmein qwerty; do
    [ "$pw" = "$b" ] && return 0
  done
  return 1
}

# Soft warnings, never fatal: the user is told and allowed to proceed.
# The single-character-class cases are tested first so the message names the
# actual problem ("is all digits") instead of a symptom of it ("contains no
# lowercase letter").
password_weak_reason() {
  local pw="$1"
  if [ "${#pw}" -lt "$MIN_PASSWORD_LEN" ]; then printf 'shorter than %s characters' "$MIN_PASSWORD_LEN"; return 0; fi
  case "$pw" in *[!0-9]*) ;; *) printf 'is all digits'; return 0 ;; esac
  case "$pw" in *[!a-z]*) ;; *) printf 'is all lowercase letters'; return 0 ;; esac
  case "$pw" in *[!A-Z]*) ;; *) printf 'is all uppercase letters'; return 0 ;; esac
  case "$pw" in *[A-Za-z0-9]*) ;; *) printf 'uses only symbols'; return 0 ;; esac
  case "$pw" in *[a-z]*) ;; *) printf 'contains no lowercase letter'; return 0 ;; esac
  case "$pw" in *[A-Z]*) ;; *) printf 'contains no uppercase letter'; return 0 ;; esac
  case "$pw" in *[0-9]*) ;; *) printf 'contains no digit'; return 0 ;; esac
  return 1
}

# Reads the password twice with echo suppressed, so it never reaches the screen,
# the scrollback or the shell history file.
prompt_password() {
  local attempt=0 pw pw2 reason
  while [ "$attempt" -lt "$MAX_PROMPT_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    printf '%sEnter password for OpenCode (user: %s): %s' "$B" "$SERVER_USER" "$N" >&2
    IFS= read -r -s pw || die "could not read the password; aborting"
    printf '\n' >&2

    # An empty entry is not an error: offer to do the choosing instead.
    if [ -z "$pw" ]; then
      warn "no password entered."
      ask "Generate a strong random password instead? [Y/n] "
      case "${reply,,}" in
        ""|y|yes) PASSWORD="$(generate_password)"; PW_SOURCE="generated"
                 ok "generated password: $PASSWORD"; return 0 ;;
        *)        warn "password entry cancelled (attempt $attempt/$MAX_PROMPT_ATTEMPTS)"; continue ;;
      esac
    fi

    if password_blocked "$pw"; then
      err "that password is on the blocklist (or is the username). Choose something else."
      continue
    fi

    printf '%sConfirm password: %s' "$B" "$N" >&2
    IFS= read -r -s pw2 || die "could not read the confirmation; aborting"
    printf '\n' >&2
    if [ "$pw" != "$pw2" ]; then
      err "passwords do not match (attempt $attempt/$MAX_PROMPT_ATTEMPTS)"
      continue
    fi

    # Short or single-class passwords need a deliberate yes, not a default.
    if reason="$(password_weak_reason "$pw")"; then
      warn "weak password: it $reason."
      ask "Use it anyway? [y/N] "
      case "${reply,,}" in
        y|yes) : ;;
        *) warn "rejected (attempt $attempt/$MAX_PROMPT_ATTEMPTS)"; continue ;;
      esac
    fi

    PASSWORD="$pw"; PW_SOURCE="user"
    ok "password accepted (as configured by user)"
    return 0
  done
  die "no valid password after $MAX_PROMPT_ATTEMPTS attempts. Use --password or --generate-password for unattended runs."
}

# Called from main() before any system change, so a bad password cannot leave a
# half-configured host behind.
resolve_password() {
  case "$PW_MODE" in
    given)
      PW_SOURCE="user"
      password_blocked "$PASSWORD" \
        && die "the password given with --password is on the blocklist (or is the username '$SERVER_USER'). Choose a different one."
      return 0 ;;
    generate)
      PASSWORD="$(generate_password)"; PW_SOURCE="generated"
      ok "generated password: $PASSWORD"
      return 0 ;;
  esac

  # Auto. Only a real terminal gets a prompt: piped input and CI must never
  # block on stdin, and must never receive a password typed into a pipe.
  if [ -t 0 ]; then
    step "Setting the OpenCode password"
    prompt_password
    return 0
  fi
  ok "no password flags and no TTY: using the stored password, or generating one"
  return 0
}

# --- opencode unit ---
create_systemd_service() {
  step "Writing systemd user unit: $UNIT_PATH"
  mkdir -p "$UNIT_DIR" "$CONFIG_DIR"
  chmod 700 "$CONFIG_DIR"   # holds the password file

  # Reuse the stored password: OpenCode mints a random one per start otherwise,
  # so every crash-restart would silently invalidate the user's session.
  #
  # Precedence: an explicit --password/--generate-password or a TTY prompt, then
  # the stored value, then OPENCODE_PASSWORD, then a fresh random password.
  local stored=""
  if [ -f "$ENV_PATH" ]; then
    stored="$(sed -n 's/^OPENCODE_PASSWORD=//p' "$ENV_PATH" | head -1)"
    # An auto-generated value is deliberately never reused when the user asked
    # for a new one, so discard the stored one whenever we already have a choice.
    [ "$PW_SOURCE" = "user" ] && [ "$stored" = "$PASSWORD" ] && stored=""
    if [ "$PW_SOURCE" = "generated" ] && [ -n "$stored" ]; then
      warn "replacing the stored password with the newly generated one"
    fi
  fi

  if [ -z "$PASSWORD" ]; then
    if [ -n "$stored" ]; then
      PASSWORD="$stored"; PW_SOURCE="reused"
      ok "reusing the stored password (unchanged: live sessions stay valid)"
    elif [ -n "${OPENCODE_PASSWORD:-}" ]; then
      PASSWORD="$OPENCODE_PASSWORD"; PW_SOURCE="user"
      ok "using OPENCODE_PASSWORD from the environment (as configured by user)"
    else
      PASSWORD="$(generate_password)"; PW_SOURCE="generated"
    fi
  fi
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

# --- pm (Project Manager) ---------------------------------------------------
# pm is a separate, already-tested installer living next to this one. We call it
# rather than inlining it: two focused scripts beat one that does everything, and
# install-pm.sh stays runnable on its own.
PM_SCRIPT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/install-pm.sh"
PM_UNIT="pmd.service"
PM_TOKEN_FILE="/etc/pm/token"
PM_MCP_CONF="${HOME}/.config/opencode/opencode.json"

pm_installed() { as_root systemctl cat "$PM_UNIT" >/dev/null 2>&1; }

pm_health() {
  local t
  t="$(as_root cat "$PM_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ -n "$t" ] || return 1
  curl -fsS --max-time 5 -H "Authorization: Bearer $t" http://127.0.0.1:8300/health
}

# OpenCode2 needs a restart to pick up a changed MCP config, and the MCP server
# only counts as wired once its own status endpoint says "connected".
pm_mcp_connected() {
  local pw body
  pw="$(sed -n 's/^OPENCODE_PASSWORD=//p' "$ENV_PATH" 2>/dev/null | head -1)"
  [ -n "$pw" ] || return 1
  body="$(curl -fsS --max-time 8 -u "${SERVER_USER}:${pw}" \
    "http://127.0.0.1:${PORT}/api/mcp" 2>/dev/null)" || return 1
  # -r is required: without it jq prints the string WITH quotes ("connected"),
  # which never matches `grep -x connected` and reports a false negative.
  printf '%s' "$body" | jq -r '.data[] | select(.name=="pm") | .status.status' 2>/dev/null \
    | grep -qx connected
}


# Decide whether pm should be installed, honouring the flags and never prompting
# twice.
pm_should_install() {
  case "$WITH_PM" in
    no)  return 1 ;;
    yes) return 0 ;;
  esac
  if pm_installed; then
    step "Project Manager already installed — verifying instead of reinstalling"
    return 0
  fi
  # No TTY (CI, piped): default to installing, so the platform is complete.
  if [ ! -t 0 ]; then
    warn "no TTY; installing pm without prompting"
    return 0
  fi
  local reply
  printf 'Install Project Manager (pm) too, so the agent can create sites on\n'
  printf 'subdomains of %s with HTTPS? [Y/n] ' "$PM_PARENT" >&2
  IFS= read -r reply || reply="y"
  case "$(printf '%s' "$reply" | tr '[:upper:]' '[:lower:]')" in
    ""|y|yes) return 0 ;;
    *) step "Skipping pm; re-run with --with-pm to add it later"; return 1 ;;
  esac
}

install_pm() {
  [ -x "$PM_SCRIPT" ] || die "install-pm.sh not found next to this script ($PM_SCRIPT)"
  # pm's wildcard must be the PARENT, not --domain. Asking for the parent here is
  # what stops a mismatch between the DNS record the operator set and the one we
  # verify; --pm-parent overrides when the parent is not the last two labels.
  step "Installing Project Manager (pm) for parent domain $PM_PARENT"
  # pm touches /etc, /opt, /srv and the Caddy gate, so it must run as root. Its
  # own smoke test is redundant here: verify_pm() runs a combined one afterwards.
  local -a pm_args=(--domain "$PM_PARENT" --parent "$PM_PARENT")
  [ "$SKIP_DNS" -eq 1 ] && pm_args+=(--skip-dns-check)
  [ "$PM_SKIP_SMOKE" -eq 1 ] && pm_args+=(--skip-smoke)
  # pmd becomes the single on_demand_tls authorization gate. The OpenCode site
  # itself is not a pm project, so without this Caddy would refuse its
  # certificate and https://$DOMAIN would fail after pm takes over.
  pm_args+=(--allow-domain "$DOMAIN")
  if ! as_root bash "$PM_SCRIPT" "${pm_args[@]}"; then
    die "pm installation failed (see the output above).
    OpenCode 2 is installed and working; pm was not added. Fix the cause above
    and re-run this same command to retry just pm."
  fi
  PM_INSTALLED=1
  ok "pm installed and started"
}

# Restart OpenCode2 and wait for it to report pm connected.
restart_opencode_for_mcp() {
  step "Restarting OpenCode 2 to load the pm MCP server"
  systemctl --user restart "$UNIT_NAME" >/dev/null 2>&1 \
    || die "could not restart $UNIT_NAME after adding the pm MCP server"
  local i state="starting"
  for ((i = 1; i <= 30; i++)); do
    state="$(unit_state)"
    [ "$state" = "active" ] && break
    sleep 1
  done
  [ "$state" = "active" ] || die "$UNIT_NAME did not return to active after restart (state=$state)"
  ok "$UNIT_NAME active again"

  # systemd reports "active" as soon as the process is up, but the HTTP API the
  # MCP status lives behind needs a moment longer. Polling /api/mcp before the
  # port is listening just burns the budget on connection failures and reports a
  # false negative, so wait for the backend first.
  local bcode
  bcode="$(wait_backend)"
  case "$bcode" in
    2*|3*|401) ok "backend serving again: HTTP $bcode" ;;
    *) die "backend did not come back after the pm MCP restart (got '${bcode:-none}')" ;;
  esac

  for ((i = 1; i <= 45; i++)); do
    if pm_mcp_connected; then
      ok "OpenCode 2 reports the pm MCP server connected"
      return 0
    fi
    sleep 1
  done
  # A concrete reason beats "it didn't work": name both plausible causes.
  die "OpenCode 2 did not report the pm MCP server as connected after 20s.
    Config written: $(jq -c '.mcp.pm' "$PM_MCP_CONF" 2>/dev/null || echo MISSING)
    Check: journalctl --user -u $UNIT_NAME -n 40 --no-pager | grep -i mcp"
}

# Combined smoke test: oc2d reachable, pmd healthy, MCP registered, and a real
# project created over HTTPS through pm and then removed.
verify_pm() {
  step "Verifying the combined stack"
  FAILS=0; WARNS=0; PASSES=0

  if [ "$(as_root systemctl is-active "$PM_UNIT" 2>/dev/null || true)" = "active" ]; then
    ok "$PM_UNIT is active (running)"; good
  else bad "$PM_UNIT is '$(as_root systemctl is-active "$PM_UNIT" 2>/dev/null || echo inactive)'"; fi

  if as_root systemctl is-enabled "$PM_UNIT" 2>/dev/null | grep -q enabled; then
    ok "$PM_UNIT is enabled at boot"; good
  else bad "$PM_UNIT is not enabled; it would not come back after a reboot"; fi

  local health
  if health="$(pm_health)"; then
    ok "pm daemon healthy: $(printf '%s' "$health" | tr -d '\n')"; good
  else bad "pm daemon did not answer /health on 127.0.0.1:8300"; fi

  if jq -e '.mcp.pm.command | length > 0' "$PM_MCP_CONF" >/dev/null 2>&1; then
    ok "pm MCP entry present in $PM_MCP_CONF"; good
  else bad "pm MCP entry missing from $PM_MCP_CONF"; fi

  if pm_mcp_connected; then
    ok "OpenCode 2 has pm MCP connected"; good
  else bad "OpenCode 2 does not report pm MCP connected"; fi

  # pmd is the whole TLS gate now: if it does not authorize the OpenCode domain,
  # Caddy silently stops issuing for it and the platform URL breaks. Check the
  # gate directly, because the symptom (a TLS warning during verification) is
  # easy to misread as slow provisioning.
  local gate
  gate="$(curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:8300/internal/check-domain?domain=${DOMAIN}" 2>/dev/null || echo 000)"
  if [ "$gate" = "200" ]; then
    ok "TLS gate authorizes $DOMAIN (pmd owns on_demand_tls)"; good
  else
    bad "the TLS gate refuses $DOMAIN (HTTP $gate).
    pmd is Caddy's authorization gate, so Caddy will not issue a certificate
    for $DOMAIN and the platform URL will not load over HTTPS.
    Fix: add --allow-domain $DOMAIN to the pm install, then re-run:
      sudo bash $PM_SCRIPT --domain $PM_PARENT --parent $PM_PARENT --allow-domain $DOMAIN
      sudo systemctl restart $PM_UNIT"
  fi

  # Functional: create a real project, wait for HTTPS, then delete it. This is
  # the only check that proves the whole chain — DNS, Caddy gate, cert issuance,
  # systemd, route injection — works end to end.
  local tok sub="smoke.$PM_PARENT" out
  tok="$(as_root cat "$PM_TOKEN_FILE" 2>/dev/null | tr -d '[:space:]')"
  if [ -z "$tok" ]; then
    bad "no pm token at $PM_TOKEN_FILE"
    audit_report
    return 1
  fi

  # Clear any leftover from an interrupted run so the name is free.
  curl -fsS --max-time 15 -X DELETE "http://127.0.0.1:8300/projects/smoke?purge=1" \
    -H "Authorization: Bearer $tok" >/dev/null 2>&1 || true

  step "Combined smoke test: creating '$sub'"
  out="$(curl -fsS --max-time 180 -X POST http://127.0.0.1:8300/projects \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"name\":\"smoke\",\"subdomain\":\"$sub\"}" 2>&1)" || true

  if printf '%s' "$out" | jq -e '.httpsReady == true' >/dev/null 2>&1; then
    ok "https://$sub served with a valid certificate"; good
    printf '%s\n' "$out" | jq -r '.port' | while read -r p; do
      [ -n "$p" ] && printf '       (loopback 127.0.0.1:%s)\n' "$p"
    done
  else
    bad "could not create a project at https://$sub
    $(printf '%s' "$out" | jq -r '.error // .' 2>/dev/null || printf '%s' "$out")
    Check: journalctl -u $PM_UNIT -n 40 --no-pager"
    curl -fsS --max-time 15 -X DELETE "http://127.0.0.1:8300/projects/smoke?purge=1" \
      -H "Authorization: Bearer $tok" >/dev/null 2>&1 || true
    audit_report
    return 1
  fi

  step "Combined smoke test: removing the test project"
  if curl -fsS --max-time 20 -X DELETE "http://127.0.0.1:8300/projects/smoke?purge=1" \
       -H "Authorization: Bearer $tok" >/dev/null 2>&1; then
    ok "test project removed (unit, files, state entry and Caddy route)"
    good
  else
    bad "could not delete the smoke project"
  fi

  # oc2d regression: the platform itself must be untouched by all of the above.
  local c; c="$(http_code "https://${DOMAIN}/")"
  case "$c" in
    2*|3*|401) ok "OpenCode 2 still serving after pm's changes: HTTP $c"; good ;;
    000|"")   bad "https://$DOMAIN stopped responding after pm's changes" ;;
    *)         soft "https://$DOMAIN returned HTTP $c" ;;
  esac

  audit_report
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

FAILS=0; WARNS=0; PASSES=0
bad()  { warn "[FAIL] $*"; FAILS=$((FAILS+1)); }
soft() { warn "[WARN] $*"; WARNS=$((WARNS+1)); }
good() { PASSES=$((PASSES+1)); }

# On-demand TLS provisions a certificate lazily, on the first request, so a
# single-shot probe races the ACME issuance and reports a false failure. Kick the
# HTTP-01 challenge off with a :80 request, then poll HTTPS until it settles.
HTTPS_ATTEMPTS=24
wait_https() {
  local c err i
  curl -s -o /dev/null --max-time 10 "http://${DOMAIN}/" >/dev/null 2>&1 || true
  for ((i = 1; i <= HTTPS_ATTEMPTS; i++)); do
    err="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/" 2>&1 >/dev/null || true)"
    c="$(http_code "https://${DOMAIN}/")"
    case "$c" in
      200|301|302|401|403) printf '%s' "$c"; return 0 ;;
    esac
    case "$c" in
      5*) [ "$i" -ge 3 ] && warn "  https://$DOMAIN returned HTTP $c (attempt $i/$HTTPS_ATTEMPTS); still retrying" ;;
      000|"") printf '[wait] HTTPS not ready yet (attempt %s/%s)...\n' "$i" "$HTTPS_ATTEMPTS" >&2 ;;
    esac
    [ "$i" -lt "$HTTPS_ATTEMPTS" ] && sleep 5
  done
  # Classify: turn curl's exit text into an actionable cause.
  case "${err:-}" in
    *"Could not resolve host"*|*"resolve"*) printf 'DNS' ;;
    *"Connection refused"*|*"timed out"*|*"Failed to connect"*) printf 'TCP' ;;
    *"SSL"*|*"tls"*|*"TLS"*|*"certificate"*) printf 'TLS' ;;
    *) printf '%s' "${c:-000}" ;;
  esac
  return 1
}

# Same lazy-provisioning problem as wait_https; poll the certificate too.
wait_cert() {
  local f i
  for ((i = 1; i <= HTTPS_ATTEMPTS; i++)); do
    f="$(cert_field "$1")"
    [ -n "$f" ] && { printf '%s' "$f"; return 0; }
    sleep 5
  done
  return 1
}

verify_installation() {
  step "Verifying installation"
  FAILS=0; WARNS=0; PASSES=0

  # 1. OpenCode unit (fatal)
  if [ "$(unit_state)" = "active" ]; then ok "opencode.service is active (running)"; good
  else bad "opencode.service is '$(unit_state)'"; fi

  # 2. Backend on loopback (fatal)
  local code; code="$(wait_backend)"
  case "$code" in 2*|3*|401) ok "backend responded: HTTP $code on 127.0.0.1:$PORT"; good ;;
    *) bad "no usable HTTP response from 127.0.0.1:$PORT (got '${code:-none}')" ;; esac

  # 3. Caddy unit (fatal)
  if as_root systemctl is-active --quiet caddy; then ok "caddy is active (running)"; good
  else bad "caddy is not active"; fi

  # 4. HTTPS (NON-FATAL: with on-demand TLS the cert is issued lazily, so a
  #    not-yet-provisioned name is a transient state, not a broken install.)
  local https_code=""
  if https_code="$(wait_https)"; then
    ok "HTTPS endpoint responded: HTTP $https_code via https://$DOMAIN"; good
  else
    soft "HTTPS not yet ready for $DOMAIN (last result: ${https_code:-none}).
    With on-demand TLS the certificate is issued on first use; if this persists,
    Caddy is refusing to issue it. That is usually an authorization policy, not
    a timing problem.
    Check status: curl -I https://$DOMAIN/
    Tail Caddy:   journalctl -u caddy -f"
  fi

  # 5. Certificate (NON-FATAL for the same reason)
  local notafter issuer
  if notafter="$(wait_cert -enddate)"; then
    ok "TLS certificate valid until $notafter"; good
    issuer="$(cert_field -issuer)"
    case "$issuer" in
      *"Let's Encrypt"*|*ZeroSSL*) ok "certificate issuer: $issuer"; good ;;
      *) soft "certificate is not from a public CA (issuer: ${issuer:-unknown})" ;;
    esac
  else
    soft "Certificate not yet issued for $DOMAIN. This is normal with on-demand TLS;
    it will be provisioned on the next request."
  fi

  # 5b. Boot enablement (fatal: the stack must come back after a reboot)
  if [ "$(systemctl --user is-enabled "$UNIT_NAME" 2>/dev/null || true)" = "enabled" ]; then
    ok "opencode.service is enabled at boot"; good
  else bad "opencode.service is not enabled; it would not come back after a reboot"; fi
  if as_root systemctl is-enabled caddy 2>/dev/null | grep -q enabled; then
    ok "caddy is enabled at boot"; good
  else bad "caddy is not enabled; it would not come back after a reboot"; fi
  if loginctl show-user "$RUN_USER" 2>/dev/null | grep -q '^Linger=yes'; then
    ok "linger is enabled for $RUN_USER"; good
  else bad "linger is not enabled; opencode.service stops at logout and misses boot"; fi

  # 5c. Backend must not be reachable from outside the host (fatal: exposure)
  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*|\[::\]):${PORT}\$"; then
    bad "backend is bound to a public address; it must listen on 127.0.0.1 only"
  else ok "backend is bound to loopback only"; good; fi

  # 6. Reboot simulation. Source of truth is the backend on loopback: HTTPS may
  # still be mid-provisioning, which says nothing about reboot resilience.
  step "Reboot simulation: restarting both services"
  systemctl --user restart "$UNIT_NAME" || bad "opencode restart command failed"
  as_root systemctl restart caddy >/dev/null 2>&1 || bad "caddy restart command failed"
  sleep 10
  if [ "$(unit_state)" = "active" ]; then ok "opencode.service active again"; good
  else bad "opencode.service down after restart"; fi
  if as_root systemctl is-active --quiet caddy; then ok "caddy active again"; good
  else bad "caddy down after restart"; fi
  code="$(wait_backend)"
  case "$code" in 2*|3*|401) ok "backend responding after restart: HTTP $code"; good ;;
    *) bad "backend down after restart (got '${code:-none}')" ;; esac
  # HTTPS after a restart is informational only: with on-demand TLS the cert may
  # still be provisioning, and that says nothing about reboot resilience. A single
  # fast probe here -- the full retry budget already ran above.
  https_code="$(http_code "https://${DOMAIN}/")"
  case "$https_code" in
    200|301|302|401|403) ok "HTTPS responding after restart: HTTP $https_code"; good ;;
    *) soft "HTTPS not ready after restart for $DOMAIN (got '${https_code:-none}'); provisioning may still be in progress" ;;
  esac

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
      ok "[OK] crash recovery: auto-restarted as pid $after"; good
    else
      bad "crash recovery: not auto-restarted (state=$(unit_state) pid=${after:-none})"
    fi
  else
    soft "crash recovery skipped: could not confirm our MainPID owns port $PORT"
  fi

  # Production safety: every pre-existing site must still answer. Wildcard blocks
  # (*.example.com) are skipped: a wildcard is not a resolvable hostname, so
  # probing it would always report a false "DOWN". Retried, so a lazily-provisioned
  # on-demand cert is not mistaken for damage we caused.
  local s
  for s in $PRISTINE_SITES; do
    case "$s" in
      '*'*) ok "[OK] wildcard block preserved (not directly probeable): $s"; good; continue ;;
    esac
    local c="" i
    for ((i = 1; i <= 6; i++)); do
      c="$(http_code "https://${s}/")"
      case "$c" in 000|"") sleep 5 ;; *) break ;; esac
    done
    case "$c" in
      2*|3*) ok "[OK] pre-existing site unaffected: $s (HTTP $c)"; good ;;
      000|"") bad "pre-existing site is DOWN after our change: $s" ;;
      *) soft "pre-existing site $s returned HTTP $c" ;; esac
  done

  # Idempotency evidence: exactly one block, exactly one unit.
  local blocks
  blocks="$(grep -c "^${DOMAIN} {" "$CADDYFILE" 2>/dev/null || echo 0)"
  if [ "$blocks" = "1" ]; then ok "[OK] exactly one Caddy block for $DOMAIN"; good
  else bad "found $blocks Caddy blocks for $DOMAIN; expected 1"; fi
  if [ "$(systemctl --user list-unit-files 2>/dev/null | grep -c "^${UNIT_NAME}\b" || true)" = "1" ]; then
    ok "[OK] exactly one opencode unit file"; good
  else bad "expected exactly one $UNIT_NAME unit file"; fi

  printf '%s[OK] Stability audit complete%s\n' "$G" "$N"
}

# Tally. Only fatal failures abort; warnings (typically a lazily-provisioned
# on-demand certificate) are reported and the install still succeeds.
audit_report() {
  printf '\n'
  ok "[OK] $PASSES checks passed"
  [ "$WARNS" -gt 0 ] && printf '%s[WARN]%s %s checks warn (see above)\n' "$Y" "$N" "$WARNS"
  [ "$WARNS" -eq 0 ] && ok "0 checks warn"
  if [ "$FAILS" -ne 0 ]; then
    printf '\n%s--- opencode.service (last 20) ---%s\n' "$Y" "$N" >&2
    journalctl --user -u "$UNIT_NAME" -n 20 --no-pager >&2 || true
    printf '%s--- caddy.service (last 20) ---%s\n' "$Y" "$N" >&2
    as_root journalctl -u caddy -n 20 --no-pager >&2 || true
    printf '%s[FAIL]%s %s checks failed (fatal)\n' "$R" "$N" "$FAILS" >&2
    die "$FAILS fatal check(s) failed; the stack is NOT healthy"
  fi
  ok "[OK] 0 checks failed (fatal)"
  # Harmless, pre-existing noise from another site's block; do not "fix" it.
  if as_root journalctl -u caddy -n 200 --no-pager 2>/dev/null | grep -q 'Unnecessary header_up'; then
    warn "Caddy logs contain 'Unnecessary header_up' warnings from a pre-existing
    site block. They are harmless and were left untouched."
  fi
  ok "[OK] Reboot resilience verified (backend on 127.0.0.1:$PORT is the source of truth)"
}

print_summary() {
  local pid issuer notafter
  pid="$(systemctl --user show "$UNIT_NAME" -p MainPID --value 2>/dev/null || echo '?')"
  issuer="$(cert_field -issuer)"
  notafter="$(cert_field -enddate)"

  # pm block: state reflects what actually happened, so the summary can never
  # claim a capability the machine does not have.
  local pm_state="not installed" pm_line="" parent_line=""
  if [ "$PM_INSTALLED" -eq 1 ]; then
    pm_state="$(as_root systemctl is-active "$PM_UNIT" 2>/dev/null || echo unknown)"
    if pm_mcp_connected; then
      pm_line="pm_create, pm_list, pm_status, pm_start, pm_stop,
                  pm_restart, pm_delete, pm_logs"
    else
      pm_line="configured but not connected — check: journalctl --user -u $UNIT_NAME | grep -i mcp"
    fi
    parent_line="$PM_PARENT   (wildcard *.$PM_PARENT)"
  fi

  # A password is echoed back only when this run generated it. Anything the
  # operator chose, or a value reused from a previous install, is reported as
  # "as configured by user" so a re-run never reprints a live secret.
  local pw_line
  case "$PW_SOURCE" in
    generated) pw_line="$PASSWORD" ;;
    *)         pw_line="(as configured by user)" ;;
  esac

  cat <<EOF

========================================
 Vibecoding Platform — Installed
========================================
 OpenCode 2:     $(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || echo unknown)  (pid $pid)
 URL:            https://$DOMAIN
 Login:          $SERVER_USER / $pw_line
 Backend:        http://127.0.0.1:$PORT  (loopback only)
 Certificate:    ${issuer:-issuer unknown}
                 valid until ${notafter:-unknown}
 Caddy:          $(as_root systemctl is-active caddy 2>/dev/null || echo unknown)
 PM daemon:      $pm_state
 MCP tools:      $pm_line
 Parent domain:  $parent_line

 Logs (OpenCode): journalctl --user -u $UNIT_NAME -f
 Logs (PM):       journalctl -u $PM_UNIT -f
 Logs (Caddy):    journalctl -u caddy -f
========================================

Open https://$DOMAIN in a browser, log in as "$SERVER_USER", and chat with the
agent. Try:

  "Create a project called blog at blog.$PM_PARENT"
  "List all my projects"
  "Stop the blog project"
  "Delete the demo project and clean up its files"

Certificates are automatic (Caddy renews ~30 days before expiry).
Change the password later with: ./change-password.sh
Remove with:  bash install-opencode.sh --uninstall [--purge]
Remove both:  bash install-opencode.sh --uninstall --with-pm [--purge]
EOF
}

uninstall_pm() {
  [ -f "$PM_SCRIPT" ] || { warn "install-pm.sh not found; remove pm manually"; return 0; }
  step "Removing Project Manager (pm)"
  # pm restores its own Caddy ask endpoint, drops the MCP entry and stops every
  # project unit, so this is safe to run even when pm was never installed here.
  local -a args=(--uninstall)
  [ "$PURGE" -eq 1 ] && args+=(--purge)
  [ -n "$PM_PARENT" ] && args+=(--parent "$PM_PARENT")
  if as_root bash "$PM_SCRIPT" "${args[@]}"; then
    ok "pm removed"
  else
    warn "pm uninstall reported errors; check 'systemctl status $PM_UNIT'"
  fi
}

uninstall() {
  # pm first: it restores the Caddy ask endpoint, so OpenCode's block stays
  # consistent with whatever we hand control back to.
  if [ "$WITH_PM" = "yes" ] || pm_installed; then uninstall_pm; fi

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
    mktmp >/dev/null
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

  # Before any system change: a rejected password must not leave a host that is
  # half-configured.
  resolve_password

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

  # pm comes after OpenCode is healthy: its MCP entry lands in OpenCode's config,
  # and the combined verification needs both halves up.
  if pm_should_install; then
    install_pm
    restart_opencode_for_mcp
    verify_pm
  else
    PM_INSTALLED=0
  fi

  print_summary
}

main "$@"