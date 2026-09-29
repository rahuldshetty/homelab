#!/usr/bin/env bash
# Deploy every app under apps/ as systemd user services via Quadlet.
# Persistence comes from [Install] WantedBy=default.target on daemon-reload,
# not `systemctl enable`. Commands take an optional app name to scope them.

set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
APPS_DIR="${REPO_ROOT}/apps"
UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/containers/systemd"
USER_NAME="$(id -un)"
USER_ID="$(id -u)"
API_SOCKET="${XDG_RUNTIME_DIR:-/run/user/${USER_ID}}/podman/podman.sock"

# Secrets from the gitignored .env, exported so app setups inherit them.
DOTENV="${REPO_ROOT}/.env"
if [[ -f "$DOTENV" ]]; then
  set -a
  . "$DOTENV"
  set +a
fi

mapfile -t ALL_NETWORKS < <(find "$APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.network' | sort)
mapfile -t ALL_CONTAINERS < <(find "$APPS_DIR" -mindepth 2 -maxdepth 2 -type f -name '*.container' | sort)

TARGET=''      # app name; empty means the whole stack
NETWORKS=()    # selected units
CONTAINERS=()
SERVICES=()

ok()   { printf '%-9s %s\n' 'ok'      "$*"; }
bad()  { printf '%-9s %s\n' 'FAIL'    "$*"; }
did()  { printf '%-9s %s\n' 'applied' "$*"; }
info() { printf '%-9s %s\n' 'info'    "$*"; }
die()  { bad "$*" >&2; exit 1; }

http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$@" 2>/dev/null || echo 000; }

unit_service() {
  case "$(basename "$1")" in
    *.network)   printf '%s-network.service\n' "$(basename "$1" .network)" ;;
    *.container) printf '%s.service\n'         "$(basename "$1" .container)" ;;
  esac
}
unit_key() { sed -n "s/^$2=//p" "$1" | head -n1; }

# Unique app directories behind the current selection.
selected_apps() {
  local f
  { for f in "${NETWORKS[@]}" "${CONTAINERS[@]}"; do dirname "$f"; done; } | sort -u
}

# Optional per-app hook apps/<app>/setup.sh, idempotent and no sudo; runs
# before anything is linked or started. --check only verifies.
run_setups() {
  local mode="${1:-}" dir rc=0
  while read -r dir; do
    [[ -n "$dir" && -x "${dir}/setup.sh" ]] || continue
    info "setup ${dir#"${APPS_DIR}"/}"
    "${dir}/setup.sh" ${mode} || rc=1
  done < <(selected_apps)
  return $rc
}

# Scope later operations to apps/<app>/, or to everything when no app is given.
set_scope() {
  TARGET="${1:-}"
  if [[ -n "$TARGET" && ! -d "${APPS_DIR}/${TARGET}" ]]; then
    bad "no such app: ${TARGET}"
    info "apps: $(cd "$APPS_DIR" && printf '%s ' */ | tr -d '/')"
    exit 2
  fi
  NETWORKS=(); CONTAINERS=(); SERVICES=()
  local f
  for f in "${ALL_NETWORKS[@]}"; do
    [[ -z "$TARGET" || "$f" == "${APPS_DIR}/${TARGET}/"* ]] || continue
    NETWORKS+=("$f"); SERVICES+=("$(unit_service "$f")")
  done
  for f in "${ALL_CONTAINERS[@]}"; do
    [[ -z "$TARGET" || "$f" == "${APPS_DIR}/${TARGET}/"* ]] || continue
    CONTAINERS+=("$f"); SERVICES+=("$(unit_service "$f")")
  done
  (( ${#SERVICES[@]} )) || { bad "no units found under apps/${TARGET:-}"; exit 1; }
}

usage() {
  cat >&2 <<'EOF'
usage: scripts/stack.sh <command> [app|unit] [--purge]

  install   [app]        run app setup, link units, reload systemd, restart
  setup     [app]        run the per-app pre-install steps only
  check     [app]        prerequisites, app setup and installed state; no changes
  status    [app]        unit/container state, routers, HTTP probes
  logs      [unit]       follow the journal (no arg: whole stack)
  restart   [app|unit]   restart one app, one unit, or everything
  stop      [app]        stop an app, or every unit
  uninstall [app] [--purge]
                         stop and unlink; --purge also removes podman networks

  With no app argument the command covers every app under apps/.
EOF
  exit 2
}

port_prereq() {
  local start
  start="$(sysctl -n net.ipv4.ip_unprivileged_port_start 2>/dev/null || echo 1024)"
  (( start <= 80 )) && { ok "ip_unprivileged_port_start=${start}"; return 0; }
  bad "ip_unprivileged_port_start=${start}: cannot bind :80/:443 rootless"
  info 'fix once as root, then re-run:'
  info "  echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/90-unprivileged-ports.conf && sudo sysctl --system"
  return 1
}

# The socket file can vanish while the unit stays active; only a restart
# recreates the inode Traefik bind-mounts.
ensure_api_socket() {
  if [[ -S "$API_SOCKET" ]]; then
    ok "${API_SOCKET} present"
    return 0
  fi
  info "${API_SOCKET} missing -- restarting podman.socket"
  systemctl --user restart podman.socket || return 1
  local i
  for i in {1..25}; do
    [[ -S "$API_SOCKET" ]] && break
    sleep 0.2
  done
  [[ -S "$API_SOCKET" ]] || { bad "podman.socket did not create ${API_SOCKET}"; return 1; }
  did "podman.socket recreated ${API_SOCKET}"
}

# Host-level, so identical whichever app is selected.
check_prereqs() {
  local rc=0

  [[ -d "$UNIT_DIR" ]] && ok "quadlet dir ${UNIT_DIR}" \
    || { bad "missing ${UNIT_DIR} -- run scripts/bootstrap.sh"; rc=1; }

  [[ "$(loginctl show-user "$USER_NAME" -p Linger --value)" == 'yes' ]] \
    && ok "linger enabled for ${USER_NAME}" \
    || { bad 'linger disabled -- run scripts/bootstrap.sh'; rc=1; }

  systemctl --user is-active --quiet podman.socket \
    && ok 'podman.socket active' \
    || { bad 'podman.socket inactive'; rc=1; }

  [[ -S "$API_SOCKET" ]] && ok "${API_SOCKET} exists" \
    || { bad "no socket at ${API_SOCKET}"; rc=1; }

  if [[ -f "$DOTENV" ]]; then
    ok '.env present'
  else
    info 'no .env -- cp .env.sample .env (apps that need secrets will fail setup)'
  fi

  port_prereq || rc=1

  return $rc
}

# Produced by install; scoped to the selected app.
check_installed() {
  local rc=0 f s

  for f in "${NETWORKS[@]}" "${CONTAINERS[@]}"; do
    [[ -L "${UNIT_DIR}/$(basename "$f")" ]] && ok "linked $(basename "$f")" \
      || { bad "not linked: $(basename "$f") (run install)"; rc=1; }
  done

  for s in "${SERVICES[@]}"; do
    if systemctl --user cat "$s" >/dev/null 2>&1; then
      ok "generated ${s}"
    else
      bad "not generated: ${s} (run install)"
      rc=1
    fi
  done

  return $rc
}

cmd_check() {
  local rc=0
  info "scope: ${TARGET:-whole stack}"
  echo
  echo 'prerequisites:'
  check_prereqs || rc=1
  echo
  echo 'app setup:'
  run_setups --check || rc=1
  echo
  echo 'installed state:'
  check_installed || rc=1
  return $rc
}

# Traefik learns about containers from the API event stream; without this the
# status below races it and reports a false 404.
wait_for_routers() {
  local i n
  for i in {1..20}; do
    # `|| true`: curl fails while Traefik is restarting, and pipefail + set -e
    # would otherwise abort the script instead of retrying.
    n="$(curl -s --max-time 3 http://127.0.0.1:8080/traefik/api/http/routers 2>/dev/null \
      | grep -o '"name":"[^"]*@docker"' | wc -l || true)"
    (( n > 0 )) && { ok "Traefik discovered ${n} labelled router(s)"; return 0; }
    sleep 0.5
  done
  info 'no @docker router yet -- check labels, then: scripts/stack.sh logs traefik.service'
}

cmd_install() {
  ensure_api_socket || true
  echo

  check_prereqs || { echo; die 'prerequisites not satisfied -- nothing was changed'; }

  echo
  # Per-app groundwork before linking, so a fresh clone installs cleanly.
  run_setups || die 'app setup failed -- nothing was installed'
  echo

  local f s
  # Networks are shared plumbing: always ensured. Only containers are scoped.
  for f in "${ALL_NETWORKS[@]}"; do
    ln -sfn "$f" "${UNIT_DIR}/$(basename "$f")"
    did "linked $(basename "$f")"
  done
  for f in "${CONTAINERS[@]}"; do
    ln -sfn "$f" "${UNIT_DIR}/$(basename "$f")"
    did "linked $(basename "$f")"
  done

  systemctl --user daemon-reload
  did 'systemctl --user daemon-reload'

  for f in "${ALL_NETWORKS[@]}"; do
    s="$(unit_service "$f")"
    systemctl --user start "$s"
    did "started ${s}"
  done
  # restart, not start: start is a no-op on a running unit, so a changed unit
  # file (new mount, new label) would silently not apply.
  for f in "${CONTAINERS[@]}"; do
    s="$(unit_service "$f")"
    systemctl --user restart "$s"
    did "restarted ${s}"
  done

  if grep -q 'traefik\.http\.routers\.' "${CONTAINERS[@]}" 2>/dev/null; then
    wait_for_routers
  fi

  echo
  cmd_status
}

cmd_status() {
  local s f routers api http80 https443 state names=() filters=() inactive=()

  info "scope: ${TARGET:-whole stack}"
  for s in "${SERVICES[@]}"; do
    state="$(systemctl --user is-active "$s" 2>/dev/null || true)"
    printf '%-9s %-26s %s\n' 'unit' "$s" "$state"
    [[ "$state" == 'active' ]] || inactive+=("$s")
  done

  for f in "${CONTAINERS[@]}"; do
    names+=("$(unit_key "$f" ContainerName)")
    filters+=("--filter" "name=^$(unit_key "$f" ContainerName)\$")
  done
  if (( ${#names[@]} )); then
    echo
    podman ps -a "${filters[@]}" --format '{{.Names}} | {{.Status}} | {{.Ports}}' 2>/dev/null || true
  fi

  # Traefik's live router table: did the labels produce a route?
  routers="$(curl -s --max-time 5 http://127.0.0.1:8080/traefik/api/http/routers 2>/dev/null \
    | grep -o '"name":"[^"]*"' | cut -d'"' -f4 | sort | tr '\n' ' ' || true)"
  echo
  [[ -n "$routers" ]] && printf '%-9s %s\n' 'routers' "$routers" \
                      || printf '%-9s %s\n' 'routers' 'none'

  http80="$(http_code "http://127.0.0.1/")"
  https443="$(http_code -k "https://127.0.0.1/")"
  api="$(http_code "http://127.0.0.1:8080/traefik/api/overview")"
  printf '%-9s %-32s %s\n' 'probe' 'http://127.0.0.1/ want 301' "$http80"
  printf '%-9s %-32s %s\n' 'probe' 'https://127.0.0.1/ want non-000' "$https443"
  printf '%-9s %-32s %s\n' 'probe' 'api /traefik/api/overview want 200' "$api"

  echo
  info "dashboard: http://127.0.0.1:8080/traefik/ (or: ssh -N -L 8080:127.0.0.1:8080 $(hostname -s))"
  [[ "$api" != '200' ]] && info 'not serving: scripts/stack.sh logs traefik.service'
  if (( ${#inactive[@]} )); then
    info "not active: ${inactive[*]}"
    if (( ${#inactive[@]} == 1 )); then
      info "why: scripts/stack.sh logs ${inactive[0]}"
    else
      info 'why: scripts/stack.sh logs'
    fi
  fi
  return 0
}

cmd_logs() {
  local args=() s
  if [[ -n "${1:-}" ]]; then
    args=(-u "$1")
  else
    for s in "${SERVICES[@]}"; do args+=(-u "$s"); done
  fi
  exec journalctl --user "${args[@]}" -n 50 -f
}

cmd_restart() {
  local arg="${1:-}" s

  # A systemd unit name (traefik.service) is restarted directly; anything else
  # is an app name.
  if [[ -n "$arg" && ! -d "${APPS_DIR}/${arg}" ]]; then
    systemctl --user restart "$arg"
    did "restarted ${arg}"
    return 0
  fi

  set_scope "$arg"
  for s in "${SERVICES[@]}"; do
    systemctl --user restart "$s"
    did "restarted ${s}"
  done
  echo
  cmd_status
}

cmd_stop() {
  local i
  for (( i=${#SERVICES[@]}-1; i>=0; i-- )); do
    systemctl --user stop "${SERVICES[$i]}" 2>/dev/null || true
    did "stopped ${SERVICES[$i]}"
  done
}

cmd_uninstall() {
  local purge="${1:-0}"
  local f s name o other sel kept=()

  # Containers that survive, so a shared network is not removed under them.
  for other in "${ALL_CONTAINERS[@]}"; do
    sel=0
    for o in "${CONTAINERS[@]}"; do [[ "$o" == "$other" ]] && sel=1; done
    (( sel )) || kept+=("$other")
  done

  cmd_stop

  for f in "${CONTAINERS[@]}"; do
    name="$(unit_key "$f" ContainerName)"
    [[ -n "$name" ]] && podman rm -f "$name" >/dev/null 2>&1 || true
    rm -f "${UNIT_DIR}/$(basename "$f")"
    did "unlinked $(basename "$f")"
  done

  for f in "${NETWORKS[@]}"; do
    name="$(unit_key "$f" NetworkName)"
    if grep -q "Network=${name}\.network" "${kept[@]}" 2>/dev/null; then
      info "keeping $(basename "$f"): another app still joins it"
      continue
    fi
    rm -f "${UNIT_DIR}/$(basename "$f")"
    did "unlinked $(basename "$f")"
  done

  if (( purge )); then
    for f in "${NETWORKS[@]}"; do
      name="$(unit_key "$f" NetworkName)"
      [[ -n "$name" ]] || continue
      if (( ${#kept[@]} )) && grep -q "Network=${name}\.network" "${kept[@]}" 2>/dev/null; then
        info "keeping podman network ${name}: another app still joins it"
        continue
      fi
      podman network rm "$name" >/dev/null 2>&1 || true
      did "removed podman network ${name}"
    done
  fi

  systemctl --user daemon-reload
  did 'systemctl --user daemon-reload'
  info "repo config left untouched: ${APPS_DIR}"
}

cmd="${1:-}"
shift || true

case "$cmd" in
  install)   set_scope "${1:-}"; cmd_install ;;
  setup)     set_scope "${1:-}"; run_setups ;;
  check)     set_scope "${1:-}"; cmd_check ;;
  status)    set_scope "${1:-}"; cmd_status ;;
  logs)      set_scope ''; cmd_logs "${1:-}" ;;
  restart)   cmd_restart "${1:-}" ;;
  stop)      set_scope "${1:-}"; cmd_stop ;;
  uninstall)
    purge=0; app=''
    for a in "$@"; do
      case "$a" in
        --purge) purge=1 ;;
        '') ;;
        *) app="$a" ;;
      esac
    done
    set_scope "$app"
    cmd_uninstall "$purge"
    ;;
  ''|help|-h|--help) usage ;;
  *) bad "unknown command: ${cmd}"; echo; usage ;;
esac
