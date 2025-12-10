#!/usr/bin/env bash
# V5 - IP优先版
# trafficcop-manager-merged.sh
# =============== 节点/面板分离版 ===============
# - 节点机：安装/升级/卸载 Agent
# - 面板机：安装/升级/卸载 面板栈 (docker-compose)
# - 新增：完全卸载（Agent + 面板栈 + 数据目录）
# - V5新增：IP优先识别，优先读取面板数据库
# ===============================================

set -Eeuo pipefail

# -------- 通用工具 --------
log()  { echo -e "\e[32m[$(date '+%F %T')] $*\e[0m"; }
warn() { echo -e "\e[33m[$(date '+%F %T')] $*\e[0m"; }
err()  { echo -e "\e[31m[$(date '+%F %T')] $*\e[0m"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "缺少依赖：$1"; }
root() { [[ $EUID -eq 0 ]] || err "请用 root 运行"; }

# =============================================================================
#                    ① Agent 安装逻辑 (V5 - IP优先版)
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
    for service in "ifconfig.me" "ipinfo.io/ip" "icanhazip.com" "api.ipify.org"; do
      ip=$(curl -s --connect-timeout 5 "$service" 2>/dev/null | tr -d '\n\r ')
      if [[ -n "$ip" && "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
      fi
    done
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
    
    local resp
    resp=$(curl -sS --connect-timeout 10 "${panel_api}/nodes/query-by-ip?ip=${my_ip}" 2>/dev/null || echo "{}")
    
    local found_id found_instance found_display_name
    found_id=$(echo "$resp" | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+' || echo "")
    found_instance=$(echo "$resp" | grep -o '"instance":[[:space:]]*"[^"]*"' | head -n1 | sed 's/"instance":[[:space:]]*"\([^"]*\)"/\1/' || echo "")
    found_display_name=$(echo "$resp" | grep -o '"display_name":[[:space:]]*"[^"]*"' | head -n1 | sed 's/"display_name":[[:space:]]*"\([^"]*\)"/\1/' || echo "")
    
    if [[ -n "$found_id" && "$found_id" != "0" ]]; then
      log "✅ 面板机已存在该 IP 的节点记录:"
      log "   NODE_ID=$found_id"
      log "   INSTANCE=$found_instance"
      log "   DISPLAY_NAME=$found_display_name"
      
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

  PANEL_HOST=$(echo "$PG_URL_INPUT" | sed -E 's#^https?://([^:/]+).*#\1#')
  PANEL_API="http://${PANEL_HOST}:18000"
  log "自动推导 PANEL_API=$PANEL_API"

  #------------------------------
  # 🆕 第二步：优先从面板机查询该 IP 是否已注册 (V5自动同步版)
  #------------------------------
  echo ""
  echo "=============================="
  echo "🔍 正在从面板机查询节点信息..."
  echo "=============================="
  
  if query_node_by_ip "$PANEL_API" "$MY_PUBLIC_IP"; then
    INSTANCE_DEFAULT="${PANEL_INSTANCE}"
    DISPLAY_NAME_DEFAULT="${PANEL_DISPLAY_NAME}"
    NODE_ID="$PANEL_NODE_ID"
    
    echo ""
    log "✅ 自动识别：该 IP 已在面板注册 (ID=$NODE_ID)"
    log "ℹ️  将自动加载面板端的配置信息（优先于本地）"
    echo "   实例名称: $INSTANCE_DEFAULT"
    echo "   显示名称: $DISPLAY_NAME_DEFAULT"
  else
    if [[ -f "$NODE_ID_FILE" ]]; then
      local_id=$(cat "$NODE_ID_FILE")
      warn "⚠️  本地存在旧 ID=$local_id，但面板数据库无此 IP 记录。"
      warn "⚠️  根据'优先读取面板数据库'原则，将忽略本地旧 ID，视为新节点。"
      rm -f "$NODE_ID_FILE"
    fi
    
    log "ℹ️  面板未收录此 IP，将作为新节点进行安装..."
    NODE_ID=""
    
    if [[ -f "$ENV_FILE" ]]; then
      set +u; set +e; source "$ENV_FILE" 2>/dev/null; set -e; set -u
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
    log "更新现有节点 ID=$NODE_ID..."
    UPDATE_RESP=$(curl -sS -X PATCH "${PANEL_API}/nodes/${NODE_ID}" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY" 2>/dev/null || echo "{}")
    
    if echo "$UPDATE_RESP" | grep -q '"id"'; then
      log "✅ 节点更新成功"
    else
      warn "⚠️ 节点更新可能失败: $UPDATE_RESP"
    fi
  else
    log "创建新节点..."
    CREATE_RESP=$(curl -sS -X POST "${PANEL_API}/nodes" \
      -H "Content-Type: application/json" \
      -d "$JSON_BODY" 2>/dev/null || echo "{}")
    
    NODE_ID=$(echo "$CREATE_RESP" | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+' || echo "")
    
    if [[ -z "$NODE_ID" || "$NODE_ID" == "0" ]]; then
      warn "⚠️ 面板返回无效，响应内容: $CREATE_RESP"
      warn "⚠️ 临时设置 NODE_ID=0，请稍后在面板手动修复"
      NODE_ID=0
    else
      log "✅ 新节点创建成功，NODE_ID=$NODE_ID"
    fi
  fi

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

  if [[ -x /opt/trafficcop-agent/tg_notifier.sh ]]; then
    /opt/trafficcop-agent/tg_notifier.sh "✅ 面板/监控栈安装或升级完成\n主机: $(hostname) 已安装完成，并注册到面板。"
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

# =============================================================================
#                       ② 卸载 Agent 函数
# =============================================================================
uninstall_agent() {
  root
  log "卸载节点 Agent..."
  systemctl disable --now trafficcop-agent 2>/dev/null || true
  rm -f /etc/systemd/system/trafficcop-agent.service
  rm -f /etc/trafficcop-agent.env /etc/trafficcop-nodeid
  rm -rf /opt/trafficcop-agent
  systemctl daemon-reload
  log "✅ 节点 Agent 已卸载"
  read -rp "按回车返回菜单..." _
}

# =============================================================================
#                       ③ 面板栈安装逻辑（面板机用）
# =============================================================================
REPO_RAW="https://raw.githubusercontent.com/jgwycom/TrafficCop/main"
INSTALL_DIR="/www/trafficcop-panel"
DB_DIR="$INSTALL_DIR/data"
DB_PATH="$DB_DIR/trafficcop.db"
ENV_PATH="$INSTALL_DIR/settings.env"

install_or_upgrade_stack() {
  root
  need curl
  mkdir -p "$INSTALL_DIR" "$DB_DIR"

  log "从仓库获取最新面板与编排文件..."
  if ! curl -fsSL "$REPO_RAW/docker-compose.yml" -o "$INSTALL_DIR/docker-compose.yml"; then
    err "下载 docker-compose.yml 失败"
  fi
  if ! curl -fsSL "$REPO_RAW/app.py" -o "$INSTALL_DIR/app.py"; then
    err "下载 app.py 失败"
  fi
  if ! curl -fsSL "$REPO_RAW/trafficcop.json" -o "$INSTALL_DIR/trafficcop.json"; then
    err "下载 trafficcop.json 失败"
  fi
  if ! [[ -f "$ENV_PATH" ]]; then
    if ! curl -fsSL "$REPO_RAW/settings.env" -o "$ENV_PATH"; then
      err "下载 settings.env 失败"
    fi
  fi

  if command -v docker >/dev/null 2>&1; then
    log "启动 Docker 容器..."
    (cd "$INSTALL_DIR" && docker compose up -d || docker-compose up -d)
  else
    warn "未安装 docker；请手动启动面板栈"
  fi

  if [[ -x /opt/trafficcop-agent/tg_notifier.sh ]]; then
    /opt/trafficcop-agent/tg_notifier.sh "✅ 面板/监控栈安装或升级完成"
  fi

  setup_systemd_reset_timer
  log "面板/监控栈安装或升级完成 ✅"
  read -rp "按回车返回菜单..." _
}

# =============================================================================
#                       ④ systemd 双保险 reset
# =============================================================================
setup_systemd_reset_timer() {
  root
  need python3
  cat >/usr/local/bin/trafficcop-reset.sh <<"EOF"
#!/usr/bin/env bash
set -e
curl -fsSL http://127.0.0.1:8000/admin/reset-baseline >/dev/null 2>&1 || true
EOF
  chmod +x /usr/local/bin/trafficcop-reset.sh

  cat >/etc/systemd/system/trafficcop-reset.service <<EOF
[Unit]
Description=TrafficCop 月度流量基线重置
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/trafficcop-reset.sh

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/trafficcop-reset.timer <<EOF
[Unit]
Description=每日 00:10 执行流量基线重置
[Timer]
OnCalendar=*-*-* 00:10:00
Persistent=true
[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now trafficcop-reset.timer
  log "systemd reset 定时任务已启用（每日 00:10）"
}

# =============================================================================
#                       ⑤ 完全卸载
# =============================================================================
uninstall_all() {
  root
  log "⚠️ 将卸载 Agent + 面板栈 + 数据目录..."
  systemctl disable --now trafficcop-agent 2>/dev/null || true
  systemctl disable --now trafficcop-reset.timer 2>/dev/null || true
  rm -f /etc/systemd/system/trafficcop-agent.service
  rm -f /etc/systemd/system/trafficcop-reset.{service,timer}
  systemctl daemon-reload
  rm -rf /opt/trafficcop-agent /etc/trafficcop-agent.env /etc/trafficcop-nodeid /etc/trafficcop /www/trafficcop-panel
  log "✅ 已完成完全卸载（Agent + 面板栈 + 数据目录已清理）"
  read -rp "按回车返回菜单..." _
}

# =============================================================================
#                                ⑥ 菜单
# =============================================================================
menu() {
  while true; do
    clear
    echo -e "\e[36m============ TrafficCop 管理面板 V5 ============\e[0m"
    echo "1. 安装/升级 节点 Agent（节点机用）"
    echo "2. 卸载 节点 Agent（节点机用）"
    echo "3. 安装/升级 面板栈（面板机用）"
    echo "4. 卸载 面板/监控栈（不删数据）"
    echo "5. 查看状态"
    echo "6. 配置 Telegram 推送"
    echo "7. 调整每日任务时间"
    echo "8. ⚠️ 完全卸载（Agent + 面板栈 + 数据目录）"
    echo "9. 退出"
    echo "============================================"
    read -rp "请输入选项: " num
    case "$num" in
      1) 
        install_agent
        ;;
      2) 
        uninstall_agent
        ;;
      3) 
        install_or_upgrade_stack
        ;;
      4) 
        systemctl disable --now trafficcop-reset.timer 2>/dev/null || true
        read -rp "按回车返回菜单..." _
        ;;
      5)
        echo "=== 服务状态 ==="
        systemctl status trafficcop-agent --no-pager 2>/dev/null || echo "❌ trafficcop-agent 服务未安装或未运行"
        if systemctl list-unit-files | grep -q trafficcop-reset.timer; then
          systemctl status trafficcop-reset.timer --no-pager || echo "❌ trafficcop-reset.timer 状态异常"
        else
          echo "ℹ️  节点机未启用 reset.timer"
        fi
        echo -e "\n=== 文件检查 ==="
        [[ -f "/etc/trafficcop-agent.env" ]] && echo "✅ /etc/trafficcop-agent.env 存在" || echo "❌ /etc/trafficcop-agent.env 不存在"
        [[ -f "/opt/trafficcop-agent/agent.sh" ]] && echo "✅ /opt/trafficcop-agent/agent.sh 存在" || echo "❌ /opt/trafficcop-agent/agent.sh 不存在"
        [[ -f "/etc/systemd/system/trafficcop-agent.service" ]] && echo "✅ /etc/systemd/system/trafficcop-agent.service 存在" || echo "❌ /etc/systemd/system/trafficcop-agent.service 不存在"
        read -rp "按回车返回菜单..." _
        ;;
      6)
        root
        mkdir -p /etc/trafficcop
        read -rp "TG_BOT_TOKEN: " t
        read -rp "TG_CHAT_ID: " c
        echo "TG_BOT_TOKEN=$t" >/etc/trafficcop/telegram.env
        echo "TG_CHAT_ID=$c" >>/etc/trafficcop/telegram.env
        if curl -fsSL "$REPO_RAW/tg_notifier.sh" -o /opt/trafficcop-agent/tg_notifier.sh; then
          chmod +x /opt/trafficcop-agent/tg_notifier.sh
          log "✅ 已写入 Telegram 配置并安装 tg_notifier.sh"
        else
          warn "下载 tg_notifier.sh 失败"
        fi
        read -rp "按回车返回菜单..." _
        ;;
      7)
        if [[ ! -f /etc/systemd/system/trafficcop-reset.timer ]]; then
          warn "未检测到 reset.timer，请先在面板机运行安装/升级面板栈"
          read -rp "按回车返回菜单..." _
        else
          read -rp "请输入新 OnCalendar (默认 00:10:00): " t; t="${t:-00:10:00}"
          sed -i "s|OnCalendar=.*|OnCalendar=*-*-* $t|" /etc/systemd/system/trafficcop-reset.timer
          systemctl daemon-reload
          systemctl restart trafficcop-reset.timer
          log "✅ 已更新 reset.timer 执行时间"
          read -rp "按回车返回菜单..." _
        fi
        ;;
      8) 
        uninstall_all
        ;;
      9) 
        exit 0 
        ;;
      *) 
        echo "输入错误"
        sleep 1
        ;;
    esac
  done
}

# ===== 入口 =====
menu

