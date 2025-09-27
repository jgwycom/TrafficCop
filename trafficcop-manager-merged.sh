# AGENT_VERSION=3.1-final
#!/usr/bin/env bash
set -Eeuo pipefail

# ===== Default config =====
DEFAULT_PG_URL="${PG_URL:-http://127.0.0.1:9091}"
DEFAULT_JOB="trafficcop"
DEFAULT_INTERVAL="10"
DEFAULT_DIR="/opt/trafficcop-agent"
DEFAULT_RUN="/run/trafficcop"
DEFAULT_METRICS="${DEFAULT_RUN}/metrics.prom"
ENV_FILE="/etc/trafficcop-agent.env"
SERVICE_FILE="/etc/systemd/system/trafficcop-agent.service"
UNIT="trafficcop-agent.service"

# ===== Helpers =====
log(){ echo "[$(date +'%F %T')] $*"; }
die(){ echo "❌ ERROR: $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "必须用 root 执行"; }

stop_service(){ systemctl stop $UNIT 2>/dev/null || true; systemctl disable $UNIT 2>/dev/null || true; }
remove_old(){ rm -rf "$DEFAULT_DIR" "$ENV_FILE" "$SERVICE_FILE" "$DEFAULT_RUN"; systemctl daemon-reload || true; }

# URL encode
raw_urlencode(){ local s="$1" out=""; local i c; for ((i=0;i<${#s};i++)); do c="${s:i:1}"; case "$c" in [a-zA-Z0-9._~-]) out+="$c";; *) printf -v out '%s%%%02X' "$out" "'$c";; esac; done; echo "$out"; }

# 清空整个 job
clear_pg_job(){
  log "清空 Pushgateway job=$DEFAULT_JOB ..."
  local JENC; JENC="$(raw_urlencode "$DEFAULT_JOB")"
  curl -s -X DELETE "${DEFAULT_PG_URL%/}/metrics/job/${JENC}" || true
}

# 清理 node-01 残余
clear_residual_node01(){
  if curl -s "${DEFAULT_PG_URL%/}/metrics" | grep -q 'instance="node-01"'; then
    log "⚠️ 检测到残余节点 node-01，尝试清理 ..."
    local JENC; JENC="$(raw_urlencode "$DEFAULT_JOB")"
    curl -s -X DELETE "${DEFAULT_PG_URL%/}/metrics/job/${JENC}/instance/node-01" || true
    sleep 1
    if curl -s "${DEFAULT_PG_URL%/}/metrics" | grep -q 'instance="node-01"'; then
      log "❌ 残余节点 node-01 仍存在，请检查是否有旧 agent 在运行"
      exit 1
    else
      log "✅ 残余节点 node-01 已清理"
    fi
  fi
}

ask_instance(){
  local ans=""
  while true; do
    echo "=============================="
    echo "请输入当前节点的唯一标识 INSTANCE"
    echo "⚠️ 必须全局唯一，只允许字母、数字、点、横杠、下划线"
    echo "示例：node-01, db_02, proxy-kr.03"
    echo "=============================="
    read -r -p "INSTANCE 名称: " ans
    if [[ -z "$ans" ]]; then echo "❌ 不允许为空"; continue; fi
    if [[ ! "$ans" =~ ^[A-Za-z0-9._-]+$ ]]; then echo "❌ 仅允许 [A-Za-z0-9._-]"; continue; fi
    break
  done
  INSTANCE="$ans"
}

write_env(){
  cat >"$ENV_FILE" <<EOF
PG_URL="${DEFAULT_PG_URL}"
JOB="${DEFAULT_JOB}"
INSTANCE="${INSTANCE}"
INTERVAL="${DEFAULT_INTERVAL}"
RUN_DIR="${DEFAULT_RUN}"
METRICS="${DEFAULT_METRICS}"
EOF
}

write_agent(){
  install -d -m 755 "$DEFAULT_DIR" "$DEFAULT_RUN"
  cat >"$DEFAULT_DIR/agent.sh" <<'EOS'
#!/usr/bin/env bash
# AGENT_VERSION=3.1-final
set -Eeuo pipefail
. /etc/trafficcop-agent.env

log(){ echo "[$(date +'%F %T')] [$1] ${*:2}"; }
iface_up(){ [[ "$(cat /sys/class/net/$1/operstate 2>/dev/null || echo down)" == "up" ]] && echo 1 || echo 0; }
read_stat(){ cat "/sys/class/net/$1/statistics/${2}_bytes" 2>/dev/null || echo 0; }

list_ifaces(){
  local ret=()
  local def; def="$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}')"
  [[ -n "$def" ]] && ret+=("$def")
  while IFS= read -r name; do [[ "$name" != "lo" ]] && ret+=("$name"); done < <(ip -o link show up | awk -F': ' '{print $2}')
  printf '%s\n' "${ret[@]}" | sort -u
}

write_metrics(){
  local tmp="${METRICS}.tmp"; : >"$tmp"
  echo "# HELP traffic_rx_bytes_total Total received bytes." >>"$tmp"
  echo "# HELP traffic_tx_bytes_total Total transmitted bytes." >>"$tmp"
  echo "# HELP traffic_iface_up Interface state (1=up,0=down)." >>"$tmp"
  for ifc in $(list_ifaces); do
    rx="$(read_stat "$ifc" rx)"; tx="$(read_stat "$ifc" tx)"; up="$(iface_up "$ifc")"
    echo "traffic_rx_bytes_total{iface=\"$ifc\"} $rx" >>"$tmp"
    echo "traffic_tx_bytes_total{iface=\"$ifc\"} $tx" >>"$tmp"
    echo "traffic_iface_up{iface=\"$ifc\"} $up" >>"$tmp"
  done
  mv -f "$tmp" "$METRICS"
}

push_metrics(){
  local JENC; JENC="$(raw_urlencode "$JOB")"
  local IENC; IENC="$(raw_urlencode "$INSTANCE")"
  local url="${PG_URL%/}/metrics/job/${JENC}/instance/${IENC}"
  local code
  code="$(curl -sS -m 5 -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: text/plain; version=0.0.4' \
    -X PUT --data-binary @"${METRICS}" "$url" || true)"
  if [[ "$code" != "202" && "$code" != "200" ]]; then
    log error "Pushgateway 返回 HTTP $code"
  fi
}

main(){
  log info "Agent started (INSTANCE=$INSTANCE, PG=$PG_URL, JOB=$JOB)"
  while true; do write_metrics; push_metrics; sleep "$INTERVAL"; done
}
main
EOS
  chmod 0755 "$DEFAULT_DIR/agent.sh"
}

write_service(){
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TrafficCop Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$DEFAULT_DIR/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
}

self_check(){
  log "自检：检查 Pushgateway 是否有 INSTANCE=$INSTANCE"
  sleep 2
  if curl -s "${DEFAULT_PG_URL%/}/metrics" | grep -q "instance=\"$INSTANCE\""; then
    log "✅ 已找到 instance=$INSTANCE"
  else
    log "⚠️ 未找到 instance=$INSTANCE，请检查 agent 日志 (journalctl -u $UNIT)"
  fi

  if curl -s "${DEFAULT_PG_URL%/}/metrics" | grep -q "instance=\"node-01\""; then
    log "⚠️ 注意：Pushgateway 仍然残留 node-01"
    log "👉 这会导致 Grafana 下拉框里还有 node-01，即使节点已不存在"
    log "👉 解决方法：清理 Prometheus TSDB 数据目录 或 改用新 job 名字"
  fi
}

install_all(){
  stop_service
  remove_old
  clear_pg_job
  clear_residual_node01
  ask_instance
  write_env
  write_agent
  write_service
  systemctl daemon-reload
  systemctl enable $UNIT
  systemctl start $UNIT
  self_check
}

# ===== Main =====
need_root
install_all
log "Done. INSTANCE=$INSTANCE 安装完成。"
