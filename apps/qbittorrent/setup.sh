#!/usr/bin/env bash
# Pre-install setup for qBittorrent, run automatically by `stack.sh install qbittorrent`.
#
#   apps/qbittorrent/setup.sh           apply
#   apps/qbittorrent/setup.sh --check   verify only, change nothing
#
# Creates the two directories the container mounts and turns CoW off on them:
# on btrfs every downloaded block is otherwise copied on write, which fragments
# the files being written and again while they are read back for seeding. nocow
# is fixed at inode creation, so the attribute has to be set before the first
# file lands.
#
# The torrenting port is checked too: ../qbittorrent.container publishes it, but
# opening it in the firewall needs root, so this only reports.

set -euo pipefail

APPDATA="${HOME}/media/appdata/qbittorrent"
DOWNLOADS="${HOME}/media/downloads"
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
