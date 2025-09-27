# AGENT_VERSION=2.1-stable
#!/usr/bin/env bash
# trafficcop-manager-merged.sh
# Robust installer/manager for TrafficCop Pushgateway Agent
# 强制 INSTANCE 交互输入 + 自动清理 + agent.sh 编码修复

set -Eeuo pipefail

# ===== Default Configs =====
DEFAULT_PG_URL="${PG_URL:-http://127.0.0.1:9091}"
DEFAULT_JOB_NAME="trafficcop"
DEFAULT_PUSH_INTERVAL="10"
DEFAULT_CURL_TIMEOUT="5"
DEFAULT_IFACES="AUTO"
DEFAULT_RUN_DIR="/run/trafficcop"
DEFAULT_METRICS_PATH="${DEFAULT_RUN_DIR}/metrics.prom"
DEFAULT_LOG_LEVEL="info"

# ===== Paths =====
AGENT_DIR="/opt/trafficcop-agent"
AGENT_BIN="${AGENT_DIR}/agent.sh"
ENV_FILE="/etc/trafficcop-agent.env"
SERVICE_FILE="/etc/systemd/system/trafficcop-agent.service"
CRON_FILE="/etc/cron.d/trafficcop-agent"
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

Actions:
  --overwrite     Fresh reinstall (wipe old, then install)
  --keep          Keep current installation (no changes)
  --uninstall     Uninstall everything (service, files)
Optional:
  --clear-pg      Also clear Pushgateway metrics for this instance (or whole job if confirmed)
  -y, --yes       Assume "yes" to prompts (non-interactive)
HLP
      exit 0;;
    *) echo "Unknown option: $1"; exit 2;;
  esac
done

# ===== Helpers =====
log() { echo "[$(date +'%F %T')] $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }
need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Please run as root (sudo -i)."; }

svc_is_installed() { [[ -f "$SERVICE_FILE" ]] || systemctl list-unit-files | grep -q "^trafficcop-agent\.service"; }
ensure_dirs() { install -d -m 755 "$AGENT_DIR" "$DEFAULT_RUN_DIR"; }

stop_disable_service() { systemctl stop "$UNIT_NAME" 2>/dev/null || true; systemctl disable "$UNIT_NAME" 2>/dev/null || true; }
remove_old_cron() { rm -f "$CRON_FILE" 2>/dev/null || true; }
remove_files() { rm -f "$SERVICE_FILE" "$ENV_FILE" || true; rm -rf "$AGENT_DIR" || true; systemctl daemon-reload || true; }

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
  if [[ "$FLAG_YES" == "true" ]]; then return 0; fi
  read -r -p "$prompt [y/N]: " ans || true
  [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]]
}

read_env_effective() {
  if [[ -f "$ENV_FILE" ]]; then
    . "$ENV_FILE"
    echo "${PG_URL}|${JOB_NAME}|${INSTANCE}"
  else
    echo "${DEFAULT_PG_URL}|${DEFAULT_JOB_NAME}|UNKNOWN"
  fi
}

clear_pushgateway() {
  local cfg; cfg="$(read_env_effective)"
  local PG_URL JOB INSTANCE
  PG_URL="$(echo "$cfg" | cut -d'|' -f1)"
  JOB="$(echo "$cfg" | cut -d'|' -f2)"
  INSTANCE="$(echo "$cfg" | cut -d'|' -f3)"

  log "Clearing Pushgateway (job=${JOB}, instance=${INSTANCE}) at ${PG_URL}"
  curl -fsS -X DELETE "${PG_URL%/}/metrics/job/${JOB}/instance/${INSTANCE}" || true
  curl -fsS -X DELETE "${PG_URL%/}/metrics/job/${JOB}" || true
}

# ===== Ask INSTANCE (with validation) =====
ask_instance_name() {
  local ans=""
  while true; do
    echo "=============================="
    echo "请输入当前节点的唯一标识 INSTANCE"
    echo "⚠️ 必须全局唯一，只允许字母、数字、点、横杠、下划线"
    echo "示例：node-01, db_02, proxy-kr.03"
    echo "=============================="
    read -r -p "INSTANCE 名称: " ans
    if [[ -z "$ans" ]]; then
      echo "❌ INSTANCE 不能为空，请重新输入！"
      continue
    fi
    if [[ ! "$ans" =~ ^[A-Za-z0-9._-]+$ ]]; then
      echo "❌ INSTANCE 只能包含 [A-Za-z0-9._-]，请重新输入！"
      continue
    fi
    break
  done
  INSTANCE="$ans"
}

write_env_file() {
  cat >"$ENV_FILE" <<EOF
# Environment for trafficcop-agent
PG_URL="${DEFAULT_PG_URL}"
JOB_NAME="${DEFAULT_JOB_NAME}"
INSTANCE="${INSTANCE}"
PUSH_INTERVAL="${DEFAULT_PUSH_INTERVAL}"
CURL_TIMEOUT="${DEFAULT_CURL_TIMEOUT}"
IFACES="${DEFAULT_IFACES}"
RUN_DIR="${DEFAULT_RUN_DIR}"
METRICS_PATH="${DEFAULT_METRICS_PATH}"
LOG_LEVEL="${DEFAULT_LOG_LEVEL}"
EOF
  chmod 0644 "$ENV_FILE"
}

write_agent_script() {
  cat >"$AGENT_BIN" <<'EOS'
#!/usr/bin/env bash
# AGENT_VERSION=2.1-stable
# /opt/trafficcop-agent/agent.sh
set -Eeuo pipefail

ENV_FILE="/etc/trafficcop-agent.env"
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"

PG_URL="${PG_URL:?PG_URL must be set in /etc/trafficcop-agent.env}"
JOB_NAME="${JOB_NAME:-trafficcop}"
INSTANCE="${INSTANCE:?INSTANCE must be set in /etc/trafficcop-agent.env}"
PUSH_INTERVAL="${PUSH_INTERVAL:-10}"
CURL_TIMEOUT="${CURL_TIMEOUT:-5}"
IFACES="${IFACES:-AUTO}"
RUN_DIR="${RUN_DIR:-/run/trafficcop}"
METRICS_PATH="${METRICS_PATH:-${RUN_DIR}/metrics.prom}"
LOG_LEVEL="${LOG_LEVEL:-info}"

log() {
  local lvl="$1"; shift
  echo "[$(date +'%F %T')] [$lvl] $*"
}

ensure_dirs() { install -d -m 755 "$RUN_DIR"; }
iface_up() { [[ "$(cat /sys/class/net/$1/operstate 2>/dev/null || echo down)" == "up" ]] && echo 1 || echo 0; }
read_stat() { cat "/sys/class/net/$1/statistics/${2}_bytes" 2>/dev/null || echo 0; }

list_ifaces() {
  local ret=()
  if [[ "$IFACES" == "AUTO" ]]; then
    local def; def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
    [[ -n "$def" ]] && ret+=("$def")
    while IFS= read -r name; do [[ "$name" != "lo" ]] && ret+=("$name"); done < <(ip -o link show up | awk -F': ' '{print $2}')
  elif [[ "$IFACES" == "*" ]]; then
    for n in /sys/class/net/*; do [[ "$(basename "$n")" != "lo" ]] && ret+=("$(basename "$n")"); done
  else read -r -a ret <<<"$IFACES"; fi
  printf '%s\n' "${ret[@]}" | sort -u
}

write_metrics_once() {
  local tmp="${METRICS_PATH}.tmp"
  : > "$tmp"

  LC_ALL=C printf '# HELP traffic_rx_bytes_total Total received bytes.\n# TYPE traffic_rx_bytes_total counter\n' >>"$tmp"
  LC_ALL=C printf '# HELP traffic_tx_bytes_total Total transmitted bytes.\n# TYPE traffic_tx_bytes_total counter\n' >>"$tmp"
  LC_ALL=C printf '# HELP traffic_iface_up Interface state (1=up,0=down).\n# TYPE traffic_iface_up gauge\n' >>"$tmp"

  for ifc in $(list_ifaces); do
    rx="$(read_stat "$ifc" rx)"
    tx="$(read_stat "$ifc" tx)"
    up="$(iface_up "$ifc")"
    LC_ALL=C printf 'traffic_rx_bytes_total{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$rx" >>"$tmp"
    LC_ALL=C printf 'traffic_tx_bytes_total{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$tx" >>"$tmp"
    LC_ALL=C printf 'traffic_iface_up{instance="%s",iface="%s"} %s\n' "$INSTANCE" "$ifc" "$up" >>"$tmp"
  done

  mv -f "$tmp" "$METRICS_PATH"
}

push_metrics() {
  local url="${PG_URL%/}/metrics/job/${JOB_NAME}/instance/${INSTANCE}"
  local code
  code="$(curl -sS -m "${CURL_TIMEOUT}" -o /dev/stderr -w '%{http_code}' -X PUT --data-binary @"${METRICS_PATH}" "${url}" || true)"
  [[ "$code" != "200" && "$code" != "202" ]] && log error "Pushgateway returned HTTP $code"
}

main_loop() {
  ensure_dirs
  log info "Agent started (JOB=${JOB_NAME}, INSTANCE=${INSTANCE}, PG=${PG_URL}, INTERVAL=${PUSH_INTERVAL}, IFACES=${IFACES})"
  while true; do write_metrics_once; push_metrics; sleep "${PUSH_INTERVAL}"; done
}

main_loop
EOS
  chmod 0755 "$AGENT_BIN"
}

write_service_unit() {
  cat >"$SERVICE_FILE" <<EOF
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
  ask_instance_name
  stop_disable_service || true
  remove_old_cron || true
  remove_files || true
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
  log "Self-check: querying ${PG_URL}/metrics ..."
  curl -fsS "${PG_URL%/}/metrics" | grep -E '^traffic_' | head -n 20 || true
}

uninstall_all() { log "Uninstalling ..."; stop_disable_service || true; remove_old_cron || true; remove_files || true; }

# ===== Main =====
need_root
EXISTING="$(detect_existing)"
ACTION=""
if [[ "$FLAG_UNINSTALL" == "true" ]]; then ACTION="U"
elif [[ "$FLAG_OVERWRITE" == "true" ]]; then ACTION="O"
elif [[ "$FLAG_KEEP" == "true" ]]; then ACTION="K"; fi

if [[ -z "$ACTION" ]]; then
  if [[ "$EXISTING" == "true" ]]; then
    echo "Detected existing TrafficCop agent."
    echo "[O]verwrite / [K]eep / [U]uninstall"
    read -r -p "Choose action [O/K/U]: " ans || true
    case "${ans^^}" in O) ACTION="O";; K) ACTION="K";; U) ACTION="U";; *) exit 1;; esac
  else ACTION="O"; fi
fi

case "$ACTION" in
  O) install_or_overwrite; [[ "$FLAG_CLEAR_PG" == "true" ]] && clear_pushgateway; self_check;;
  K) log "Keep selected."; [[ "$FLAG_CLEAR_PG" == "true" ]] && clear_pushgateway;;
  U) uninstall_all; [[ "$FLAG_CLEAR_PG" == "true" ]] && clear_pushgateway;;
esac

log "Done."
