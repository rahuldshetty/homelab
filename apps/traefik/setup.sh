#!/usr/bin/env bash
# Pre-install setup for Traefik, run by `stack.sh install traefik`.
#
#   apps/traefik/setup.sh           apply
#   apps/traefik/setup.sh --check   verify only, change nothing
#
# Resolves the tailnet name the Tailscale resolver needs (see tailnet.yml.in) --
# from .env TAILNET_DOMAIN or `tailscale status --json` -- and renders
# config/dynamic/tailnet.yml (gitignored).

set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${APP_DIR}/../.." && pwd)"
DOTENV="${REPO_ROOT}/.env"
TEMPLATE="${APP_DIR}/config/dynamic/tailnet.yml.in"
GENERATED="${APP_DIR}/config/dynamic/tailnet.yml"

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

# --- tailnet name -----------------------------------------------------------

domain="${TAILNET_DOMAIN:-}"

if [[ -n "$domain" ]]; then
  ok "TAILNET_DOMAIN=${domain}"
elif ! command -v jq >/dev/null 2>&1; then
  bad 'jq not found: needed to read `tailscale status --json`'
  note 'install jq, or pin the name with TAILNET_DOMAIN=host.tailnet.ts.net in .env'
  failed=1
elif ! command -v tailscale >/dev/null 2>&1; then
  bad 'no tailscale binary and no TAILNET_DOMAIN in .env'
  note 'install/start tailscale, or pin the name with TAILNET_DOMAIN=host.tailnet.ts.net in .env'
  failed=1
else
  domain="$(tailscale status --json 2>/dev/null | jq -r '.Self.DNSName // empty' | sed 's/\.$//' || true)"
  if [[ -n "$domain" ]]; then
    ok "tailnet name detected: ${domain}"
  else
    bad 'tailscale reported no Self.DNSName (logged out?)'
    note 'or pin the name with TAILNET_DOMAIN=host.tailnet.ts.net in .env'
    failed=1
  fi
fi

# Traefik only considers names of the form machine-name.domains-alias.ts.net.
if [[ -n "$domain" && "$domain" != *.ts.net ]]; then
  bad "tailnet name ${domain} is not a *.ts.net name"
  failed=1
fi

# --- render -----------------------------------------------------------------

if (( failed )); then
  note "leaving ${GENERATED#"${REPO_ROOT}"/} untouched"
else
  rendered="$(sed "s|@TAILNET_DOMAIN@|${domain}|g" "$TEMPLATE")"
  if [[ -f "$GENERATED" ]] && [[ "$(cat "$GENERATED")" == "$rendered" ]]; then
    ok "${GENERATED#"${REPO_ROOT}"/} up to date"
  elif (( CHECK_ONLY )); then
    bad "${GENERATED#"${REPO_ROOT}"/} is missing or stale -- run: scripts/stack.sh setup traefik"
    failed=1
  else
    # Atomic replace: Traefik watches this dir and must not read a partial file.
    tmp="$(mktemp "${GENERATED}.XXXXXX")"
    printf '%s\n' "$rendered" > "$tmp"
    mv "$tmp" "$GENERATED"
    did "rendered ${GENERATED#"${REPO_ROOT}"/}"
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
