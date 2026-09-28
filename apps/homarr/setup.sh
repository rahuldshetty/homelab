#!/usr/bin/env bash
# Pre-install setup for Homarr, run automatically by `stack.sh install homarr`.
#
#   apps/homarr/setup.sh           apply
#   apps/homarr/setup.sh --check   verify only, change nothing
#
# Homarr needs two things before it can run: an appdata directory that is nocow
# (nocow is fixed at inode creation, so it has to exist before the SQLite
# database does) and the SECRET_ENCRYPTION_KEY the image refuses to start
# without. The key is read from the repo-root .env and never generated here, so
# .env stays the single source of truth.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DOTENV="${REPO_ROOT}/.env"
APPDATA="${HOME}/media/appdata/homarr"
APPDATA_PARENT="$(dirname "$APPDATA")"
ENV_FILE="${HOME}/.config/homarr/env"
KEY='SECRET_ENCRYPTION_KEY'

# stack.sh already loads .env; this allows running the script directly.
if [[ -f "$DOTENV" ]]; then
  set -a
  . "$DOTENV"
  set +a
fi

CHECK_ONLY=0
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=1

changed=0
failed=0
ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
note() { printf '%-9s %s\n' 'info'    "$*"; }

# --- appdata directory ------------------------------------------------------

if [[ -d "$APPDATA" ]]; then
  ok "appdata ${APPDATA}"
elif (( CHECK_ONLY )); then
  bad "missing appdata ${APPDATA}"
  failed=1
else
  mkdir -p "$APPDATA"
  did "created ${APPDATA}"
  changed=$((changed + 1))
fi

if lsattr -d "$APPDATA_PARENT" 2>/dev/null | grep -q 'C'; then
  ok "nocow on ${APPDATA_PARENT}"
else
  if (( CHECK_ONLY )); then
    bad "nocow missing on ${APPDATA_PARENT}"
    if find "$APPDATA" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      note 'directory already holds data; chattr cannot fix existing files'
    fi
    failed=1
  else
    chattr +C "$APPDATA_PARENT"
    did "chattr +C ${APPDATA_PARENT}"
    changed=$((changed + 1))
  fi
fi

# --- encryption key ---------------------------------------------------------

key="${SECRET_ENCRYPTION_KEY:-}"

if [[ ! "$key" =~ ^[0-9a-f]{64}$ ]]; then
  bad "${KEY} is not 64 hex characters in ${DOTENV}"
  note 'set it up once:'
  note '  cp .env.sample .env'
  note "  printf '${KEY}=%s\n' \"\$(openssl rand -hex 32)\""
  note 'then put that line into .env'
  failed=1
elif [[ -f "$ENV_FILE" ]] && grep -q "^${KEY}=" "$ENV_FILE"; then
  # .env is the source of truth, so this file is derived from it. A previous
  # value is kept aside rather than discarded: if Homarr already stored
  # credentials, the old key is the only way back to them.
  existing="$(sed -n "s/^${KEY}=//p" "$ENV_FILE" | head -n1)"
  if [[ "$existing" == "$key" ]]; then
    ok "${ENV_FILE} matches .env"
  elif (( CHECK_ONLY )); then
    bad "${ENV_FILE} differs from .env -- run: scripts/stack.sh setup homarr"
    note "it will be rewritten from .env, previous value kept as $(basename "${ENV_FILE}").bak"
    failed=1
  else
    cp -p "$ENV_FILE" "${ENV_FILE}.bak"
    printf '%s=%s\n' "$KEY" "$key" > "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    did "${ENV_FILE} rewritten from .env (previous value in $(basename "${ENV_FILE}").bak)"
    changed=$((changed + 1))
  fi
elif (( CHECK_ONLY )); then
  bad "missing ${ENV_FILE} -- run: scripts/stack.sh setup homarr"
  failed=1
else
  mkdir -p "$(dirname "$ENV_FILE")"
  umask 077
  printf '%s=%s\n' "$KEY" "$key" > "$ENV_FILE"
  did "wrote ${ENV_FILE} from .env"
  changed=$((changed + 1))
fi

if [[ -f "$ENV_FILE" ]]; then
  if [[ "$(stat -c '%a' "$ENV_FILE")" == '600' ]]; then
    ok "${ENV_FILE} mode 600"
  elif (( CHECK_ONLY )); then
    bad "${ENV_FILE} is mode $(stat -c '%a' "$ENV_FILE"), expected 600"
    failed=1
  else
    chmod 600 "$ENV_FILE"
    did "chmod 600 ${ENV_FILE}"
    changed=$((changed + 1))
  fi
fi

# --- summary ----------------------------------------------------------------

echo
if (( failed )); then
  bad 'setup incomplete'
  exit 1
fi

if (( CHECK_ONLY )); then
  ok 'setup satisfied'
else
  ok "setup complete (${changed} change(s))"
fi
