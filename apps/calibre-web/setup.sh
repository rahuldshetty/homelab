#!/usr/bin/env bash
# Pre-install setup for Calibre-Web, run by `stack.sh install calibre-web`.
#
#   apps/calibre-web/setup.sh           apply
#   apps/calibre-web/setup.sh --check   verify only, change nothing

set -euo pipefail

APPDATA="${HOME}/media/appdata/calibre-web"
CONFIG="${APPDATA}/config"
BOOKS="${APPDATA}/books"

CHECK_ONLY=0
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=1

changed=0
failed=0
ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
note() { printf '%-9s %s\n' 'info'    "$*"; }

nocow_dir() {
  local dir="$1" fstype

  if [[ -d "$dir" ]]; then
    ok "directory ${dir}"
  elif (( CHECK_ONLY )); then
    bad "missing directory ${dir} -- run: scripts/stack.sh setup calibre-web"
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
    bad "nocow missing on ${dir} -- run: scripts/stack.sh setup calibre-web"
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

# Parent first: children inherit nocow.
nocow_dir "$APPDATA"
nocow_dir "$CONFIG"
nocow_dir "$BOOKS"

if [[ -f "${BOOKS}/metadata.db" ]]; then
  ok "Calibre library at ${BOOKS}"
elif (( CHECK_ONLY )); then
  note "no Calibre library at ${BOOKS} -- add one before configuring /books"
else
  note "no Calibre library at ${BOOKS} (metadata.db missing)"
  note "create one with the calibre app and move it here, or copy an existing library"
fi

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
