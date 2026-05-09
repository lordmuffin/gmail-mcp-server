#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# gmail-mcp-setup-v2.sh
#
# Configure navbuildz/gmail-mcp-server as a long-lived HTTPS service managed
# by `systemd --user`, supporting BOTH interactive 1Password CLI auth (workstation
# w/ desktop app integration) AND 1Password Service Accounts (headless / server).
#
# v2 changes vs v1:
#   - Uses `op whoami` instead of `op account list` for the auth gate.
#   - Detects mode: OP_SERVICE_ACCOUNT_TOKEN present → service-account mode.
#                   Otherwise → interactive / desktop-integration mode.
#   - Surfaces stderr from failed `op run` calls (no more silent rc=1).
#   - Optional: writes ~/.config/gmail-mcp/service-account.env (mode 600)
#     and references it from the systemd unit via EnvironmentFile=.
#     This is what makes the unit work without a logged-in desktop session.
#   - Passes `--env-file .env` to every `op run` invocation (probe + systemd)
#     so op picks up the op:// references reliably regardless of cwd autodetect.
#
# Usage:
#   ./gmail-mcp-setup-v2.sh [flags]
#
# Flags:
#   --dry-run                 Print actions without executing them.
#   --enable-linger           loginctl enable-linger (off by default).
#   --no-edit-config          Don't touch claude_desktop_config.json.
#   --skip-op-test            Skip the op auth probe entirely.
#   --restart-service         systemctl --user restart even if already up.
#   --service-account-file P  Path to a file containing a single line:
#                                OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxxxxxxxxx
#                             Will be installed at
#                             ~/.config/gmail-mcp/service-account.env (mode 600)
#                             and referenced from the systemd unit. If you
#                             already have it at that path, just pass the path.
#   --use-existing-sa-file    Don't copy/install a SA file; use whatever is
#                             at ~/.config/gmail-mcp/service-account.env.
# ---------------------------------------------------------------------------

set -euo pipefail

# ---------- Configuration ----------
: "${USER_NAME:=$(id -un)}"
: "${REPO_DIR:=${HOME}/git/gmail-mcp-server}"
: "${ENV_FILE:=${REPO_DIR}/.env}"
: "${CLAUDE_CONFIG:=${HOME}/.config/Claude/claude_desktop_config.json}"
: "${UNIT_FILE:=${HOME}/.config/systemd/user/gmail-mcp.service}"
: "${LOG_DIR:=${HOME}/.local/state}"
: "${LOG_FILE:=${LOG_DIR}/gmail-mcp.log}"
: "${SA_DIR:=${HOME}/.config/gmail-mcp}"
: "${SA_FILE:=${SA_DIR}/service-account.env}"
: "${SERVER_URL:=https://192.168.1.69:3000}"
: "${OP_BIN:=/usr/bin/op}"
: "${NODE_BIN:=/usr/bin/node}"
: "${REQUIRED_ENV_KEYS:=GOOGLE_CLIENT_ID GOOGLE_CLIENT_SECRET ENCRYPTION_KEY ADMIN_PASSWORD SERVER_URL PORT}"

# ---------- Flag parsing ----------
DRY_RUN=0
ENABLE_LINGER=0
EDIT_CONFIG=1
SKIP_OP_TEST=0
RESTART_SERVICE=0
SA_SOURCE_FILE=""
USE_EXISTING_SA=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)              DRY_RUN=1; shift ;;
    --enable-linger)        ENABLE_LINGER=1; shift ;;
    --no-edit-config)       EDIT_CONFIG=0; shift ;;
    --skip-op-test)         SKIP_OP_TEST=1; shift ;;
    --restart-service)      RESTART_SERVICE=1; shift ;;
    --service-account-file) SA_SOURCE_FILE="${2:-}"; shift 2 ;;
    --use-existing-sa-file) USE_EXISTING_SA=1; shift ;;
    -h|--help) sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "Unknown flag: $1" >&2; exit 2 ;;
  esac
done

# ---------- Output helpers ----------
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'
  C_BLUE=$'\033[34m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'
else
  C_RESET=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi
step() { echo "${C_BOLD}${C_BLUE}==>${C_RESET} ${C_BOLD}$*${C_RESET}"; }
ok()   { echo "    ${C_GREEN}✓${C_RESET} $*"; }
warn() { echo "    ${C_YELLOW}!${C_RESET} $*"; }
err()  { echo "    ${C_RED}✗${C_RESET} $*" >&2; }
run()  {
  if (( DRY_RUN )); then echo "    ${C_YELLOW}[dry-run]${C_RESET} $*"
  else                   eval "$@"
  fi
}
trap 'err "Aborted at line $LINENO. See messages above."' ERR

# ---------- 0. Pre-flight ----------
step "Pre-flight checks"
for cmd in jq curl systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || { err "Missing command: $cmd"; exit 1; }
done
ok "jq, curl, systemctl present"
[[ -x "$OP_BIN" ]]   || { err "op CLI not at $OP_BIN (set OP_BIN=...)"; exit 1; }
[[ -x "$NODE_BIN" ]] || { err "node not at $NODE_BIN (set NODE_BIN=...)"; exit 1; }
[[ -d "$REPO_DIR" ]] || { err "Repo dir missing: $REPO_DIR"; exit 1; }
[[ -f "$REPO_DIR/dist/index.js" ]] || warn "$REPO_DIR/dist/index.js missing — run 'npm run build'"
[[ -f "$ENV_FILE" ]] || { err "Missing $ENV_FILE (op run --env-file needs it)"; exit 1; }
ok "Binaries, repo, and .env verified"

# ---------- 1. Install service account file (if provided) ----------
SA_FILE_INSTALLED=0
if [[ -n "$SA_SOURCE_FILE" ]]; then
  step "Install service account file from $SA_SOURCE_FILE"
  [[ -f "$SA_SOURCE_FILE" ]] || { err "Source file not found: $SA_SOURCE_FILE"; exit 1; }
  if ! grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=ops_[A-Za-z0-9_-]+' "$SA_SOURCE_FILE"; then
    err "$SA_SOURCE_FILE doesn't contain a valid OP_SERVICE_ACCOUNT_TOKEN=ops_... line"
    exit 1
  fi
  run "mkdir -p '$SA_DIR' && chmod 700 '$SA_DIR'"
  run "install -m 600 '$SA_SOURCE_FILE' '$SA_FILE'"
  SA_FILE_INSTALLED=1
  ok "Installed at $SA_FILE (mode 600)"
elif (( USE_EXISTING_SA )); then
  step "Using existing service account file at $SA_FILE"
  [[ -f "$SA_FILE" ]] || { err "Expected $SA_FILE but not found"; exit 1; }
  perm=$(stat -c '%a' "$SA_FILE" 2>/dev/null || echo "")
  if [[ "$perm" != "600" ]]; then
    warn "$SA_FILE permissions are $perm (recommend 600)"
    run "chmod 600 '$SA_FILE'"
  fi
  SA_FILE_INSTALLED=1
  ok "Will reference $SA_FILE from systemd unit"
fi

# ---------- 2. Backup & edit Claude Desktop config ----------
if (( EDIT_CONFIG )); then
  step "Back up Claude Desktop config"
  if [[ -f "$CLAUDE_CONFIG" ]]; then
    BACKUP="${CLAUDE_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    run "cp -p '$CLAUDE_CONFIG' '$BACKUP'"
    ok "Backed up → $BACKUP"
  else
    warn "No $CLAUDE_CONFIG — skipping backup"
  fi
  step "Remove .mcpServers.gmail (if present)"
  if [[ -f "$CLAUDE_CONFIG" ]] && jq -e '.mcpServers.gmail' "$CLAUDE_CONFIG" >/dev/null 2>&1; then
    if (( DRY_RUN )); then
      echo "    [dry-run] would remove .mcpServers.gmail"
    else
      tmp="$(mktemp)"
      jq 'del(.mcpServers.gmail)' "$CLAUDE_CONFIG" > "$tmp"
      mv "$tmp" "$CLAUDE_CONFIG"
      ok "Removed"
    fi
  else
    ok "No gmail entry to remove"
  fi
else
  warn "Skipping Claude Desktop config edit (--no-edit-config)"
fi

# ---------- 3. Verify .env ----------
step "Verify $ENV_FILE"
[[ -f "$ENV_FILE" ]] || { err "Missing $ENV_FILE"; exit 1; }
missing=()
for key in $REQUIRED_ENV_KEYS; do
  if grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
    val_preview="$(grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | head -n1 | cut -d= -f2-)"
    if [[ "$val_preview" == op://* ]]; then
      ok "$key set (1Password reference)"
    elif [[ -z "${val_preview// /}" ]]; then
      missing+=("$key (empty)"); err "$key present but empty"
    else
      ok "$key set (literal)"
    fi
  else
    missing+=("$key"); err "$key not set"
  fi
done
ek_line="$(grep -E '^[[:space:]]*ENCRYPTION_KEY=' "$ENV_FILE" | head -n1 || true)"
ek_val="${ek_line#*=}"
if [[ -n "$ek_val" && "$ek_val" != op://* && ${#ek_val} -lt 32 ]]; then
  err "ENCRYPTION_KEY shorter than 32 chars (${#ek_val})"
  missing+=("ENCRYPTION_KEY (too short)")
fi
(( ${#missing[@]} == 0 )) || { err "Fix .env: ${missing[*]}"; exit 1; }

# ---------- 4. Auth probe ----------
detect_op_mode() {
  # Returns: "service-account", "service-account-file", "interactive", or "none"
  if [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
    echo "service-account"; return
  fi
  if [[ -f "$SA_FILE" ]] && grep -qE '^OP_SERVICE_ACCOUNT_TOKEN=ops_' "$SA_FILE"; then
    echo "service-account-file"; return
  fi
  if "$OP_BIN" whoami >/dev/null 2>&1; then
    echo "interactive"; return
  fi
  echo "none"
}

probe_op_auth() {
  local mode="$1"
  case "$mode" in
    service-account)
      step "Probing op auth (mode: service account, env var)"
      local out err_out
      err_out="$(mktemp)"
      out="$("$OP_BIN" whoami 2>"$err_out")" || {
        err "OP_SERVICE_ACCOUNT_TOKEN is set but 'op whoami' failed:"
        sed 's/^/      /' "$err_out" >&2
        rm -f "$err_out"
        return 1
      }
      rm -f "$err_out"
      ok "Authenticated as service account"
      ;;
    service-account-file)
      step "Probing op auth (mode: service account, file)"
      local out err_out
      err_out="$(mktemp)"
      out="$( set -a; source "$SA_FILE"; set +a; "$OP_BIN" whoami 2>"$err_out" )" || {
        err "Token in $SA_FILE didn't authenticate. 'op whoami' said:"
        sed 's/^/      /' "$err_out" >&2
        rm -f "$err_out"
        return 1
      }
      rm -f "$err_out"
      ok "Authenticated using token from $SA_FILE"
      ;;
    interactive)
      step "Probing op auth (mode: interactive / desktop integration)"
      local out err_out
      err_out="$(mktemp)"
      out="$("$OP_BIN" whoami 2>"$err_out")" || {
        err "'op whoami' failed:"
        sed 's/^/      /' "$err_out" >&2
        rm -f "$err_out"
        return 1
      }
      rm -f "$err_out"
      ok "Authenticated (account: $(echo "$out" | grep -i 'url\|email' | head -1 || echo "active"))"
      ;;
    none)
      err "No 1Password authentication detected. Choose ONE of:"
      echo
      echo "  ${C_BOLD}A. Workstation w/ desktop app${C_RESET}"
      echo "     1Password desktop → Settings → Developer → enable"
      echo "        'Integrate with 1Password CLI'"
      echo "     Then verify:  op whoami"
      echo
      echo "  ${C_BOLD}B. Headless / server (recommended for this Ubuntu box)${C_RESET}"
      echo "     1. In 1Password.com → Developer Tools → create a Service Account"
      echo "        scoped to the vault containing your gmail-mcp secrets."
      echo "     2. Save the ops_xxx token to a file, e.g. ~/sa.env :"
      echo "          OP_SERVICE_ACCOUNT_TOKEN=ops_xxxxxxxxxxxxxxxxx"
      echo "     3. Re-run this script with:"
      echo "          ./$(basename "$0") --service-account-file ~/sa.env"
      echo "     4. Delete ~/sa.env afterward (it's been installed at $SA_FILE)."
      echo
      return 1
      ;;
  esac
}

probe_resolve() {
  # Confirms `op run` actually substitutes secrets, given current auth mode.
  # Passes --env-file .env explicitly so op picks up op:// refs reliably,
  # even when cwd autodetect is flaky on this op CLI build.
  local mode="$1"
  step "Confirm 'op run' resolves a secret"
  local err_out resolved rc
  err_out="$(mktemp)"
  case "$mode" in
    service-account-file)
      resolved="$( set -a; source "$SA_FILE"; set +a;
                   cd "$REPO_DIR" && "$OP_BIN" run --no-masking --env-file .env -- printenv GOOGLE_CLIENT_ID 2>"$err_out" )"
      rc=$?
      ;;
    *)
      resolved="$(cd "$REPO_DIR" && "$OP_BIN" run --no-masking --env-file .env -- printenv GOOGLE_CLIENT_ID 2>"$err_out")"
      rc=$?
      ;;
  esac
  if (( rc != 0 )); then
    err "'op run' failed (rc=$rc). stderr:"
    sed 's/^/      /' "$err_out" >&2
    rm -f "$err_out"
    return 1
  fi
  rm -f "$err_out"
  if [[ "$resolved" == op://* ]]; then
    err "GOOGLE_CLIENT_ID resolved to literal '$resolved' — substitution didn't happen"
    return 1
  fi
  if [[ -z "$resolved" ]]; then
    err "GOOGLE_CLIENT_ID resolved to empty"
    return 1
  fi
  ok "Resolved (first 8 chars: ${resolved:0:8}…)"
}

if (( SKIP_OP_TEST )); then
  warn "Skipping op auth probe (--skip-op-test)"
else
  OP_MODE="$(detect_op_mode)"
  echo "    Detected mode: ${C_BOLD}${OP_MODE}${C_RESET}"
  probe_op_auth "$OP_MODE" || exit 1
  probe_resolve "$OP_MODE" || exit 1
fi

# ---------- 5. Log dir ----------
step "Ensure log directory"
run "mkdir -p '$LOG_DIR'"
ok "$LOG_DIR ready"

# ---------- 6. Write systemd unit ----------
step "Write systemd unit at $UNIT_FILE"
ENV_FILE_DIRECTIVE=""
if (( SA_FILE_INSTALLED )) || [[ -f "$SA_FILE" ]]; then
  ENV_FILE_DIRECTIVE="EnvironmentFile=${SA_FILE}"
fi

read -r -d '' UNIT_CONTENT <<EOF || true
[Unit]
Description=Gmail MCP Server (navbuildz)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REPO_DIR}
${ENV_FILE_DIRECTIVE}
ExecStart=${OP_BIN} run --no-masking --env-file .env -- ${NODE_BIN} --no-warnings dist/index.js
Restart=on-failure
RestartSec=5
StandardOutput=append:${LOG_FILE}
StandardError=append:${LOG_FILE}
Environment=HOME=${HOME}
Environment=PATH=${HOME}/.local/bin:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF

if (( DRY_RUN )); then
  echo "    [dry-run] unit content:"
  printf '%s\n' "$UNIT_CONTENT" | sed 's/^/        /'
else
  mkdir -p "$(dirname "$UNIT_FILE")"
  printf '%s\n' "$UNIT_CONTENT" > "$UNIT_FILE"
  ok "Wrote $UNIT_FILE"
  if [[ -n "$ENV_FILE_DIRECTIVE" ]]; then
    ok "Unit will load OP_SERVICE_ACCOUNT_TOKEN from $SA_FILE"
  else
    warn "No service account file — unit will rely on caller's environment"
    warn "(this works for testing, but won't survive logout / fresh boot cleanly)"
  fi
fi

# ---------- 7. Reload + enable + start ----------
step "Reload + enable + start"
run "systemctl --user daemon-reload"
run "systemctl --user enable --now gmail-mcp.service"
(( RESTART_SERVICE )) && run "systemctl --user restart gmail-mcp.service"

if (( ENABLE_LINGER )); then
  step "Enable user linger"
  run "loginctl enable-linger '$USER_NAME'"
else
  warn "Linger NOT enabled. --enable-linger to keep service alive across logout."
fi

# ---------- 8. Verify ----------
step "Verify service"
if (( DRY_RUN )); then
  warn "Skipping verification in dry-run"
else
  sleep 2
  if systemctl --user is-active --quiet gmail-mcp.service; then
    ok "active (running)"
  else
    err "service NOT active"
    journalctl --user -u gmail-mcp.service -n 50 --no-pager || true
    exit 1
  fi
  echo "    Recent log:"
  tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/      /' || warn "log empty"

  step "HTTP health checks"
  health_code="$(curl -sk -o /dev/null -w '%{http_code}' "${SERVER_URL}/health" || echo '000')"
  setup_code="$(curl -sk -o /dev/null -w '%{http_code}' "${SERVER_URL}/setup"  || echo '000')"
  echo "      /health → $health_code"
  echo "      /setup  → $setup_code"
  [[ "$health_code" =~ ^2 ]] && ok "/health 2xx"  || warn "/health not 2xx"
  [[ "$setup_code"  =~ ^(2|4) ]] && ok "/setup reachable" || warn "/setup not responding"
fi

# ---------- 9. Manual next steps ----------
cat <<NEXT

${C_BOLD}${C_GREEN}Service is running.${C_RESET} Remaining manual steps:

${C_BOLD}1. Google OAuth consent screen${C_RESET}
   GCP Console → APIs & Services → OAuth consent screen → Test users
   Add the Gmail address(es), or set the app to Published.

${C_BOLD}2. Add Gmail account(s)${C_RESET}
   Open: ${SERVER_URL}/setup
   Accept TLS warning. Enter ADMIN_PASSWORD.
   "+ Add Gmail Account" → sign in → grant scopes.

${C_BOLD}3. Custom connector in Claude Desktop${C_RESET}
   Settings → Connectors → + → Add custom connector
     Name: Gmail
     URL:  ${SERVER_URL}/mcp
     OAuth: blank.

${C_BOLD}4. Restart Claude Desktop${C_RESET}
   pkill -f claude   # then relaunch

${C_BOLD}5. Smoke test${C_RESET}
   New chat → "List my connected Gmail accounts"

${C_BOLD}Useful:${C_RESET}
   systemctl --user status gmail-mcp.service
   journalctl --user -u gmail-mcp.service -f
   tail -f $LOG_FILE
NEXT
