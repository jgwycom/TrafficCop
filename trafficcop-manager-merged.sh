#!/usr/bin/env bash
# trafficcop-manager-merged.sh
# Robust installer/manager for TrafficCop Pushgateway Agent
# Tested on Debian/Ubuntu-family systemd hosts
set -Eeuo pipefail

# ===== Default Configs (can be overridden in /etc/trafficcop-agent.env) =====
DEFAULT_PG_URL="http://45.78.23.232:19091"
DEFAULT_JOB_NAME="trafficcop"
DEFAULT_INSTANCE="$(hostname -f 2>/dev/null || hostname)"
DEFAULT_PUSH_INTERVAL="10"           # seconds
DEFAULT_CURL_TIMEOUT="5"             # seconds
DEFAULT_IFACES="AUTO"                # AUTO | space-separated list | "*" = all non-lo
DEFAULT_RUN_DIR="/run/trafficcop"
DEFAULT_METRICS_PATH="${DEFAULT_RUN_DIR}/metrics.prom"
DEFAULT_LOG_LEVEL="info"             # info|debug

# ===== Paths =====
AGENT_DIR="/opt/trafficcop-agent"
AGENT_BIN="${AGENT_DIR}/agent.sh"
ENV_FILE="/etc/trafficcop-agent.env"
SERVICE_FILE="/etc/systemd/system/trafficcop-agent.service"
CRON_FILE="/etc/cron.d/trafficcop-agent" # 旧版本兜底
UNIT_NAME="trafficcop-agent.service"

# ===== CLI Flags =====
FLAG_OVERWRITE="false"
FLAG_KEEP="false"
FLAG_UNINSTALL="false"
FLAG_CLEAR_PG="false"
FLAG_YES="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --overwrite) FLAG_OVERWRITE="true"; shift;;
    --keep) FLAG_KEEP="true"; shift;;
    --uninstall) FLAG_UNINSTALL="true"; shift;;
    --clear-pg) FLAG_CLEAR_PG="true"; shift;;
    -y|--yes) FLAG_YES="true"; shift;;
    -h|--help)
      cat <<'HLP'
Usage: trafficcop-manager-merged.sh [options]

Actions (choose one if non-interactive):
  --overwrite     Fresh reinstall (wipe old, then install)
  --keep          Keep current installation (no changes)
  --uninstall     Uninstall everything (service, files)
Optional:
  --clear-pg      Also clear Pushgateway metrics for this instance (or whole job if --yes and confirm)
  -y, --yes       Assume "yes" to prompts (non-interactive)

If no action flags are provided, script will interactively ask:
  [O]verwrite / [K]eep / [U]ninstall
HLP
      exit 0;;
    *)
      echo "Unknown option: $1"; exit 2;;
  esac
done

# ===== Helpers =====
log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (sudo -i)."; }

svc_is_installed() { [[ -f "$SERVICE_FILE" ]] || systemctl list-unit-files | grep -q "^trafficcop-agent\.service"; }
svc_is_active() { systemctl is-active --quiet "$UNIT_NAME"; }

ensure_dirs() {
  install -d -m 755 "$AGENT_DIR"
  install -d -m 755 "$(dirname "$ENV_FILE")"
  install -d -m 755 "$DEFAULT_RUN_DIR"
}

stop_disable_service() {
  systemctl stop "$UNIT_NAME" 2>/dev/null || true
  systemctl disable "$UNIT_NAME" 2>/dev/null || true
}

remove_old_cron() {
  rm -f "$CRON_FILE" 2>/dev/null || true
}

remove_files() {
  rm -f "$SERVICE_FILE" || true
  rm -rf "$AGENT_DIR" || true
  rm -f "$ENV_FILE" || true
  systemctl daemon-reload || true
}

detect_existing() {
  local found="false"
  [[ -d "$AGENT_DIR" ]] && found="true"
  svc_is_installed && found="true"
  [[ -f "$ENV_FILE" ]] && found="true"
  [[ -f "$CRON_FILE" ]] && found="true"
  echo "$found"
}

confirm() {
  local prompt="$1"
  if [[ "$FLAG_YES" == "true" ]]; then
    return 0
  fi
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

# Read env with defaults (for Pushgateway clearing/self-check)
read_env_effective() {
  local PG_URL="$DEFAULT_PG_URL"
  local JOB="$DEFAULT_JOB_NAME"
  local INST="$DEFAULT_INSTANCE"
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    PG_URL="${PG_URL:-$DEFAULT_PG_URL}"
    JOB_NAME="${JOB_NAME:-$DEFAULT_JOB_NAME}"
    INSTANCE="${INSTANCE:-$DEFAULT_INSTANCE}"
    echo "$PG_URL|${JOB_NAME}|${INSTANCE}"
  else
    echo "$PG_URL|$JOB|$INST"
  fi
}

clear_pushgateway() {
  local cfg; cfg="$(read_env_effective)"
  local PG_URL JOB INSTANCE
  PG_URL="$(echo "$cfg" | cut -d'|' -f1)"
  JOB="$(echo "$cfg" | cut -d'|' -f2)"
  INSTANCE="$(echo "$cfg" | cut -d'|' -f3)"

  log "Will clear Pushgateway for instance: ${INSTANCE} (job=${JOB}) at ${PG_URL}"

  if confirm "DELETE metrics for job=${JOB}, instance=${INSTANCE}?"; then
    curl -fsS -X DELETE "${PG_URL%/}/metrics/job/${JOB}/instance/${INSTANCE}" && log "Cleared job=${JOB}, instance=${INSTANCE}"
  else
    log "Skipped instance delete."
  fi

  if confirm "ALSO delete the entire job=${JOB} (all instances)?"; then
    curl -fsS -X DELETE "${PG_URL%/}/metrics/job/${JOB}" && log "Cleared entire job=${JOB}"
  else
    log "Skipped whole-job delete."
  fi
}

write_env_file() {
  cat >"$ENV_FILE" <<EOF
# Environment for trafficcop-agent
# You can edit and 'systemctl restart trafficcop-agent' to apply.
PG_URL="${DEFAULT_PG_URL}"
JOB_NAME="${DEFAULT_JOB_NAME}"
INSTANCE="${DEFAULT_INSTANCE}"
PUSH_INTERVAL="${DEFAULT_PUSH_INTERVAL}"
CURL_TIMEOUT="${DEFAULT_CURL_TIMEOUT}"
IFACES="${DEFAULT_IFACES}"      # AUTO | "*" | "eth0 ens3 ..." (space separated)
RUN_DIR="${DEFAULT_RUN_DIR}"
METRICS_PATH="${DEFAULT_METRICS_PATH}"
LOG_LEVEL="${DEFAULT_LOG_LEVEL}"
EOF
  chmod 0644 "$ENV_FILE"
}

write_agent_script() {
  cat >"$AGENT_BIN" <<'EOS'
#!/usr/bin/env bash
# /opt/trafficcop-agent/agent.sh
# AGENT_VERSION=2.0-stable
set -Eeuo pipefail

# Load env (with fallbacks)
ENV_FILE="/etc/trafficcop-agent.env"
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"

PG_URL="${PG_URL:-http://127.0.0.1:9091}"
JOB_NAME="${JOB_NAME:-trafficcop}"
INSTANCE="${INSTANCE:-$(hostname -f 2>/dev/null || hostname)}"
PUSH_INTERVAL="${PUSH_INTERVAL:-10}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
IFACES="${IFACES:-AUTO}"
RUN_DIR="${RUN_DIR:-/run/trafficcop}"
METRICS_PATH="${METRICS_PATH:-${RUN_DIR}/metrics.prom}"
LOG_LEVEL="${LOG_LEVEL:-info}"

log() {
  local lvl="$1"; shift
  if [[ "$lvl" == "error" ]] || [[ "$LOG_LEVEL" == "debug" ]] || [[ "$lvl" == "info" ]]; then
    echo "[$(date +'%F %T')] [$lvl] $*"
  fi
}

cleanup() {
  log info "Exiting, cleaning up..."
  exit 0
}
trap cleanup INT TERM

ensure_dirs() {
  install -d -m 755 "$RUN_DIR"
}

list_ifaces() {
  local ret=()
  if [[ "$IFACES" == "AUTO" ]]; then
    # 默认选择默认路由的出接口 + 其他UP的非lo接口
    local def; def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')" || true
    [[ -n "$def" ]] && ret+=("$def")
    while IFS= read -r name; do
      [[ "$name" == "lo" ]] && continue
      ret+=("$name")
    done < <(ip -o link show up 2>/dev/null | awk -F': ' '{print $2}')
  elif [[ "$IFACES" == "*" ]]; then
    while IFS= read -r name; do
      [[ "$name" == "lo" ]] && continue
      ret+=("$name")
    done < <(ls -1 /sys/class/net 2>/dev/null || true)
  else
    # space-separated list
    read -r -a ret <<<"$IFACES"
  fi
  printf '%s\n' "${ret[@]}" | awk 'NF' | sort -u
}

iface_up() {
  local ifc="$1"
  local state_file="/sys/class/net/${ifc}/operstate"
  [[ -r "$state_file" ]] || { echo 0; return; }
  local st; st="$(cat "$state_file" 2>/dev/null || echo "down")"
  [[ "$st" == "up" ]] && echo 1 || echo 0
}

read_stat() {
  # $1=iface $2=rx|tx
  local file="/sys/class/net/$1/statistics/${2}_bytes"
  [[ -r "$file" ]] && cat "$file" || echo 0
}

write_metrics_once() {
  local tmp="${METRICS_PATH}.tmp"
  : > "$tmp"

  printf '# HELP traffic_rx_bytes_total Total received bytes per interface.\n' >>"$tmp"
  printf '# TYPE traffic_rx_bytes_total counter\n' >>"$tmp"
  printf '# HELP traffic_tx_bytes_total Total transmitted bytes per interface.\n' >>"$tmp"
  printf '# TYPE traffic_tx_bytes_total counter\n' >>"$tmp"
  printf '# HELP traffic_iface_up Interface link state (1=up, 0=down).\n' >>"$tmp"
  printf '# TYPE traffic_iface_up gauge\n' >>"$tmp"

  local ifaces; ifaces=($(list_ifaces))
  for ifc in "${ifaces[@]}"; do
    local rx tx up
    rx="$(read_stat "$ifc" rx)"
    tx="$(read_stat "$ifc" tx)"
    up="$(iface_up "$ifc")"
    # Labels: instance & iface
    printf 'traffic_rx_bytes_total{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$rx" >>"$tmp"
    printf 'traffic_tx_bytes_total{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$tx" >>"$tmp"
    printf 'traffic_iface_up{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$up" >>"$tmp"
  done

  # Atomic move
  mv -f "$tmp" "$METRICS_PATH"
}

push_metrics() {
  local url="${PG_URL%/}/metrics/job/${JOB_NAME}/instance/${INSTANCE}"
  # Pushgateway expects PUT or POST; we use PUT to replace group
  local code
  code="$(curl -sS -m "${CURL_TIMEOUT}" -o /dev/stderr -w '%{http_code}' \
    -X PUT --data-binary @"${METRICS_PATH}" "${url}" || true)"
  if [[ "$code" != "200" && "$code" != "202" ]]; then
    log error "Pushgateway returned HTTP $code for ${url}"
  else
    log debug "Pushed OK to ${url}"
  fi
}

main_loop() {
  ensure_dirs
  log info "Agent started (JOB=${JOB_NAME}, INSTANCE=${INSTANCE}, PG=${PG_URL}, INTERVAL=${PUSH_INTERVAL}, IFACES=${IFACES})"
  while true; do
    write_metrics_once
    push_metrics
    sleep "${PUSH_INTERVAL}"
  done
}

main_loop
EOS
  chmod 0755 "$AGENT_BIN"
}

write_service_unit() {
  cat >"$SERVICE_FILE" <<EOF
# $SERVICE_FILE
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
EnvironmentFile=-$ENV_FILE
ExecStart=/opt/trafficcop-agent/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
}

install_or_overwrite() {
  log "Installing (fresh) ..."
  stop_disable_service || true
  remove_old_cron || true
  remove_files || true   # ensure full wipe
  ensure_dirs
  write_env_file
  write_agent_script
  write_service_unit
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME"
  systemctl start "$UNIT_NAME"
  sleep 2
  systemctl --no-pager --full status "$UNIT_NAME" || true
}

self_check() {
  local cfg; cfg="$(read_env_effective)"
  local PG_URL JOB INSTANCE
  PG_URL="$(echo "$cfg" | cut -d'|' -f1)"
  JOB="$(echo "$cfg" | cut -d'|' -f2)"
  INSTANCE="$(echo "$cfg" | cut -d'|' -f3)"

  log "Self-check: querying ${PG_URL}/metrics for '^traffic_' (job=${JOB}, instance=${INSTANCE}) ..."
  # 优先只看该 job/instance 的 endpoint，减少干扰
  curl -fsS "${PG_URL%/}/metrics" | grep -E '^traffic_' | head -n 20 || {
    log "No '^traffic_' lines found yet. The service may need a few seconds. Tail journal:"
    journalctl -u "$UNIT_NAME" -n 30 --no-pager || true
  }
}

uninstall_all() {
  log "Uninstalling ..."
  stop_disable_service || true
  remove_old_cron || true
  remove_files || true
  log "Uninstalled. To remove metrics from Pushgateway, run with --clear-pg."
}

# ===== Main =====
need_root

EXISTING="$(detect_existing)"

ACTION=""
if [[ "$FLAG_UNINSTALL" == "true" ]]; then
  ACTION="U"
elif [[ "$FLAG_OVERWRITE" == "true" ]]; then
  ACTION="O"
elif [[ "$FLAG_KEEP" == "true" ]]; then
  ACTION="K"
fi

if [[ -z "$ACTION" ]]; then
  if [[ "$EXISTING" == "true" ]]; then
    echo "Detected existing TrafficCop agent on this host."
    echo "[O]verwrite (fresh install)  [K]eep (do nothing)  [U]ninstall"
    read -r -p "Choose action [O/K/U]: " ans || true
    case "${ans^^}" in
      O) ACTION="O" ;;
      K) ACTION="K" ;;
      U) ACTION="U" ;;
      *) echo "No valid choice, abort."; exit 1;;
    esac
  else
    ACTION="O"
  fi
fi

case "$ACTION" in
  O)
    install_or_overwrite
    if [[ "$FLAG_CLEAR_PG" == "true" ]]; then
      clear_pushgateway || true
    fi
    self_check
    ;;
  K)
    log "Keep selected. No changes made."
    if [[ "$FLAG_CLEAR_PG" == "true" ]]; then
      clear_pushgateway || true
    fi
    ;;
  U)
    uninstall_all
    if [[ "$FLAG_CLEAR_PG" == "true" ]]; then
      clear_pushgateway || true
    fi
    ;;
  *)
    die "Unknown action."
    ;;
esac

log "Done."
