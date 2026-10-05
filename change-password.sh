#!/usr/bin/env bash
#
# change-password.sh - change the OpenCode password of an existing oc2d install.
#
# The password lives in ~/.config/opencode/env, which the unit feeds to the
# server through EnvironmentFile. Changing it therefore means stopping the
# service, rewriting that one line, and starting it again. Every step is guarded:
# if the service does not come back, the previous file is restored and the old
# password works again, so a failed change never locks you out.
#
#   ./change-password.sh                    # prompt (hidden input)
#   ./change-password.sh --password 'pw'    # non-interactive
#   ./change-password.sh --generate         # new random password, printed once
#
set -euo pipefail

# --- paths and constants ---
CONFIG_DIR="${HOME}/.config/opencode"
ENV_PATH="${CONFIG_DIR}/env"
UNIT_NAME="opencode.service"
UNIT_PATH="${HOME}/.config/systemd/user/${UNIT_NAME}"
SERVER_USER="opencode"
CADDYFILE="/etc/caddy/Caddyfile"
MIN_PASSWORD_LEN=12
MAX_PROMPT_ATTEMPTS=3
STOP_WAIT=10           # seconds to wait for the service to actually stop
START_WAIT=10          # seconds to wait for it to come back
PORT=""                # read from the unit's ExecStart

PW_MODE="auto"         # auto | given | generate
PASSWORD=""
PW_SOURCE=""           # user | generated
BACKUP=""              # copy of the pre-change env file, for rollback
CHANGED=0              # set once the file is rewritten; drives the trap

# --- output ---
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'
else B=""; G=""; Y=""; R=""; N=""; fi
step() { printf '%s==>%s %s\n' "$B" "$N" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%swarn%s %s\n' "$Y" "$N" "$*" >&2; }
err()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; }   # not fatal on its own
die()  { printf '%serror%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Change the OpenCode password of an existing oc2d installation.

  change-password.sh [options]

  --password <pw>    Use this password (skips the prompt)
  --generate         Generate a strong random password and print it once
  -h, --help         This message

With no flag, you are prompted with hidden input and asked to confirm. Strong
passwords are recommended: 12+ characters mixing cases and digits. Blocklisted
values (password, 123456, admin, opencode, changeme, letmein, qwerty) and the
username itself are rejected.

The service is stopped, the password is rewritten, and the service is started
again. If it fails to come back, the previous password is restored automatically.

The password is never echoed: a password you type is not printed back, and a
generated one is printed exactly once. It is stored 0600 in
$ENV_PATH and never written to shell history.
EOF
}

# --- rollback ---
# Anything that exits after the file was rewritten but before the service was
# confirmed healthy puts the old file back and restarts with the old password.
# The trap returns 0 so it cannot replace the script's real exit status.
cleanup() {
  if [ "$CHANGED" -eq 1 ] && [ -n "$BACKUP" ] && [ -f "$BACKUP" ]; then
    err "the change did not complete; restoring the previous password"
    if cat "$BACKUP" > "$ENV_PATH" 2>/dev/null; then
      chmod 600 "$ENV_PATH" 2>/dev/null || true
      # `systemctl start` returns 0 as soon as the unit is *starting*, so its
      # exit status says nothing about whether the service really came back (a
      # bad ExecStart fails a moment later). Poll the unit, then the backend.
      systemctl --user start "$UNIT_NAME" >/dev/null 2>&1 || true
      if wait_active "$START_WAIT" && backend_answers "$START_WAIT"; then
        err "previous password restored and $UNIT_NAME restarted with it"
      else
        err "previous password restored, but $UNIT_NAME did NOT come back."
        err "Fix the unit, then run: systemctl --user start $UNIT_NAME"
      fi
    else
      err "could not restore $BACKUP. Restore it by hand, then run: systemctl --user start $UNIT_NAME"
    fi
  fi
  [ -n "$BACKUP" ] && rm -f "$BACKUP"
  return 0
}
trap cleanup EXIT

# --- password helpers (same rules as install-opencode.sh) ---
# Prompts go to stderr so anything capturing stdout still gets clean output.
ask() { printf '%s' "$1" >&2; IFS= read -r reply || die "could not read from stdin"; printf '\n' >&2; }

# 21 random base62 characters (~125 bits) behind a fixed class prefix, so the
# result always contains a lowercase, an uppercase and a digit. `head` closes the
# pipe early, so tr dies of SIGPIPE: the `|| true` keeps pipefail from turning
# that into a fatal error inside the command substitution.
generate_password() {
  printf '%s' "aA1$(LC_ALL=C tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 21 || true)"
}

# Hard rejections: a password on this list, or one equal to the login user, is
# a public secret.
password_blocked() {
  local pw="${1,,}" b
  [ "$pw" = "$SERVER_USER" ] && return 0
  for b in password 123456 admin opencode changeme letmein qwerty; do
    [ "$pw" = "$b" ] && return 0
  done
  return 1
}

# Soft warnings, never fatal. The character-class cases come first so the
# message names the real problem ("all digits") instead of a symptom of it.
password_weak_reason() {
  local pw="$1"
  if [ "${#pw}" -lt "$MIN_PASSWORD_LEN" ]; then printf 'shorter than %s characters' "$MIN_PASSWORD_LEN"; return 0; fi
  case "$pw" in *[!0-9]*) ;; *) printf 'is all digits'; return 0 ;; esac
  case "$pw" in *[!a-z]*) ;; *) printf 'is all lowercase letters'; return 0 ;; esac
  case "$pw" in *[!A-Z]*) ;; *) printf 'is all uppercase letters'; return 0 ;; esac
  case "$pw" in *[!A-Za-z0-9]*) ;; *) printf 'uses only symbols'; return 0 ;; esac
  case "$pw" in *[a-z]*) ;; *) printf 'contains no lowercase letter'; return 0 ;; esac
  case "$pw" in *[A-Z]*) ;; *) printf 'contains no uppercase letter'; return 0 ;; esac
  case "$pw" in *[0-9]*) ;; *) printf 'contains no digit'; return 0 ;; esac
  return 1
}

# Verified against systemd 255: EnvironmentFile keeps spaces, '#' and quotes
# verbatim, but consumes a backslash as an escape and trims leading/trailing
# whitespace. A password containing those would be stored but never match what
# the server actually receives, so say so instead of failing at login time.
warn_if_env_unroundtrippable() {
  local pw="$1"
  case "$pw" in
    *\\*) warn "this password contains a backslash. systemd's EnvironmentFile treats
    a backslash as an escape, so the server will not receive it exactly as typed.
    Prefer a password without backslashes." ; return 0 ;;
  esac
  case "$pw" in
    " "*|*" ") warn "this password starts or ends with a space, which systemd strips
    from an EnvironmentFile value. Prefer a password without edge spaces." ; return 0 ;;
  esac
  return 0
}

prompt_password() {
  local attempt=0 pw pw2 reason
  while [ "$attempt" -lt "$MAX_PROMPT_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    printf '%sEnter new password for OpenCode (user: %s): %s' "$B" "$SERVER_USER" "$N" >&2
    IFS= read -r -s pw || die "could not read the password; aborting"
    printf '\n' >&2

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

    printf '%sConfirm new password: %s' "$B" "$N" >&2
    IFS= read -r -s pw2 || die "could not read the confirmation; aborting"
    printf '\n' >&2
    if [ "$pw" != "$pw2" ]; then
      err "passwords do not match (attempt $attempt/$MAX_PROMPT_ATTEMPTS)"
      continue
    fi

    if reason="$(password_weak_reason "$pw")"; then
      warn "weak password: it $reason."
      ask "Use it anyway? [y/N] "
      case "${reply,,}" in
        y|yes) : ;;
        *) warn "rejected (attempt $attempt/$MAX_PROMPT_ATTEMPTS)"; continue ;;
      esac
    fi

    PASSWORD="$pw"; PW_SOURCE="user"
    ok "new password accepted (as configured by user)"
    return 0
  done
  die "no valid password after $MAX_PROMPT_ATTEMPTS attempts. Use --password or --generate for unattended runs."
}

# --- args ---
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --password)
        [ $# -ge 2 ] || die "--password needs a value"
        [ -n "$2" ] || die "--password needs a non-empty value"
        PASSWORD="$2"; PW_MODE="given"; shift 2 ;;
      --generate) PW_MODE="generate"; shift ;;
      -h|--help)  usage; exit 0 ;;
      *)          die "unknown option: $1 (try --help)" ;;
    esac
  done
}

# --- environment ---
# Refuse to touch anything unless this really is an oc2d install.
check_installed() {
  step "Checking the existing installation"
  local env_ok=0 unit_ok=0 units=""

  if [ -f "$ENV_PATH" ]; then env_ok=1
  else err "missing $ENV_PATH"; fi

  # Query into a variable instead of piping into grep: under `pipefail` a
  # transient systemctl failure would make the whole pipeline fail and report a
  # perfectly good install as "not installed".
  units="$(systemctl --user list-unit-files 2>/dev/null || true)"
  if printf '%s\n' "$units" | grep -q "^${UNIT_NAME}"; then unit_ok=1
  elif [ -z "$units" ]; then
    die "could not query systemd (systemctl --user is unavailable). Is the user manager running?"
  else
    err "missing $UNIT_NAME"
  fi

  if [ "$env_ok" -eq 0 ] || [ "$unit_ok" -eq 0 ]; then
    die "oc2d is not installed. Run install-opencode.sh first."
  fi
  ok "found $ENV_PATH and $UNIT_NAME"

  PORT="$(sed -n 's/.*--port \([0-9]\{1,\}\).*/\1/p' "$UNIT_PATH" 2>/dev/null | head -1 || true)"
  if [ -n "$PORT" ]; then ok "backend port from the unit: $PORT"
  else PORT=4096; warn "could not read the port from $UNIT_PATH; assuming $PORT"; fi
}

# The public URL, when the Caddyfile shows which site block proxies to our port.
# Purely cosmetic: the script works fine without it.
#
# Several blocks can share the port (a wildcard layout does), so probe the
# candidates and return the first one that actually answers. Returning the first
# match blindly would happily print a name whose certificate was never issued.
discover_domain() {
  [ -r "$CADDYFILE" ] || return 0
  local candidates site code
  candidates="$(awk -v port="127.0.0.1:${PORT}" '
    /^[^#[:space:]].*\{[[:space:]]*$/ { sub(/[[:space:]]*\{$/, ""); block=$0 }
    index($0, "reverse_proxy " port) > 0 { print block }
  ' "$CADDYFILE" 2>/dev/null || true)"
  [ -n "$candidates" ] || return 0

  while IFS= read -r site; do
    [ -n "$site" ] || continue
    case "$site" in *'*'*) continue ;;   # a wildcard is not a hostname
    esac
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${site}/" 2>/dev/null || true)"
    case "$code" in
      2*|3*|401) printf '%s' "$site"; return 0 ;;
    esac
  done <<< "$candidates"
  return 0
}

# The new password goes through a shell redirect, never through a command line,
# so it cannot show up in `ps` output while the file is rewritten.
write_env() {
  local tmp line found=0
  tmp="$(mktemp)"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "${line#OPENCODE_PASSWORD=}" != "$line" ]; then
      printf 'OPENCODE_PASSWORD=%s\n' "$PASSWORD" >> "$tmp"
      found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_PATH"
  [ "$found" -eq 1 ] || printf 'OPENCODE_PASSWORD=%s\n' "$PASSWORD" >> "$tmp"

  # `cat >` truncates in place, so the file keeps its inode and 0600 mode: no
  # window where the password sits in a world-readable file.
  cat "$tmp" > "$ENV_PATH"
  rm -f "$tmp"
  chmod 600 "$ENV_PATH"
  # The installer creates this directory 0700; enforce it here too, so a manually
  # loosened directory cannot expose the file we just wrote.
  chmod 700 "$CONFIG_DIR" 2>/dev/null || true
}

# "Stopped" cannot be spelled `is-active == inactive`: this unit sets
# Restart=always, so when systemd stops it the recorded result is `failed`, not
# `inactive`. Waiting for the literal word "inactive" would time out every time.
# Any state that is not running-or-on-the-way-to-running counts as stopped.
wait_stopped() {
  local state i
  for ((i = 1; i <= $1; i++)); do
    state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
    case "$state" in
      active|activating|reloading|deactivating) sleep 1 ;;
      *) return 0 ;;
    esac
  done
  return 1
}

wait_active() {
  local i
  for ((i = 1; i <= $1; i++)); do
    [ "$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)" = "active" ] && return 0
    sleep 1
  done
  return 1
}

# The backend answering on loopback is the real proof the server is up.
# `systemctl is-active` is not: with Type=simple systemd reports "active" as
# soon as the process is forked, so a doomed ExecStart (or one that dies on the
# next Restart=always tick) can read "active" for a moment and fool a poll.
backend_answers() {
  local code i
  for ((i = 1; i <= ${1:-5}; i++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    case "$code" in
      2*|3*|401) return 0 ;;
    esac
    sleep 1
  done
  return 1
}

apply_password() {
  # 1. Back up before touching anything, so rollback is always possible.
  BACKUP="$(mktemp)"
  cp -a "$ENV_PATH" "$BACKUP" || die "could not back up $ENV_PATH"
  chmod 600 "$BACKUP"
  ok "previous password backed up"

  # 2. Stop, and wait until it has really stopped. Starting again while the old
  #    process still holds the port is what produces a half-applied change.
  step "Stopping $UNIT_NAME"
  systemctl --user stop "$UNIT_NAME" || die "could not stop $UNIT_NAME (journalctl --user -u $UNIT_NAME -n 50)"
  wait_stopped "$STOP_WAIT" || die "$UNIT_NAME did not stop within ${STOP_WAIT}s; nothing was changed"
  ok "service stopped"

  # 3. Rewrite one line, preserving anything else in the file.
  write_env
  CHANGED=1
  ok "password written to $ENV_PATH (mode 600)"

  # 4. Start again and wait for it.
  step "Starting $UNIT_NAME"
  systemctl --user start "$UNIT_NAME" || die "$UNIT_NAME refused to start (journalctl --user -u $UNIT_NAME -n 50)"
  if ! wait_active "$START_WAIT"; then
    die "$UNIT_NAME did not become active within ${START_WAIT}s. The previous password has been restored."
  fi
  # Type=simple marks the unit active the moment systemd forks the process, so
  # this only proves the unit started; verify_change is what proves it works.
  ok "service reports active (now verifying it actually serves)"
}

verify_change() {
  step "Verifying"
  local state
  state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || true)"
  [ "$state" = "active" ] || die "$UNIT_NAME is '$state', not 'active'"
  ok "$UNIT_NAME is active (running)"

  backend_answers "$START_WAIT" \
    || die "the backend did not answer on 127.0.0.1:$PORT. The previous password has been restored."
  ok "backend answered on 127.0.0.1:$PORT"
}

print_summary() {
  local domain state
  domain="$(discover_domain)"
  state="$(systemctl --user is-active "$UNIT_NAME" 2>/dev/null || echo unknown)"

  # A typed password is never echoed back; only a generated one is shown.
  local pw_line
  case "$PW_SOURCE" in
    generated) pw_line="$PASSWORD" ;;
    *)         pw_line="as configured by user" ;;
  esac

  cat <<EOF
========================================
 OpenCode Password Changed Successfully
========================================
 Service:    $state (running)
 User:       $SERVER_USER
 Password:   $pw_line
 Login URL:  ${domain:-unknown (no matching Caddy block for port $PORT)}
========================================
Log out from any active browser session and log in with the new password.
EOF
}

main() {
  parse_args "$@"
  check_installed

  step "Selecting the new password"
  case "$PW_MODE" in
    given)
      PW_SOURCE="user"
      password_blocked "$PASSWORD" \
        && die "the password given with --password is on the blocklist (or is the username '$SERVER_USER'). Choose a different one."
      ok "using the password from --password (as configured by user)"
      ;;
    generate)
      PASSWORD="$(generate_password)"; PW_SOURCE="generated"
      ok "generated password: $PASSWORD"
      ;;
    *)
      # Only a real terminal gets a prompt, so CI and pipes never block on stdin.
      if [ -t 0 ]; then
        prompt_password
      else
        die "no password flags and no TTY. Use --password <pw> or --generate, or run this from a terminal."
      fi
      ;;
  esac
  warn_if_env_unroundtrippable "$PASSWORD"

  apply_password
  verify_change
  CHANGED=0          # confirmed healthy: the trap must not roll back
  print_summary
}

main "$@"