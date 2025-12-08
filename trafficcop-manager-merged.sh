# =============================================================================
#                               ① Agent 安装逻辑 (V5 - IP优先版)
# =============================================================================
install_agent() {
  log "开始执行 install_agent 函数 (V5 - IP优先版)"
  
  ENV_FILE="/etc/trafficcop-agent.env"
  AGENT_DIR="/opt/trafficcop-agent"
  METRICS_DIR="/run/trafficcop"
  SERVICE_FILE="/etc/systemd/system/trafficcop-agent.service"
  OLD_CONF="/root/TrafficCop/traffic_monitor_config.txt"
  NODE_ID_FILE="/etc/trafficcop-nodeid"

  #------------------------------
  # 清理函数
  #------------------------------
  pg_delete_instance() {
    local pg_url="$1" job="$2" inst="$3"
    if ! curl -s -X DELETE "${pg_url}/metrics/job/${job}/instance/${inst}" >/dev/null; then
      warn "清理 Pushgateway 残余数据失败: ${pg_url}/metrics/job/${job}/instance/${inst}"
    fi
  }

  #------------------------------
  # 🆕 获取本机公网 IP
  #------------------------------
  get_public_ip() {
    local ip=""
    # 尝试多个公网 IP 查询服务
    for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "api.ipify.org"; do
      ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
      if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
      fi
    done
    # 回退到本地 IP
    ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    echo "$ip"
  }

  #------------------------------
  # 🆕 从面板机查询是否已存在该 IP 的节点
  #------------------------------
  query_node_by_ip() {
    local panel_api="$1"
    local my_ip="$2"
    
    log "正在从面板机查询 IP=$my_ip 是否已注册..."
    
    # 调用面板机的 API 查询
    local resp
    resp=$(curl -sS --connect-timeout 10 "${panel_api}/nodes/query-by-ip?ip=${my_ip}" 2>/dev/null || echo "{}")
    
    # 解析返回的 JSON
    local found_id found_instance found_display_name
    found_id=$(echo "$resp" | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+' || echo "")
    found_instance=$(echo "$resp" | grep -o '"instance":[[:space:]]*"[^"]*"' | head -n1 | sed 's/"instance":[[:space:]]*"\([^"]*\)"/\1/' || echo "")
    found_display_name=$(echo "$resp" | grep -o '"display_name":[[:space:]]*"[^"]*"' | head -n1 | sed 's/"display_name":[[:space:]]*"\([^"]*\)"/\1/' || echo "")
    
    if [[ -n "$found_id" && "$found_id" != "0" ]]; then
      log "✅ 面板机已存在该 IP 的节点记录:"
      log "   NODE_ID=$found_id"
      log "   INSTANCE=$found_instance"
      log "   DISPLAY_NAME=$found_display_name"
      
      # 导出变量供后续使用
      PANEL_NODE_ID="$found_id"
      PANEL_INSTANCE="$found_instance"
      PANEL_DISPLAY_NAME="$found_display_name"
      return 0
    else
      log "ℹ️ 面板机未找到该 IP 的节点记录，将作为新节点注册"
      PANEL_NODE_ID=""
      PANEL_INSTANCE=""
      PANEL_DISPLAY_NAME=""
      return 1
    fi
  }

  #------------------------------
  # 默认值初始化
  #------------------------------
  RESET_DAY_DEFAULT="1"
  LIMIT_BYTES_DEFAULT="0"
  BANDWIDTH_MBPS_DEFAULT="0"
  LIMIT_MODE_DEFAULT="double"
  
  # 初始化面板查询结果变量
  PANEL_NODE_ID=""
  PANEL_INSTANCE=""
  PANEL_DISPLAY_NAME=""

  #------------------------------
  # 🆕 第一步：获取本机公网 IP 并显示
  #------------------------------
  echo ""
  echo "=============================="
  echo "🔍 正在检测本机公网 IP..."
  echo "=============================="
  MY_PUBLIC_IP=$(get_public_ip)
  
  if [[ -z "$MY_PUBLIC_IP" ]]; then
    warn "⚠️ 无法获取本机公网 IP，将使用本地 IP"
    MY_PUBLIC_IP=$(hostname -I | awk '{print $1}')
  fi
  
  log "✅ 本机 IP: $MY_PUBLIC_IP"
  echo ""

  #------------------------------
  # 从现有 ENV 文件读取旧值（仅用于获取 PG_URL）
  #------------------------------
  if [[ -f "$ENV_FILE" ]]; then
    log "检测到现有配置文件 $ENV_FILE，读取旧值..."
    set +u
    set +e
    source "$ENV_FILE" 2>/dev/null
    set -e
    set -u
    PG_URL_DEFAULT="${PG_URL:-}"
  else
    if [[ -f "$OLD_CONF" ]]; then
      log "检测到旧版配置 $OLD_CONF，尝试读取..."
      set +u
      set +e
      source "$OLD_CONF" 2>/dev/null
      set -e
      set -u
    fi
    PG_URL_DEFAULT="${PG_URL:-}"
  fi

  #------------------------------
  # 获取 PG_URL（用于推导面板 API 地址）
  #------------------------------
  if [[ -n "${PG_URL_DEFAULT:-}" ]]; then
    PG_URL_INPUT="$PG_URL_DEFAULT"
    log "使用现有 PG_URL: $PG_URL_INPUT"
  else
    echo "=============================="
    echo "请输入 Pushgateway 地址"
    echo "示例: http://your-panel-ip:19091"
    echo "=============================="
    read -rp "Pushgateway 地址: " PG_URL_INPUT
    [[ -z "$PG_URL_INPUT" ]] && { echo "❌ PG_URL 不能为空"; exit 1; }
  fi

  # 自动推导 PANEL_API
  PANEL_HOST=$(echo "$PG_URL_INPUT" | sed -E 's#^https?://([^:/]+).*#\1#')
  PANEL_API="http://${PANEL_HOST}:18000"
  log "自动推导 PANEL_API=$PANEL_API"

  #------------------------------
  # 🆕 第二步：优先从面板机查询该 IP 是否已注册
  #------------------------------
  echo ""
  echo "=============================="
  echo "🔍 正在从面板机查询节点信息..."
  echo "=============================="
  
  if query_node_by_ip "$PANEL_API" "$MY_PUBLIC_IP"; then
    # 面板机已有该 IP 的记录，使用面板机的数据作为默认值
    INSTANCE_DEFAULT="${PANEL_INSTANCE}"
    DISPLAY_NAME_DEFAULT="${PANEL_DISPLAY_NAME}"
    NODE_ID="$PANEL_NODE_ID"
    
    echo ""
    echo -e "\e[33m⚠️ 检测到该 IP 已在面板机注册过！\e[0m"
    echo "   原 NODE_ID: $NODE_ID"
    echo "   原 INSTANCE: $INSTANCE_DEFAULT"
    echo "   原 DISPLAY_NAME: $DISPLAY_NAME_DEFAULT"
    echo ""
    read -rp "是否使用面板机的现有配置？(y=使用并可修改 / n=作为全新节点): " use_panel
    
    if [[ "$use_panel" =~ ^[Nn]$ ]]; then
      log "用户选择作为全新节点注册..."
      NODE_ID=""
      INSTANCE_DEFAULT=""
      DISPLAY_NAME_DEFAULT=""
    else
      log "将更新现有节点 ID=$NODE_ID 的信息..."
    fi
  else
    # 面板机没有该 IP 的记录
    # 检查本地是否有旧的 NODE_ID 文件（可能是克隆机器）
    if [[ -f "$NODE_ID_FILE" ]]; then
      local_node_id=$(cat "$NODE_ID_FILE")
      warn "⚠️ 本地存在 NODE_ID=$local_node_id，但面板机未找到该 IP 的记录"
      warn "   这可能是因为：1) 机器从其他节点克隆而来  2) 面板机数据库已重置"
      read -rp "是否忽略本地 NODE_ID 并作为新节点注册？(y=新注册 / n=尝试复用): " ignore_local
      
      if [[ "$ignore_local" =~ ^[Yy]$ ]]; then
        rm -f "$NODE_ID_FILE"
        log "已删除本地 NODE_ID 文件，将作为新节点注册"
        NODE_ID=""
      else
        NODE_ID="$local_node_id"
      fi
    else
      NODE_ID=""
    fi
    
    # 从本地 ENV 文件读取默认值（如果有）
    if [[ -f "$ENV_FILE" ]]; then
      set +u
      set +e
      source "$ENV_FILE" 2>/dev/null
      set -e
      set -u
      INSTANCE_DEFAULT="${INSTANCE:-}"
      DISPLAY_NAME_DEFAULT="${DISPLAY_NAME:-${INSTANCE_DEFAULT}}"
    else
      INSTANCE_DEFAULT=""
      DISPLAY_NAME_DEFAULT=""
    fi
  fi

  #------------------------------
  # 其他默认值（从本地 ENV 或使用系统默认）
  #------------------------------
  if [[ -f "$ENV_FILE" ]]; then
    set +u
    set +e
    source "$ENV_FILE" 2>/dev/null
    set -e
    set -u
  fi
  
  JOB_DEFAULT="${JOB:-trafficcop}"
  INTERVAL_DEFAULT="${INTERVAL:-10}"
  RESET_DAY_DEFAULT="${RESET_DAY:-1}"
  LIMIT_BYTES_GB_DEFAULT=$(awk "BEGIN {printf \"%.0f\", (${LIMIT_BYTES:-0}/1024/1024/1024)}" 2>/dev/null || echo "0")
  BANDWIDTH_MBPS_DEFAULT=$(awk "BEGIN {printf \"%.0f\", (${BANDWIDTH_BPS:-0}/1000000)}" 2>/dev/null || echo "0")
  LIMIT_MODE_DEFAULT="${LIMIT_MODE:-double}"
  IFACES_DEFAULT="${IFACES:-eth0}"

  #------------------------------
  # 交互输入
  #------------------------------
  echo ""
  echo "=============================="
  echo "请输入当前节点的唯一标识 INSTANCE"
  echo "⚠️ 必须唯一，仅允许字母/数字/点/横杠/下划线"
  echo "示例：node-01, db_02, proxy-kr.03"
  echo "=============================="
  read -rp "INSTANCE [默认 ${INSTANCE_DEFAULT:-无}]: " INSTANCE_INPUT
  INSTANCE="${INSTANCE_INPUT:-$INSTANCE_DEFAULT}"
  [[ -z "$INSTANCE" ]] && { echo "❌ INSTANCE 不能为空"; exit 1; }

  read -rp "显示名称 (可选，默认=${DISPLAY_NAME_DEFAULT:-$INSTANCE}): " DISPLAY_NAME_INPUT
  DISPLAY_NAME="${DISPLAY_NAME_INPUT:-${DISPLAY_NAME_DEFAULT:-$INSTANCE}}"

  read -rp "Job 名称 [默认 ${JOB_DEFAULT}]: " JOB_INPUT
  JOB="${JOB_INPUT:-$JOB_DEFAULT}"

  read -rp "推送间隔秒 [默认 ${INTERVAL_DEFAULT}]: " INTERVAL_INPUT
  INTERVAL="${INTERVAL_INPUT:-$INTERVAL_DEFAULT}"

  read -rp "每月重置日 (1-31) [默认 $RESET_DAY_DEFAULT]: " RESET_DAY_INPUT
  RESET_DAY="${RESET_DAY_INPUT:-$RESET_DAY_DEFAULT}"

  read -rp "流量配额 (GiB, 0=不限) [默认 $LIMIT_BYTES_GB_DEFAULT]: " LIMIT_INPUT
  LIMIT_BYTES=$(awk "BEGIN {print (${LIMIT_INPUT:-$LIMIT_BYTES_GB_DEFAULT} * 1024 * 1024 * 1024)}")

  read -rp "带宽上限 (Mbps, 0=不限) [默认 $BANDWIDTH_MBPS_DEFAULT]: " BW_INPUT
  BANDWIDTH_MBPS="${BW_INPUT:-$BANDWIDTH_MBPS_DEFAULT}"
  BANDWIDTH_BPS=$(awk "BEGIN {print $BANDWIDTH_MBPS * 1000000}")

  echo "限流模式 (double=双向, upload=仅上行, download=仅下行)"
  read -rp "请选择限流模式 [默认 $LIMIT_MODE_DEFAULT]: " LIMIT_MODE_INPUT
  LIMIT_MODE="${LIMIT_MODE_INPUT:-$LIMIT_MODE_DEFAULT}"

  # 网卡选择
  AVAILABLE_IFACES=$(ls /sys/class/net | grep -Ev '^(lo|docker.*|veth.*)$')
  DEFAULT_IFACE="${IFACES_DEFAULT:-$(echo "$AVAILABLE_IFACES" | grep -qw "eth0" && echo "eth0" || echo "$(echo "$AVAILABLE_IFACES" | head -n1)")}"
  
  echo "=============================="
  echo "检测到以下网络接口:"
  echo "$AVAILABLE_IFACES"
  echo "请输入需要监控的接口（可输入多个，以空格分隔）"
  echo "直接回车则默认使用: $DEFAULT_IFACE"
  echo "=============================="
  read -rp "IFACES: " IFACES_INPUT
  IFACES="${IFACES_INPUT:-$DEFAULT_IFACE}"

  #------------------------------
  # 🆕 向面板机注册/更新节点（携带 IP）
  #------------------------------
  echo ""
  log "正在向面板机注册/更新节点信息..."
  log "   IP: $MY_PUBLIC_IP"
  log "   INSTANCE: $INSTANCE"
  log "   DISPLAY_NAME: $DISPLAY_NAME"
  
  # 构建 JSON 请求体（包含 IP）
  JSON_BODY=$(cat <<EOF
{
  "instance": "$INSTANCE",
  "display_name": "$DISPLAY_NAME",
  "sort_order": 0,
  "reset_day": $RESET_DAY,
  "limit_bytes": $LIMIT_BYTES,
  "limit_mode": "$LIMIT_MODE",
  "bandwidth_bps": $BANDWIDTH_BPS,
  "ip": "$MY_PUBLIC_IP"
}
EOF
)

  if [[ -n "${NODE_ID:-}" && "$NODE_ID" != "0" ]]; then
    # 更新现有节点
    log "更新现有节点 ID=$NODE_ID..."
    UPDATE_RESP=$(curl -sS -X PATCH "${PANEL_API}/nodes/${NODE_ID}" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY" 2>/dev/null || echo "{}")
    
    # 检查更新是否成功
    if echo "$UPDATE_RESP" | grep -q '"id"'; then
      log "✅ 节点更新成功"
    else
      warn "⚠️ 节点更新可能失败: $UPDATE_RESP"
    fi
  else
    # 创建新节点
    log "创建新节点..."
    CREATE_RESP=$(curl -sS -X POST "${PANEL_API}/nodes" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY" 2>/dev/null || echo "{}")
    
    # 解析返回的 NODE_ID
    NODE_ID=$(echo "$CREATE_RESP" | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+' || echo "")
    
    if [[ -z "$NODE_ID" || "$NODE_ID" == "0" ]]; then
      warn "⚠️ 面板返回无效，响应内容: $CREATE_RESP"
      warn "⚠️ 临时设置 NODE_ID=0，请稍后在面板手动修复"
      NODE_ID=0
    else
      log "✅ 新节点创建成功，NODE_ID=$NODE_ID"
    fi
  fi

  # 保存 NODE_ID 到本地
  echo "$NODE_ID" > "$NODE_ID_FILE"
  log "已保存 NODE_ID=$NODE_ID 到 $NODE_ID_FILE"

  #------------------------------
  # 清理 PG 残余
  #------------------------------
  log "清理 Pushgateway 残余 (instance=$INSTANCE)"
  pg_delete_instance "$PG_URL_INPUT" "$JOB" "$INSTANCE"
  curl -s -X DELETE "$PG_URL_INPUT/metrics/job/$JOB/instance/$INSTANCE/node_id/$NODE_ID" >/dev/null 2>&1 || true

  #------------------------------
  # 写配置文件
  #------------------------------
  log "创建目录和配置文件..."
  install -d -m 755 "$AGENT_DIR" "$METRICS_DIR" || err "无法创建目录"
  
  cat >"$ENV_FILE" <<EOF
PG_URL=$PG_URL_INPUT
JOB=$JOB
INSTANCE=$INSTANCE
DISPLAY_NAME=$DISPLAY_NAME
INTERVAL=$INTERVAL
IFACES="$IFACES"
RESET_DAY=$RESET_DAY
LIMIT_BYTES=$LIMIT_BYTES
NODE_ID=$NODE_ID
BANDWIDTH_BPS=$BANDWIDTH_BPS
LIMIT_MODE=$LIMIT_MODE
MY_IP=$MY_PUBLIC_IP
EOF

  log "✅ 已写入配置 $ENV_FILE"

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
  CURRENT_DATE=$(date +%Y-%m-%d)
  {
    echo "# HELP traffic_rx_bytes_total Total received bytes."
    echo "# TYPE traffic_rx_bytes_total counter"
    echo "# HELP traffic_tx_bytes_total Total transmitted bytes."
    echo "# TYPE traffic_tx_bytes_total counter"
    echo "# HELP traffic_iface_up Interface state."
    echo "# TYPE traffic_iface_up gauge"
    echo "# HELP node_id Node ID."
    echo "# TYPE node_id gauge"
  } >"$METRICS_DIR/metrics.prom"

  ACTUAL_IFACES="${IFACES:-eth0}"
  for IF in $ACTUAL_IFACES; do
    RX=$(cat /sys/class/net/"$IF"/statistics/rx_bytes 2>/dev/null || echo 0)
    TX=$(cat /sys/class/net/"$IF"/statistics/tx_bytes 2>/dev/null || echo 0)
    STATE=$(cat /sys/class/net/"$IF"/operstate 2>/dev/null | grep -q up && echo 1 || echo 0)
    echo "traffic_rx_bytes_total{iface=\"$IF\",date=\"$CURRENT_DATE\"} $RX" >>"$METRICS_DIR/metrics.prom"
    echo "traffic_tx_bytes_total{iface=\"$IF\",date=\"$CURRENT_DATE\"} $TX" >>"$METRICS_DIR/metrics.prom"
    echo "traffic_iface_up{iface=\"$IF\"} $STATE" >>"$METRICS_DIR/metrics.prom"
  done

  echo "node_id $NODE_ID" >>"$METRICS_DIR/metrics.prom"

  curl -s -X PUT --data-binary @"$METRICS_DIR/metrics.prom" \
    "$PG_URL/metrics/job/$JOB/node_id/$NODE_ID/instance/$INSTANCE" || true

  sleep "$INTERVAL"
done
EOS

  chmod +x "$AGENT_DIR/agent.sh"
  log "✅ 已写入 $AGENT_DIR/agent.sh"

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
  systemctl enable --now trafficcop-agent || err "无法启用 trafficcop-agent 服务"
  log "✅ 已写入 systemd 单元并启动服务"

  #------------------------------
  # 安装验证
  #------------------------------
  log "验证安装结果..."
  local errors=0
  [[ -f "$ENV_FILE" ]] || { warn "缺少: $ENV_FILE"; ((errors++)); }
  [[ -f "$AGENT_DIR/agent.sh" ]] || { warn "缺少: $AGENT_DIR/agent.sh"; ((errors++)); }
  [[ -f "$SERVICE_FILE" ]] || { warn "缺少: $SERVICE_FILE"; ((errors++)); }
  
  if systemctl is-active trafficcop-agent &>/dev/null; then
    log "✅ 服务正在运行"
  else
    warn "服务未运行"; ((errors++))
  fi
  
  [[ $errors -eq 0 ]] && log "✅ 所有组件安装成功" || warn "⚠️ 安装完成但有 $errors 个问题"

  #------------------------------
  # 自检
  #------------------------------
  sleep 3
  if curl -s "$PG_URL_INPUT/metrics" | grep -q "node_id=\"$NODE_ID\""; then
     log "✅ 自检成功: $INSTANCE (node_id=$NODE_ID) 已在 Pushgateway 注册"
  else
     warn "未在 Pushgateway 检测到，可能需要等待一段时间"
  fi

  echo ""
  echo "=============================="
  echo -e "\e[32m✅ Agent 安装完成\e[0m"
  echo "   节点 IP: $MY_PUBLIC_IP"
  echo "   节点 ID: $NODE_ID"
  echo "   实例名: $INSTANCE"
  echo "   显示名: $DISPLAY_NAME"
  echo "=============================="
  
  read -rp "按回车返回菜单..." _
}
