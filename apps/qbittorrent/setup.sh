#!/usr/bin/env bash
# Pre-install setup for qBittorrent, run by `stack.sh install qbittorrent`.
#
#   apps/qbittorrent/setup.sh           apply
#   apps/qbittorrent/setup.sh --check   verify only, change nothing
#
# Creates the mounted directories with CoW off (nocow is fixed at inode
# creation), seeds ./qBittorrent.conf once (qBittorrent rewrites it after), and
# reports whether the torrenting port is open (opening it needs root).

set -euo pipefail

APPDATA="${HOME}/media/appdata/qbittorrent"
DOWNLOADS="${HOME}/media/downloads"
# Where the container's /config/qBittorrent/qBittorrent.conf lives on the host.
CONF_SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/qBittorrent.conf"
CONF_DIR="${APPDATA}/qBittorrent"
CONF="${CONF_DIR}/qBittorrent.conf"
# Must match TORRENTING_PORT and PublishPort in qbittorrent.container.
PORT=6881

CHECK_ONLY=0
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=1

changed=0
failed=0
ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
note() { printf '%-9s %s\n' 'info'    "$*"; }

# --- nocow directories ------------------------------------------------------

nocow_dir() {
  local dir="$1" fstype

  if [[ -d "$dir" ]]; then
    ok "directory ${dir}"
  elif (( CHECK_ONLY )); then
    bad "missing directory ${dir} -- run: scripts/stack.sh setup qbittorrent"
    failed=1
    return 0
  else
    mkdir -p "$dir"
    did "created ${dir}"
    changed=$((changed + 1))
  fi

  fstype="$(findmnt -no FSTYPE --target "$dir" 2>/dev/null || true)"
  if [[ "$fstype" != 'btrfs' ]]; then
    note "${dir} is on ${fstype:-an unknown filesystem}: no CoW to disable"
    return 0
  fi

  if lsattr -d "$dir" 2>/dev/null | grep -q 'C'; then
    ok "nocow on ${dir}"
  elif (( CHECK_ONLY )); then
    bad "nocow missing on ${dir} -- run: scripts/stack.sh setup qbittorrent"
    if find "$dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
      note 'directory already holds data; chattr cannot fix existing files'
    fi
    failed=1
  elif find "$dir" -mindepth 1 -print -quit 2>/dev/null | grep -q .; then
    # chattr +C only affects inodes created after it is set.
    bad "nocow missing on ${dir} and it is not empty"
    note "existing files keep CoW; move them out, 'chattr +C ${dir}', move them back"
    failed=1
  else
    chattr +C "$dir"
    did "chattr +C ${dir}"
    changed=$((changed + 1))
  fi
}

nocow_dir "$APPDATA"
nocow_dir "$DOWNLOADS"

# --- config seed ------------------------------------------------------------

# Settings this stack relies on: no authentication and a WebUI behind a
# TLS-terminating proxy. qBittorrent rewrites the file, so each key is checked
# individually rather than the whole file. `0.0.0.0/0` makes isAuthNeeded()
# false for everyone; the tailnet-only router is what gates the WebUI.

conf_keys() {
  local line
  for line in \
    'WebUI\LocalHostAuth=false' \
    'WebUI\AuthSubnetWhitelistEnabled=true' \
    'WebUI\CSRFProtection=false' \
    'WebUI\ReverseProxySupportEnabled=true'
  do
    grep -Fxq "$line" "$CONF" || { bad "config missing ${line}"; return 1; }
  done

  grep -Eq '^WebUI\\AuthSubnetWhitelist=.*0\.0\.0\.0/0.*::/0' "$CONF" \
    || { bad 'config whitelist does not cover every address'; return 1; }

  grep -Eq '^WebUI\\TrustedReverseProxiesList="[^"]+"' "$CONF" \
    || { bad 'config trusts no reverse proxies'; return 1; }
}

if [[ -f "$CONF" ]]; then
  if conf_keys; then
    ok 'config: unauthenticated, reverse proxy settings present'
  else
    note "edit ${CONF}, or delete it and re-run to reseed from ${CONF_SRC}"
    failed=1
  fi
elif (( CHECK_ONLY )); then
  bad "missing ${CONF} -- run: scripts/stack.sh setup qbittorrent"
  failed=1
else
  mkdir -p "$CONF_DIR"
  # qBittorrent's parser has no comment syntax: any "#" line with an "=" in it
  # becomes a preference key, so comments are dropped on the way in. The
  # trusted-proxy list is substituted here rather than seeded verbatim.
  # Trust X-Forwarded-* from everywhere: the WebUI is never published and this
  # host is tailnet-only, so nothing untrusted can spoof it. .env override wins.
  proxies="${QBITTORRENT_TRUSTED_PROXIES:-0.0.0.0/0; ::/0}"
  awk -v proxies="$proxies" '
    /^[[:space:]]*#/ { next }
    /^WebUI\\TrustedReverseProxiesList=/ {
      print "WebUI\\TrustedReverseProxiesList=\"" proxies "\""
      next
    }
    { print }
  ' "$CONF_SRC" > "$CONF"
  chmod 0644 "$CONF"
  did "seeded ${CONF} (trusted proxies: ${proxies})"
  changed=$((changed + 1))
fi

# --- torrenting port --------------------------------------------------------

if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld; then
  note 'firewalld not running: nothing to allow for the torrenting port'
elif firewall-cmd --quiet --query-port="${PORT}/tcp" \
  && firewall-cmd --quiet --query-port="${PORT}/udp"; then
  ok "${PORT}/tcp and ${PORT}/udp allowed in zone $(firewall-cmd --get-default-zone)"
else
  bad "${PORT}/tcp or ${PORT}/udp blocked in zone $(firewall-cmd --get-default-zone)"
  note 'incoming peers need both; open them once as root:'
  note "  sudo firewall-cmd --permanent --add-port=${PORT}/tcp --add-port=${PORT}/udp && sudo firewall-cmd --reload"
  failed=1
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
