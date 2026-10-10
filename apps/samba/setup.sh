#!/usr/bin/env bash
# Read-only SMB shares of the downloads and Steam library dirs. No custom unit:
# writes smb.conf, creates the Samba account, opens the firewall and enables the
# stock smb.service. See README.md.
#
#   apps/samba/setup.sh           apply (needs root)
#   apps/samba/setup.sh --check   verify only, change nothing

set -euo pipefail

APP_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SMB_CONF=/etc/samba/smb.conf
SMB_CONF_SRC="${APP_DIR}/smb.conf"
OLD_UNIT=/etc/systemd/system/smb.service
SE_BOOL=samba_export_all_ro

# The share is owned by, and served as, the invoking user; stay correct if the
# script is launched as `sudo apps/samba/setup.sh`.
if (( EUID == 0 )) && [[ -n "${SUDO_USER:-}" ]]; then
  RUN_USER="$SUDO_USER"
  RUN_HOME="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
else
  RUN_USER="$(id -un)"
  RUN_HOME="$HOME"
fi
# Must match the [name] and `path =` stanzas in smb.conf.
SHARE_NAMES=(downloads steamapps)
SHARE_DIRS=(
  "${RUN_HOME}/media/downloads"
  "${RUN_HOME}/.local/share/Steam/steamapps"
)
SHARE_HINTS=(
  'install qbittorrent first (scripts/stack.sh install qbittorrent)'
  'launch Steam once so it creates the library'
)

CHECK_ONLY=0
[[ "${1:-}" == '--check' ]] && CHECK_ONLY=1

changed=0
failed=0
config_changed=0
ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
note() { printf '%-9s %s\n' 'info'    "$*"; }

as_root() {
  "$@" 2>/dev/null && return 0
  sudo -n "$@" 2>/dev/null && return 0
  [[ -t 0 ]] && sudo "$@"
}
# Read-only probe that never prompts for a password.
as_root_q() { "$@" 2>/dev/null || sudo -n "$@" 2>/dev/null; }

# --- share directories ------------------------------------------------------

for i in "${!SHARE_DIRS[@]}"; do
  if [[ -d "${SHARE_DIRS[$i]}" ]]; then
    ok "share dir ${SHARE_DIRS[$i]}"
  else
    bad "missing ${SHARE_DIRS[$i]} -- ${SHARE_HINTS[$i]}"
    failed=1
  fi
done
if (( failed )); then exit 1; fi

# --- config -----------------------------------------------------------------

for dir in "${SHARE_DIRS[@]}"; do
  if ! grep -Fq "path = ${dir}" "$SMB_CONF_SRC"; then
    bad "${SMB_CONF_SRC} does not point at ${dir}"
    failed=1
  fi
done

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
    config_changed=1
  else
    bad "could not install ${SMB_CONF} (need root)"
    failed=1
  fi
fi

# --- samba account ----------------------------------------------------------

# Windows refuses guest sessions, so the share authenticates. The account must
# already exist as a Unix user (it does); smbpasswd adds it to Samba with the
# password Windows will prompt for.
HAVE_ROOT=0
if (( EUID == 0 )) || sudo -n true 2>/dev/null; then HAVE_ROOT=1; fi

if (( CHECK_ONLY )); then
  if (( HAVE_ROOT )) && as_root_q pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$RUN_USER"; then
    ok "Samba account ${RUN_USER}"
  elif (( HAVE_ROOT )); then
    bad "no Samba account for ${RUN_USER} -- run: apps/samba/setup.sh"
    failed=1
  else
    note "Samba account ${RUN_USER}: cannot verify without root"
  fi
elif as_root pdbedit -L 2>/dev/null | cut -d: -f1 | grep -qx "$RUN_USER"; then
  ok "Samba account ${RUN_USER}"
elif as_root smbpasswd -a "$RUN_USER"; then
  did "created Samba account ${RUN_USER} (use the password you just typed on Windows)"
  changed=$((changed + 1))
else
  bad "could not create Samba account ${RUN_USER} (need root)"
  failed=1
fi

# --- firewall ---------------------------------------------------------------

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

# downloads is container_file_t, Steam is data_home_t; both are covered by the
# stock boolean -- no custom policy module.
if ! getenforce 2>/dev/null | grep -q '^Enforcing$'; then
  note 'SELinux not enforcing: no boolean needed'
elif [[ "$(getsebool "$SE_BOOL" 2>/dev/null | awk '{print $NF}')" == on ]]; then
  ok "SELinux boolean ${SE_BOOL} is on"
elif (( CHECK_ONLY )); then
  bad "SELinux boolean ${SE_BOOL} is off -- run: sudo setsebool -P ${SE_BOOL} on"
  failed=1
elif as_root setsebool -P "$SE_BOOL" on; then
  did "enabled SELinux boolean ${SE_BOOL}"
  changed=$((changed + 1))
else
  bad "could not enable ${SE_BOOL} (need root)"
  failed=1
fi

# `:Z` categories (s0:cN,cM) are unsatisfiable by smbd's s0 context; report stale.
for dir in "${SHARE_DIRS[@]}"; do
  ctx="$(getfattr -n security.selinux --only-values "$dir" 2>/dev/null | tr -d '\0' || true)"
  case "$ctx" in
    *':c'[0-9]*)
      note "SELinux: ${dir} still has MCS categories (${ctx#*:})"
      note 'restart its writer after switching the mount to :z'
      ;;
  esac
done

# --- service ----------------------------------------------------------------

# Older installs dropped a duplicate unit here, which shadows the packaged one.
if [[ -e "$OLD_UNIT" ]]; then
  if (( CHECK_ONLY )); then
    bad "${OLD_UNIT} shadows the packaged unit -- run: apps/samba/setup.sh"
    failed=1
  elif as_root rm -f "$OLD_UNIT" && as_root systemctl daemon-reload \
    && as_root systemctl enable --now smb; then
    did "removed ${OLD_UNIT} and re-enabled the packaged smb.service"
    changed=$((changed + 1))
  else
    bad "could not remove ${OLD_UNIT} (need root)"
    failed=1
  fi
fi

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

# --- reload -----------------------------------------------------------------

# smbd caches smb.conf; SIGHUP makes new shares appear without dropping sessions.
if (( config_changed )) && systemctl is-active --quiet smb; then
  if as_root systemctl reload smb; then
    did 'reloaded smbd config'
  else
    note 'could not reload smbd; the config applies on next restart'
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
  for name in "${SHARE_NAMES[@]}"; do
    note "share ${name}: \\\\$(hostname -f)\\${name}  (read-only, user ${RUN_USER})"
  done
fi
