#!/usr/bin/env bash
# AGENT_VERSION=2.5-final
set -Eeuo pipefail

log() { echo "[$(date '+%F %T')] $*"; }

ENV_FILE="/etc/trafficcop-agent.env"
AGENT_DIR="/opt/trafficcop-agent"
METRICS_DIR="/run/trafficcop"
SERVICE_FILE="/etc/systemd/system/trafficcop-agent.service"
OLD_CONF="/root/TrafficCop/traffic_monitor_config.txt"
NODE_ID_FILE="/etc/trafficcop-nodeid"

#------------------------------
# 清理指定 instance
#------------------------------
pg_delete_instance() {
  local pg_url="$1" job="$2" inst="$3"
  curl -s -X DELETE "${pg_url}/metrics/job/${job}/instance/${inst}" >/dev/null || true
}

#------------------------------
# 全量清理 job 残余
#------------------------------
pg_cleanup_all() {
  local pg_url="$1" job="$2"
  log "检测并清理 $job 下的残余 instance ..."
  INSTANCES=$(curl -s "$pg_url/metrics" | grep "job=\"$job\"" | sed -n 's/.*instance=\"\([^\"]*\)\".*/\1/p' | sort -u || true)
  if [[ -z "$INSTANCES" ]]; then
    log "未发现残余 instance"
    return
  fi
  for inst in $INSTANCES; do
    if [[ "$inst" != "$INSTANCE" ]]; then
      log "清理旧残余 instance=$inst"
      curl -s -X DELETE "$pg_url/metrics/job/$job/instance/$inst" >/dev/null || true
    fi
  done
}

#------------------------------
# 迁移助手
#------------------------------
RESET_DAY_DEFAULT="1"
LIMIT_BYTES_DEFAULT="0"
if [[ -f "$OLD_CONF" ]]; then
  log "检测到旧版配置 $OLD_CONF，尝试读取 ..."
  RESET_DAY_DEFAULT=$(grep -E '^RESET_DAY=' "$OLD_CONF" | cut -d= -f2 || echo "1")
  LIMIT_BYTES_DEFAULT=$(grep -E '^LIMIT_BYTES=' "$OLD_CONF" | cut -d= -f2 || echo "0")
  log "迁移默认值: RESET_DAY=$RESET_DAY_DEFAULT, LIMIT_BYTES=$LIMIT_BYTES_DEFAULT"
fi

#------------------------------
# 交互输入
#------------------------------
echo "=============================="
echo "请输入当前节点的唯一标识 INSTANCE"
echo "⚠️ 必须唯一，仅允许字母/数字/点/横杠/下划线"
echo "示例：node-01, db_02, proxy-kr.03"
echo "=============================="
while true; do
  read -rp "INSTANCE: " INSTANCE
  if [[ "$INSTANCE" =~ ^[A-Za-z0-9._-]+$ ]]; then break; fi
  echo "❌ 无效的 INSTANCE，请重新输入"
done
read -rp "显示名称 (可选，默认=$INSTANCE): " DISPLAY_NAME_INPUT
DISPLAY_NAME="${DISPLAY_NAME_INPUT:-$INSTANCE}"

# PG_URL 优先取环境变量
if [[ -n "${PG_URL:-}" ]]; then
  PG_URL_INPUT="$PG_URL"
else
  read -rp "Pushgateway 地址 (必填): " PG_URL_INPUT
  [[ -z "$PG_URL_INPUT" ]] && { echo "❌ PG_URL 不能为空"; exit 1; }
fi

read -rp "Job 名称 [默认 trafficcop]: " JOB_INPUT
JOB="${JOB_INPUT:-trafficcop}"

read -rp "推送间隔秒 [默认 10]: " INTERVAL_INPUT
INTERVAL="${INTERVAL_INPUT:-10}"

read -rp "每月重置日 (1-28) [默认 $RESET_DAY_DEFAULT]: " RESET_DAY_INPUT
RESET_DAY="${RESET_DAY_INPUT:-$RESET_DAY_DEFAULT}"

read -rp "流量配额 (GiB, 0=不限) [默认 $LIMIT_BYTES_DEFAULT]: " LIMIT_INPUT
LIMIT_BYTES=$(awk "BEGIN {print (${LIMIT_INPUT:-$LIMIT_BYTES_DEFAULT} * 1024 * 1024 * 1024)}")

#------------------------------
# 自动推导 PANEL_API（由 PG_URL 的主机拼成 18000 端口）
#------------------------------
PANEL_HOST=$(echo "$PG_URL_INPUT" | sed -E 's#^https?://([^:/]+).*#\1#')
PANEL_API="http://${PANEL_HOST}:18000"
log "自动推导 PANEL_API=$PANEL_API"

#------------------------------
# 唯一 NODE_ID 处理（由面板分配，自增、终身不变）
#------------------------------
if [[ -f "$NODE_ID_FILE" ]]; then
  NODE_ID=$(cat "$NODE_ID_FILE")
  log "检测到已有 NODE_ID=$NODE_ID"
  # 无论是否重装/改名，都把当前 INSTANCE / display_name 与该 NODE_ID 对齐
  curl -s -X PATCH "$PANEL_API/nodes/$NODE_ID" \
    -H "Content-Type: application/json" \
    -d "{\"instance\":\"$INSTANCE\",\"display_name\":\"$DISPLAY_NAME\"}" >/dev/null || true
else
  log "向面板机申请新的 NODE_ID..."
  # 注册节点，要求面板返回 JSON 中包含 "id": <number>
  CREATE_RESP=$(curl -sS -X POST "$PANEL_API/nodes" \
    -H "Content-Type: application/json" \
    -d "{\"instance\":\"$INSTANCE\",\"display_name\":\"$DISPLAY_NAME\",\"sort_order\":0,\"reset_day\":$RESET_DAY,\"limit_bytes\":$LIMIT_BYTES,\"limit_mode\":\"double\",\"bandwidth_bps\":0}" || true)

  # 用 grep/sed 提取 id 数字，避免依赖 jq
  NODE_ID=$(printf '%s' "$CREATE_RESP" | tr -d '\n' | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+')
if [[ -z "$NODE_ID" ]]; then
  log "⚠️ 面板返回无效，临时设置 NODE_ID=0"
  NODE_ID=0
fi
  echo "$NODE_ID" > "$NODE_ID_FILE"
  log "已分配 NODE_ID=$NODE_ID"
fi

#------------------------------
# 网卡选择
#------------------------------
AVAILABLE_IFACES=$(ls /sys/class/net | grep -Ev '^(lo|docker.*|veth.*)$')
DEFAULT_IFACE=""
if echo "$AVAILABLE_IFACES" | grep -qw "eth0"; then
  DEFAULT_IFACE="eth0"
else
  DEFAULT_IFACE=$(echo "$AVAILABLE_IFACES" | head -n1)
fi

echo "=============================="
echo "检测到以下网络接口:"
echo "$AVAILABLE_IFACES"
echo "请输入需要监控的接口（可输入多个，以空格分隔）"
echo "直接回车则默认使用: $DEFAULT_IFACE"
echo "=============================="
read -rp "IFACES: " IFACES_INPUT
IFACES="${IFACES_INPUT:-$DEFAULT_IFACE}"

#------------------------------
# 清理 PG 残余（不带 node_id 的路径）
#------------------------------
log "清理 Pushgateway 残余 (instance=$INSTANCE)"
pg_delete_instance "$PG_URL_INPUT" "$JOB" "$INSTANCE"
# 追加：清理带 node_id 的路径（防止历史残留）
curl -s -X DELETE "$PG_URL_INPUT/metrics/job/$JOB/instance/$INSTANCE/node_id/$NODE_ID" >/dev/null || true

#------------------------------
# 写配置文件
#------------------------------
install -d -m 755 "$AGENT_DIR" "$METRICS_DIR"
cat >"$ENV_FILE" <<EOF
PG_URL=$PG_URL_INPUT
JOB=$JOB
INSTANCE=$INSTANCE
INTERVAL=$INTERVAL
IFACES="$IFACES"
RESET_DAY=$RESET_DAY
LIMIT_BYTES=$LIMIT_BYTES
NODE_ID=$NODE_ID
EOF
log "已写入配置 $ENV_FILE"

#------------------------------
# 写 agent.sh
#------------------------------
cat >"$AGENT_DIR/agent.sh" <<'EOS'
#!/usr/bin/env bash
set -Eeuo pipefail
source /etc/trafficcop-agent.env
METRICS_DIR="/run/trafficcop"

while true; do
  : >"$METRICS_DIR/metrics.prom"
  {
    echo "# HELP traffic_rx_bytes_total Total received bytes."
    echo "# TYPE traffic_rx_bytes_total untyped"
    echo "# HELP traffic_tx_bytes_total Total transmitted bytes."
    echo "# TYPE traffic_tx_bytes_total untyped"
    echo "# HELP traffic_iface_up Interface state."
    echo "# TYPE traffic_iface_up untyped"
    echo "# HELP node_id 永久节点ID"
    echo "# TYPE node_id gauge"
  } >"$METRICS_DIR/metrics.prom"

  for IF in $IFACES; do
    RX=$(cat /sys/class/net/$IF/statistics/rx_bytes 2>/dev/null || echo 0)
    TX=$(cat /sys/class/net/$IF/statistics/tx_bytes 2>/dev/null || echo 0)
    STATE=$(cat /sys/class/net/$IF/operstate 2>/dev/null | grep -q up && echo 1 || echo 0)
    echo "traffic_rx_bytes_total{iface=\"$IF\"} $RX" >>"$METRICS_DIR/metrics.prom"
    echo "traffic_tx_bytes_total{iface=\"$IF\"} $TX" >>"$METRICS_DIR/metrics.prom"
    echo "traffic_iface_up{iface=\"$IF\"} $STATE" >>"$METRICS_DIR/metrics.prom"
  done

  # 作为独立指标保留（不删原逻辑）
  echo "node_id $NODE_ID" >>"$METRICS_DIR/metrics.prom"

  # Push 到带 node_id 分组标签的路径，所有指标会带上 label node_id="<数字>"
  curl -s -X PUT --data-binary @"$METRICS_DIR/metrics.prom" \
    "$PG_URL/metrics/job/$JOB/node_id/$NODE_ID/instance/$INSTANCE" || true

  sleep "$INTERVAL"
done
EOS
chmod +x "$AGENT_DIR/agent.sh"
log "已写入 $AGENT_DIR/agent.sh"

#------------------------------
# 写 systemd unit
#------------------------------
cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$AGENT_DIR/agent.sh
Restart=always
RestartSec=5
EnvironmentFile=$ENV_FILE

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now trafficcop-agent
log "已写入 systemd 单元 $SERVICE_FILE 并启动服务"

#------------------------------
# 自检 + 残余清理
#------------------------------
sleep 3
if curl -s "$PG_URL_INPUT/metrics" | grep -q "instance=\"$INSTANCE\"" && \
   curl -s "$PG_URL_INPUT/metrics" | grep -q "node_id=\"$NODE_ID\""; then
    log "✅ 自检成功: $INSTANCE 已在 Pushgateway 注册 (node_id=$NODE_ID)"
else
    log "⚠️ 未检测到 $INSTANCE (node_id=$NODE_ID)，请检查 agent 日志"
fi

