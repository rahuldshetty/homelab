#!/usr/bin/env bash
# Host bootstrap: repo skeleton, user linger, podman API socket, proxy ports.
# Idempotent; everything is user-level except the firewall step, which needs
# root.
#
#   scripts/bootstrap.sh           apply
#   scripts/bootstrap.sh --check   verify only, change nothing

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
USER_NAME="$(id -un)"
USER_ID="$(id -u)"
QUADLET_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
SOCKET_PATH="/run/user/${USER_ID}/podman/podman.sock"

SKELETON=(apps docs scripts)

usage() {
  printf 'usage: %s [--check]\n' "${0##*/}" >&2
  exit 2
}

CHECK_ONLY=0
case "${1:-}" in
  '') ;;
  --check) CHECK_ONLY=1 ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage

changed=0
failed=0
note() { printf '%-9s %s\n' "$1" "$2"; }

if (( CHECK_ONLY )); then
  note 'MODE' 'check only -- nothing will be modified'
else
  note 'MODE' "applying as ${USER_NAME} (uid ${USER_ID})"
fi
echo

# Needed by every `systemctl --user` call; absent in non-login shells.
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/${USER_ID}}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

# --- repo skeleton ----------------------------------------------------------

echo "repo: ${REPO_ROOT}"
for entry in "${SKELETON[@]}"; do
  dir="${REPO_ROOT}/${entry}"
  if [[ -d "$dir" ]]; then
    note 'ok' "dir ${entry}/"
  elif (( CHECK_ONLY )); then
    note 'MISSING' "dir ${entry}/"
    failed=1
  else
    mkdir -p -- "$dir"
    note 'created' "dir ${entry}/"
    changed=$((changed + 1))
  fi
done

# Quadlet's generator scans only this path, so repo units are linked here.
if [[ -d "$QUADLET_DIR" ]]; then
  note 'ok' "dir ${QUADLET_DIR}"
elif (( CHECK_ONLY )); then
  note 'MISSING' "dir ${QUADLET_DIR}"
  failed=1
else
  mkdir -p -- "$QUADLET_DIR"
  note 'created' "dir ${QUADLET_DIR}"
  changed=$((changed + 1))
fi

# --- linger -----------------------------------------------------------------

echo
linger_state="$(loginctl show-user "$USER_NAME" -p Linger --value)"
if [[ "$linger_state" == 'yes' ]]; then
  note 'ok' "linger enabled for ${USER_NAME}"
elif (( CHECK_ONLY )); then
  note 'MISSING' "linger disabled for ${USER_NAME}"
  failed=1
else
  loginctl enable-linger "$USER_NAME"
  note 'enabled' "linger for ${USER_NAME}"
  changed=$((changed + 1))
fi

# --- podman API socket ------------------------------------------------------

case "$(systemctl --user is-enabled podman.socket 2>&1)" in
  enabled) note 'ok'      'podman.socket enabled' ;;
  *)       if (( CHECK_ONLY )); then
             note 'MISSING' 'podman.socket not enabled'
             failed=1
           else
             systemctl --user enable podman.socket
             note 'enabled' 'podman.socket'
             changed=$((changed + 1))
           fi ;;
esac

if systemctl --user is-active --quiet podman.socket; then
  note 'ok' 'podman.socket active'
elif (( CHECK_ONLY )); then
  note 'MISSING' 'podman.socket not active'
  failed=1
else
  systemctl --user start podman.socket
  note 'started' 'podman.socket'
  changed=$((changed + 1))
fi

# --- firewall ---------------------------------------------------------------

# Fedora's default zone opens only ssh and 1025-65535, so :80/:443 are dropped
# for LAN and tailnet hosts (unbound tailscale0 uses the default zone too).
fw_missing() {
  local svc port
  for svc in http https; do
    case "$svc" in http) port=80 ;; https) port=443 ;; esac
    firewall-cmd --quiet --query-service="$svc" && continue
    firewall-cmd --quiet --query-port="${port}/tcp" && continue
    printf '%s\n' "$svc"
  done
}

# firewalld is polkit-mediated (desktop prompt, no sudo); headless falls back
# to `sudo -n`, then an interactive sudo if a terminal exists.
fw_apply() {
  firewall-cmd "$@" 2>/dev/null && return 0
  sudo -n firewall-cmd "$@" 2>/dev/null && return 0
  [[ -t 0 ]] && sudo firewall-cmd "$@"
}

if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld; then
  note 'info' 'firewalld not running: :80/:443 left alone'
else
  mapfile -t fw_services < <(fw_missing)
  if (( ${#fw_services[@]} == 0 )); then
    note 'ok' "zone $(firewall-cmd --get-default-zone) allows http https"
  else
    fw_args=()
    for svc in "${fw_services[@]}"; do fw_args+=(--add-service="$svc"); done
    if (( CHECK_ONLY )); then
      note 'MISSING' "zone $(firewall-cmd --get-default-zone) blocks ${fw_services[*]}"
      failed=1
    elif fw_apply --permanent "${fw_args[@]}" && fw_apply --reload; then
      note 'opened' "zone $(firewall-cmd --get-default-zone): ${fw_services[*]}"
      changed=$((changed + 1))
    else
      note 'FAIL' "could not reach root to open ${fw_services[*]} -- run:"
      note '' "  sudo firewall-cmd --permanent ${fw_args[*]} && sudo firewall-cmd --reload"
      failed=1
    fi
  fi
fi

# --- verification -----------------------------------------------------------

echo
if [[ ! -S "$SOCKET_PATH" ]]; then
  note 'FAIL' "no socket at ${SOCKET_PATH}"
  failed=1
elif ! curl -fsS --max-time 5 --unix-socket "$SOCKET_PATH" \
       http://localhost/_ping >/dev/null 2>&1; then
  note 'FAIL' "API not answering on ${SOCKET_PATH}"
  failed=1
else
  note 'ok' "API answering on ${SOCKET_PATH}"
fi

if [[ "$(loginctl show-user "$USER_NAME" -p Linger --value)" == 'yes' ]]; then
  note 'ok' 'user manager survives logout/reboot'
else
  note 'FAIL' 'linger still disabled'
  failed=1
fi

echo
if (( failed )); then
  note 'FAILED' "${changed} change(s) applied, checks failed"
  exit 1
fi

if (( CHECK_ONLY )); then
  note 'PASS' 'all checks satisfied'
else
  note 'DONE' "${changed} change(s) applied"
fi
