# AGENT_VERSION=2.2-stable
#!/usr/bin/env bash
set -Eeuo pipefail

### ================================
### 常量与默认值
### ================================
UNIT_NAME="trafficcop-agent.service"
SERVICE_FILE="/etc/systemd/system/${UNIT_NAME}"
ENV_FILE="/etc/trafficcop-agent.env"
AGENT_DIR="/opt/trafficcop-agent"
RUN_DIR="/run/trafficcop"
METRICS_FILE="${RUN_DIR}/metrics.prom"

JOB_DEFAULT="trafficcop"
INTERVAL_DEFAULT="10"
IFACES_DEFAULT="AUTO"
RESET_DAY_DEFAULT="1"
LIMIT_BYTES_DEFAULT="0"

YES_ALL="${YES_ALL:-0}"
NUKE_PG="${NUKE_PG:-0}"

### ================================
### 工具函数
### ================================
log(){ echo "[$(date +'%F %T')] $*"; }
die(){ echo "❌ $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "需要 root 权限运行"; }

urlenc(){
  local s="$1" o="" c
  for ((i=0;i<${#s};i++)); do
    c="${s:i:1}"
    case "$c" in [a-zA-Z0-9._~-]) o+="$c";; *) printf -v o '%s%%%02X' "$o" "'$c";; esac
  done
  echo "$o"
}

yn(){
  local prompt="$1" d="${2:-N}"
  [[ "$YES_ALL" = "1" ]] && { echo "y"; return; }
  read -r -p "$prompt [y/N]: " ans || true
  ans="${ans:-$d}"
  [[ "$ans" =~ ^[Yy]$ ]] && echo "y" || echo "n"
}

pg_delete_instance(){
  local pg="$1" job="$2" inst="$3"
  curl -s -X DELETE "${pg%/}/metrics/job/$(urlenc "$job")/instance/$(urlenc "$inst")" >/dev/null || true
}
pg_delete_job(){
  local pg="$1" job="$2"
  curl -s -X DELETE "${pg%/}/metrics/job/$(urlenc "$job")" >/dev/null || true
}

### ================================
### 迁移助手：读取旧版配置
### ================================
load_old_config(){
  local cfg="/root/TrafficCop/traffic_monitor_config.txt"
  if [[ -f "$cfg" ]]; then
    log "检测到旧版配置 $cfg，尝试读取 ..."
    local rd lb
    rd="$(grep -E '^RESET_DAY=' "$cfg" | cut -d= -f2 || true)"
    lb="$(grep -E '^LIMIT_BYTES=' "$cfg" | cut -d= -f2 || true)"
    [[ -n "$rd" ]] && RESET_DAY_DEFAULT="$rd"
    [[ -n "$lb" ]] && LIMIT_BYTES_DEFAULT="$lb"
    log "迁移默认值: RESET_DAY=$RESET_DAY_DEFAULT, LIMIT_BYTES=$LIMIT_BYTES_DEFAULT"
  fi
}

### ================================
### 交互输入
### ================================
ask_instance(){
  local v=""
  while true; do
    echo "=============================="
    echo "请输入当前节点的唯一标识 INSTANCE"
    echo "⚠️ 必须唯一，仅允许字母/数字/点/横杠/下划线"
    echo "示例：node-01, db_02, proxy-kr.03"
    echo "=============================="
    read -r -p "INSTANCE: " v || true
    [[ -z "$v" ]] && { echo "❌ 不允许为空"; continue; }
    [[ ! "$v" =~ ^[A-Za-z0-9._-]+$ ]] && { echo "❌ 仅允许 [A-Za-z0-9._-]"; continue; }
    break
  done
  INSTANCE="$v"
}

ask_pg_url_job_interval(){
  local p j itf
  read -r -p "Pushgateway 地址 (必填): " p || true
  [[ -z "$p" ]] && die "必须提供 Pushgateway 地址，例如 http://123.45.678.90:19091"
  PG_URL="$p"

  read -r -p "Job 名称 [默认 $JOB_DEFAULT]: " j || true
  JOB="${j:-$JOB_DEFAULT}"

  read -r -p "推送间隔秒 [默认 $INTERVAL_DEFAULT]: " itf || true
  [[ "$itf" =~ ^[0-9]+$ ]] || itf="$INTERVAL_DEFAULT"
  INTERVAL="$itf"

  IFACES="$IFACES_DEFAULT"
}

ask_reset_day_and_limit(){
  read -r -p "每月重置日 (1-28) [默认 $RESET_DAY_DEFAULT]: " RESET_DAY || true
  RESET_DAY="${RESET_DAY:-$RESET_DAY_DEFAULT}"
  [[ "$RESET_DAY" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || RESET_DAY="$RESET_DAY_DEFAULT"

  read -r -p "流量配额 (GiB, 0=不限) [默认 0]: " giB || true
  giB="${giB:-0}"
  if [[ "$giB" =~ ^[0-9]+$ ]] && [[ "$giB" -gt 0 ]]; then
    LIMIT_BYTES="$(( giB * 1024 * 1024 * 1024 ))"
  else
    LIMIT_BYTES="$LIMIT_BYTES_DEFAULT"
  fi
}

### ================================
### 写配置 / agent / systemd
### ================================
write_env(){
  cat >"$ENV_FILE" <<EOF
# AGENT_VERSION=2.2-stable
PG_URL="$PG_URL"
JOB="$JOB"
INSTANCE="$INSTANCE"
INTERVAL="$INTERVAL"
IFACES="$IFACES"
RUN_DIR="$RUN_DIR"
METRICS_FILE="$METRICS_FILE"
RESET_DAY="$RESET_DAY"
LIMIT_BYTES="$LIMIT_BYTES"
EOF
  chmod 644 "$ENV_FILE"
  log "已写入配置 $ENV_FILE"
}

write_agent(){
  install -d -m 755 "$AGENT_DIR" "$RUN_DIR"
  cat >"$AGENT_DIR/agent.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/trafficcop-agent.env

log(){ echo "[$(date +'%F %T')] [$1] ${*:2}"; }

iface_up(){ [[ "$(cat /sys/class/net/$1/operstate 2>/dev/null || echo down)" == "up" ]] && echo 1 || echo 0; }
read_stat(){ cat "/sys/class/net/$1/statistics/${2}_bytes" 2>/dev/null || echo 0; }

list_ifaces(){
  local def ret=()
  def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  [[ -n "$def" ]] && ret+=("$def")
  while IFS= read -r n; do [[ "$n" != "lo" ]] && ret+=("$n"); done < <(ip -o link show up | awk -F': ' '{print $2}')
  printf '%s\n' "${ret[@]}" | sort -u
}

write_metrics(){
  local tmp="${METRICS_FILE}.tmp"; : >"$tmp"
  echo "# HELP traffic_rx_bytes_total Total received bytes." >>"$tmp"
  echo "# TYPE traffic_rx_bytes_total counter" >>"$tmp"
  echo "# HELP traffic_tx_bytes_total Total transmitted bytes." >>"$tmp"
  echo "# TYPE traffic_tx_bytes_total counter" >>"$tmp"
  echo "# HELP traffic_iface_up Interface state." >>"$tmp"
  echo "# TYPE traffic_iface_up gauge" >>"$tmp"

  local cards=()
  if [[ "$IFACES" == "AUTO" ]]; then mapfile -t cards < <(list_ifaces); else IFS=',' read -r -a cards <<<"$IFACES"; fi
  for nic in "${cards[@]}"; do
    echo "traffic_rx_bytes_total{iface=\"$nic\"} $(read_stat "$nic" rx)" >>"$tmp"
    echo "traffic_tx_bytes_total{iface=\"$nic\"} $(read_stat "$nic" tx)" >>"$tmp"
    echo "traffic_iface_up{iface=\"$nic\"} $(iface_up "$nic")" >>"$tmp"
  done
  mv -f "$tmp" "$METRICS_FILE"
}

push_once(){
  local url="${PG_URL%/}/metrics/job/$(printf %s "$JOB" | jq -sRr @uri)/instance/$(printf %s "$INSTANCE" | jq -sRr @uri)"
  curl -s -X PUT -H 'Content-Type: text/plain; version=0.0.4' --data-binary @"$METRICS_FILE" "$url" -o /dev/null || log error "push fail"
}

main(){
  log info "Agent started (INSTANCE=$INSTANCE)"
  while true; do
    write_metrics
    push_once
    sleep "$INTERVAL"
  done
}
main
EOS
  chmod 755 "$AGENT_DIR/agent.sh"
  log "已写入 $AGENT_DIR/agent.sh"
}

write_service(){
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-$ENV_FILE
ExecStart=$AGENT_DIR/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  log "已写入 systemd 单元 $SERVICE_FILE"
}

### ================================
### 主流程
### ================================
main(){
  need_root
  load_old_config
  ask_instance
  ask_pg_url_job_interval
  ask_reset_day_and_limit

  log "清理 Pushgateway 残余 (instance=$INSTANCE)"
  pg_delete_instance "$PG_URL" "$JOB" "$INSTANCE"
  [[ "$NUKE_PG" == "1" ]] && pg_delete_job "$PG_URL" "$JOB"

  write_env
  write_agent
  write_service
  systemctl enable "$UNIT_NAME"
  systemctl restart "$UNIT_NAME"

  sleep 2
  if curl -s "$PG_URL/metrics" | grep -q "instance=\"$INSTANCE\""; then
    log "✅ 新节点 $INSTANCE 已注册到 Pushgateway"
  else
    log "⚠️ 未检测到 $INSTANCE，请检查 agent 日志"
  fi

  if curl -s "$PG_URL/metrics" | grep -q 'instance="node-01"'; then
    log "⚠️ 检测到残余 node-01，建议清理：curl -X DELETE $PG_URL/metrics/job/$JOB/instance/node-01"
  fi
}
main "$@"
