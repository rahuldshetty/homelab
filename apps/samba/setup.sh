#!/usr/bin/env bash
# Samba share for the qBittorrent downloads directory: anonymous, read-only,
# all access forced to `nobody`.
#
#   apps/samba/setup.sh           apply (needs root)
#   apps/samba/setup.sh --check   verify only, change nothing
#
# Host-level, not a Quadlet: smbd must run as root for `force user = nobody`,
# so scripts/stack.sh (rootless user services) does not manage this app. Run
# this script directly; see README.md for the SELinux caveat.

set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SHARE_DIR="${HOME}/media/downloads"
SMB_CONF=/etc/samba/smb.conf
UNIT=/etc/systemd/system/smb.service
SMB_CONF_SRC="${APP_DIR}/smb.conf"
UNIT_SRC="${APP_DIR}/smb.service"

CHECK_ONLY=0
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=1

changed=0
failed=0
ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
note() { printf '%-9s %s\n' 'info'    "$*"; }

# polkit first, then non-interactive sudo, then an interactive sudo. Mirrors
# the firewall step in scripts/bootstrap.sh.
as_root() {
  "$@" 2>/dev/null && return 0
  sudo -n "$@" 2>/dev/null && return 0
  [[ -t 0 ]] && sudo "$@"
}

# --- share directory --------------------------------------------------------

if [[ -d "$SHARE_DIR" ]]; then
  ok "share dir ${SHARE_DIR}"
else
  bad "missing ${SHARE_DIR} -- install qbittorrent first (scripts/stack.sh install qbittorrent)"
  exit 1
fi

# --- config ----------------------------------------------------------------

# The share path is baked into smb.conf; keep them in sync.
if ! grep -Fq "path = ${SHARE_DIR}" "$SMB_CONF_SRC"; then
  bad "${SMB_CONF_SRC} does not point at ${SHARE_DIR}"
  failed=1
fi

if [[ -f "$SMB_CONF" ]] && cmp -s "$SMB_CONF_SRC" "$SMB_CONF"; then
  ok "installed ${SMB_CONF}"
elif (( CHECK_ONLY )); then
  bad "${SMB_CONF} differs from ${SMB_CONF_SRC} -- run: apps/samba/setup.sh"
  failed=1
else
  if [[ -f "$SMB_CONF" && ! -f "${SMB_CONF}.orig" ]]; then
    as_root cp -a "$SMB_CONF" "${SMB_CONF}.orig" || true
  fi
  if as_root install -m 0644 "$SMB_CONF_SRC" "$SMB_CONF"; then
    did "installed ${SMB_CONF} (previous kept at ${SMB_CONF}.orig)"
    changed=$((changed + 1))
  else
    bad "could not install ${SMB_CONF} (need root)"
    failed=1
  fi
fi

# --- unit ------------------------------------------------------------------

if [[ -f "$UNIT" ]] && cmp -s "$UNIT_SRC" "$UNIT"; then
  ok "installed ${UNIT}"
elif (( CHECK_ONLY )); then
  bad "${UNIT} differs from ${UNIT_SRC} -- run: apps/samba/setup.sh"
  failed=1
elif as_root install -m 0644 "$UNIT_SRC" "$UNIT"; then
  did "installed ${UNIT}"
  changed=$((changed + 1))
else
  bad "could not install ${UNIT} (need root)"
  failed=1
fi

# --- ACLs for `nobody` ------------------------------------------------------

# smbd runs as `nobody`; the home dir is 0700 and the share 0700, so without
# these ACLs samba returns "access denied" regardless of the config.
acl_ok() {
  getfacl -cp "$HOME" 2>/dev/null | grep -qx 'user:nobody:x' || return 1
  getfacl -cp "$SHARE_DIR" 2>/dev/null | grep -q '^user:nobody:r' || return 1
  getfacl -cp "$SHARE_DIR" 2>/dev/null | grep -q '^default:user:nobody:r' || return 1
}

if acl_ok; then
  ok "ACLs grant nobody read/traverse"
elif (( CHECK_ONLY )); then
  bad "missing ACLs for nobody -- run: apps/samba/setup.sh"
  failed=1
elif as_root setfacl -m u:nobody:x "$HOME" \
  && as_root setfacl -R -m u:nobody:rX "$SHARE_DIR" \
  && as_root setfacl -R -d -m u:nobody:rX "$SHARE_DIR"; then
  did "ACLs: ${HOME} traverse, ${SHARE_DIR} read + default"
  changed=$((changed + 1))
else
  bad "could not set ACLs (need root)"
  failed=1
fi

# --- firewall ---------------------------------------------------------------

# FedoraWorkstation already allows samba-client (137/138 udp); the `samba`
# service adds 139/445 tcp.
if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld; then
  note 'firewalld not running: nothing to open'
elif firewall-cmd --quiet --query-service=samba; then
  ok "samba allowed in zone $(firewall-cmd --get-default-zone)"
elif (( CHECK_ONLY )); then
  bad "samba blocked in zone $(firewall-cmd --get-default-zone)"
  note "  sudo firewall-cmd --permanent --add-service=samba && sudo firewall-cmd --reload"
  failed=1
elif as_root firewall-cmd --permanent --add-service=samba \
  && as_root firewall-cmd --reload; then
  did "opened samba in zone $(firewall-cmd --get-default-zone)"
  changed=$((changed + 1))
else
  bad "could not open samba (need root):"
  note "  sudo firewall-cmd --permanent --add-service=samba && sudo firewall-cmd --reload"
  failed=1
fi

# --- selinux ----------------------------------------------------------------

# podman's :Z relabels the downloads mount container_file_t; smbd cannot read
# that type under SELinux enforcing. Warn here; the fix is in README.md.
ctx="$(getfattr -n security.selinux --only-values "$SHARE_DIR" 2>/dev/null | tr -d '\0' || true)"
case "$ctx" in
  *container_file_t*)
    note "SELinux: ${SHARE_DIR} is ${ctx#*:}"
    note "smbd (smbd_t) cannot read container_file_t -- see apps/samba/README.md"
    ;;
esac

# --- service ----------------------------------------------------------------

if systemctl is-enabled --quiet smb 2>/dev/null && systemctl is-active --quiet smb; then
  ok 'smb enabled and active'
elif (( CHECK_ONLY )); then
  bad 'smb not enabled/active -- run: apps/samba/setup.sh'
  failed=1
elif as_root systemctl daemon-reload && as_root systemctl enable --now smb; then
  did 'smb enabled and started'
  changed=$((changed + 1))
else
  bad 'could not enable smb (need root)'
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
  note "connect: \\\\$(hostname -f)\\downloads  (read-only, anonymous)"
fi
