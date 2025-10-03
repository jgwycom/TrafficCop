#!/usr/bin/env bash
# V4
# trafficcop-manager-merged.sh
# =============== 节点/面板分离版 ===============
# - 节点机：安装/升级/卸载 Agent
# - 面板机：安装/升级/卸载 面板栈 (docker-compose)
# - 新增：完全卸载（Agent + 面板栈 + 数据目录）
# ===============================================

set -Eeuo pipefail

# -------- 通用工具 --------
log()  { echo -e "\e[32m[$(date '+%F %T')] $*\e[0m"; }
warn() { echo -e "\e[33m[$(date '+%F %T')] $*\e[0m"; }
err()  { echo -e "\e[31m[$(date '+%F %T')] $*\e[0m"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "缺少依赖：$1"; }
root() { [[ $EUID -eq 0 ]] || err "请用 root 运行"; }

# =============================================================================
#                               ① Agent 安装逻辑
# =============================================================================
install_agent() {
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
    curl -s -X DELETE "${pg_url}/metrics/job/${job}/instance/${inst}" >/dev/null || true
  }

  #------------------------------
  # 默认值初始化
  #------------------------------
  RESET_DAY_DEFAULT="1"
  LIMIT_BYTES_DEFAULT="0"
  BANDWIDTH_MBPS_DEFAULT="0"
  LIMIT_MODE_DEFAULT="double"

  #------------------------------
  # 从现有 ENV 文件读取旧值（优先）
  #------------------------------
  if [[ -f "$ENV_FILE" ]]; then
    log "检测到现有配置文件 $ENV_FILE，读取旧值..."
    # 临时取消错误设置以安全source
    set +u
    source "$ENV_FILE"
    set -u
    
    # 设置默认值为现有值
    INSTANCE_DEFAULT="${INSTANCE:-}"
    DISPLAY_NAME_DEFAULT="${DISPLAY_NAME:-${INSTANCE_DEFAULT}}"
    PG_URL_DEFAULT="${PG_URL:-}"
    JOB_DEFAULT="${JOB:-trafficcop}"
    INTERVAL_DEFAULT="${INTERVAL:-10}"
    RESET_DAY_DEFAULT="${RESET_DAY:-1}"
    LIMIT_BYTES_GB_DEFAULT=$(awk "BEGIN {printf \"%.0f\", (${LIMIT_BYTES:-0}/1024/1024/1024)}")
    BANDWIDTH_MBPS_DEFAULT=$(awk "BEGIN {printf \"%.0f\", (${BANDWIDTH_BPS:-0}/1000000)}")
    LIMIT_MODE_DEFAULT="${LIMIT_MODE:-double}"
    IFACES_DEFAULT="${IFACES:-eth0}"
  else
    # 从旧版配置迁移
    if [[ -f "$OLD_CONF" ]]; then
      log "检测到旧版配置 $OLD_CONF，尝试读取..."
      set +u
      source "$OLD_CONF"
      set -u
      RESET_DAY_DEFAULT="${RESET_DAY:-1}"
      LIMIT_BYTES_GB_DEFAULT=$(awk "BEGIN {printf \"%.0f\", (${LIMIT_BYTES:-0}/1024/1024/1024)}")
    fi
    
    # 新安装的默认值
    INSTANCE_DEFAULT=""
    DISPLAY_NAME_DEFAULT=""
    PG_URL_DEFAULT=""
    JOB_DEFAULT="trafficcop"
    INTERVAL_DEFAULT="10"
    RESET_DAY_DEFAULT="${RESET_DAY_DEFAULT:-1}"
    LIMIT_BYTES_GB_DEFAULT="${LIMIT_BYTES_GB_DEFAULT:-0}"
    BANDWIDTH_MBPS_DEFAULT="0"
    LIMIT_MODE_DEFAULT="double"
    IFACES_DEFAULT="eth0"
  fi

  #------------------------------
  # 交互输入（显示旧值作为默认）
  #------------------------------
  echo "=============================="
  echo "请输入当前节点的唯一标识 INSTANCE"
  echo "⚠️ 必须唯一，仅允许字母/数字/点/横杠/下划线"
  echo "示例：node-01, db_02, proxy-kr.03"
  echo "=============================="
  read -rp "INSTANCE [默认 ${INSTANCE_DEFAULT}]: " INSTANCE_INPUT
  INSTANCE="${INSTANCE_INPUT:-$INSTANCE_DEFAULT}"
  [[ -z "$INSTANCE" ]] && { echo "❌ INSTANCE 不能为空"; exit 1; }

  read -rp "显示名称 (可选，默认=${DISPLAY_NAME_DEFAULT}): " DISPLAY_NAME_INPUT
  DISPLAY_NAME="${DISPLAY_NAME_INPUT:-$DISPLAY_NAME_DEFAULT}"

  if [[ -n "${PG_URL_DEFAULT:-}" ]]; then
    PG_URL_INPUT="$PG_URL_DEFAULT"
  else
    read -rp "Pushgateway 地址 [默认 ${PG_URL_DEFAULT:-}]: " PG_URL_TMP
    PG_URL_INPUT="${PG_URL_TMP:-${PG_URL_DEFAULT:-}}"
    [[ -z "$PG_URL_INPUT" ]] && { echo "❌ PG_URL 不能为空"; exit 1; }
  fi

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

  # 网卡选择（显示旧值）
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
  # 自动推导 PANEL_API
  #------------------------------
  PANEL_HOST=$(echo "$PG_URL_INPUT" | sed -E 's#^https?://([^:/]+).*#\1#')
  PANEL_API="http://${PANEL_HOST}:18000"
  log "自动推导 PANEL_API=$PANEL_API"

  #------------------------------
  # 唯一 NODE_ID 处理（保持原有逻辑）
  #------------------------------
  NODE_ID=""
  if [[ -f "$NODE_ID_FILE" ]]; then
    NODE_ID=$(cat "$NODE_ID_FILE")
    log "检测到已有 NODE_ID=$NODE_ID"
    read -rp "是否复用已有 NODE_ID=$NODE_ID ? (y=复用 / n=重新申请): " reuse
    if [[ "$reuse" =~ ^[Nn]$ ]]; then
      rm -f "$NODE_ID_FILE"
      log "已删除旧 NODE_ID 文件，将重新申请新 ID"
      NODE_ID=""
    fi
  fi

  if [[ -z "${NODE_ID:-}" ]]; then
    log "向面板机申请新的 NODE_ID..."
    CREATE_RESP=$(curl -sS -X POST "$PANEL_API/nodes" \
      -H "Content-Type: application/json" \
      -d "{\"instance\":\"$INSTANCE\",\"display_name\":\"$DISPLAY_NAME\",\"sort_order\":0,\"reset_day\":$RESET_DAY,\"limit_bytes\":$LIMIT_BYTES,\"limit_mode\":\"$LIMIT_MODE\",\"bandwidth_bps\":$BANDWIDTH_BPS}" || true)
    NODE_ID=$(printf '%s' "$CREATE_RESP" | tr -d '\n' | grep -o '"id":[[:space:]]*[0-9]\+' | head -n1 | grep -o '[0-9]\+')
    if [[ -z "$NODE_ID" ]]; then
      log "⚠️ 面板返回无效，临时设置 NODE_ID=0"
      NODE_ID=0
    fi
    echo "$NODE_ID" > "$NODE_ID_FILE"
    log "已分配 NODE_ID=$NODE_ID"
  else
    curl -s -X PATCH "$PANEL_API/nodes/$NODE_ID" \
      -H "Content-Type: application/json" \
      -d "{\"instance\":\"$INSTANCE\",\"display_name\":\"$DISPLAY_NAME\",\"reset_day\":$RESET_DAY,\"limit_bytes\":$LIMIT_BYTES,\"limit_mode\":\"$LIMIT_MODE\",\"bandwidth_bps\":$BANDWIDTH_BPS}" >/dev/null || true
  fi

  #------------------------------
  # 清理 PG 残余
  #------------------------------
  log "清理 Pushgateway 残余 (instance=$INSTANCE)"
  pg_delete_instance "$PG_URL_INPUT" "$JOB" "$INSTANCE"
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
BANDWIDTH_BPS=$BANDWIDTH_BPS
LIMIT_MODE=$LIMIT_MODE
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
  CURRENT_DATE=$(date +%Y-%m-%d)
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

  # 安全处理：确保 IFACES 有值
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
  # 自检
  #------------------------------
  sleep 3
  if curl -s "$PG_URL_INPUT/metrics" | grep -q "instance=\"$INSTANCE\".*node_id=\"$NODE_ID\""; then
     log "✅ 自检成功: $INSTANCE (node_id=$NODE_ID) 已在 Pushgateway 注册"
  else
     warn "未在 Pushgateway 检测到 $INSTANCE (node_id=$NODE_ID)，可能需要等待一段时间"
  fi

  if [[ -x /opt/trafficcop-agent/tg_notifier.sh ]]; then
    /opt/trafficcop-agent/tg_notifier.sh "✅ 面板/监控栈安装或升级完成\n主机: $(hostname) 已安装完成，并注册到面板。"
  fi

  # 安装完成后回到菜单
  menu
}

# =============================================================================
#                       ② 卸载 Agent 函数（新增）
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
  menu
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
  curl -fsSL "$REPO_RAW/docker-compose.yml" -o "$INSTALL_DIR/docker-compose.yml"
  curl -fsSL "$REPO_RAW/app.py" -o "$INSTALL_DIR/app.py"
  curl -fsSL "$REPO_RAW/trafficcop.json" -o "$INSTALL_DIR/trafficcop.json"
  if ! [[ -f "$ENV_PATH" ]]; then
    curl -fsSL "$REPO_RAW/settings.env" -o "$ENV_PATH"
  fi

  if command -v docker >/dev/null 2>&1; then
    (cd "$INSTALL_DIR" && docker compose up -d || docker-compose up -d)
  else
    warn "未安装 docker；请手动启动面板栈"
  fi

  if [[ -x /opt/trafficcop-agent/tg_notifier.sh ]]; then
    /opt/trafficcop-agent/tg_notifier.sh "✅ 面板/监控栈安装或升级完成"
  fi

  setup_systemd_reset_timer
  log "面板/监控栈安装或升级完成 ✅"

  # 安装完成后回到菜单
  menu
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
#                       ⑤ 完全卸载（新增）
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
  menu
}

# =============================================================================
#                                ⑥ 菜单
# =============================================================================
menu() {
  clear
  echo -e "\e[36m============ TrafficCop 管理面板 V4 ============\e[0m"
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
    1) install_agent ;;
    2) uninstall_agent ;;
    3) install_or_upgrade_stack ;;
    4) systemctl disable --now trafficcop-reset.timer; menu ;;
    5)
       systemctl status trafficcop-agent --no-pager || true
       if systemctl list-unit-files | grep -q trafficcop-reset.timer; then
         systemctl status trafficcop-reset.timer --no-pager || true
       else
         echo "节点机未启用 reset.timer"
       fi
       read -rp "按回车返回菜单..." _
       menu
       ;;
    6)
       root
       mkdir -p /etc/trafficcop
       read -rp "TG_BOT_TOKEN: " t
       read -rp "TG_CHAT_ID: " c
       echo "TG_BOT_TOKEN=$t" >/etc/trafficcop/telegram.env
       echo "TG_CHAT_ID=$c" >>/etc/trafficcop/telegram.env
       curl -fsSL "$REPO_RAW/tg_notifier.sh" -o /opt/trafficcop-agent/tg_notifier.sh
       chmod +x /opt/trafficcop-agent/tg_notifier.sh
       log "✅ 已写入 Telegram 配置并安装 tg_notifier.sh"
       menu
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
       menu
       ;;
    8) uninstall_all ;;
    9) exit 0 ;;
    *) echo "输入错误"; sleep 1; menu ;;
  esac
}

# 始终进入菜单
menu
