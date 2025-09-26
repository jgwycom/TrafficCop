#!/usr/bin/env bash
set -euo pipefail

# =============================
# TrafficCop + Prometheus Agent 一键合并安装脚本
# 兼容你的原TrafficCop配置，新增 Pushgateway metrics 上报
# Author: ChatGPT merge for jian Ma
# =============================

# -------- 可自定义的默认项（可通过环境变量覆盖） --------
: "${PG_URL:=http://45.78.23.232:9091}"       # Pushgateway 地址（按你现在的环境默认）
: "${JOB_NAME:=trafficcop}"                    # Prometheus job
: "${AGENT_DIR:=/opt/trafficcop-agent}"        # agent 安装目录
: "${AGENT_USER:=root}"                        # 运行用户（默认 root，保持与原脚本一致）
: "${CONFIG_FILE:=/root/TrafficCop/traffic_monitor_config.txt}"   # 原配置文件
: "${ORIG_DIR:=/root/TrafficCop}"              # 原脚本安装目录
: "${ORIG_MONITOR:=/root/TrafficCop/traffic_monitor.sh}"          # 原主程序（trafficcop.sh 改名）
: "${ENV_FILE:=/etc/trafficcop-agent.env}"     # agent 环境变量
: "${SERVICE_NAME:=trafficcop-agent.service}"  # systemd 服务名
: "${PUSH_INTERVAL:=10}"                       # 上报间隔(s)

# -------- 颜色输出 --------
c_green(){ echo -e "\033[32m$*\033[0m"; }
c_yellow(){ echo -e "\033[33m$*\033[0m"; }
c_red(){ echo -e "\033[31m$*\033[0m"; }
hr(){ echo "------------------------------------------------------------"; }

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { c_red "缺少依赖：$1"; return 1; }
}

ensure_root() {
  if [ "$(id -u)" -ne 0 ]; then
    c_red "请以root运行"; exit 1
  fi
}

detect_pkgmgr() {
  if command -v apt >/dev/null 2>&1; then echo apt; return; fi
  if command -v dnf >/dev/null 2>&1; then echo dnf; return; fi
  if command -v yum >/dev/null 2>&1; then echo yum; return; fi
  if command -v apk >/dev/null 2>&1; then echo apk; return; fi
  c_red "未检测到常见包管理器(apt/dnf/yum/apk)，请手动安装 curl jq iproute2 coreutils"; exit 1
}

install_deps() {
  local pm; pm=$(detect_pkgmgr)
  c_green "[1/6] 安装依赖($pm)：curl jq iproute2/coreutils"
  case "$pm" in
    apt)  apt update -y && apt install -y curl jq iproute2 coreutils vnstat ;;
    dnf)  dnf install -y curl jq iproute iproute-tc coreutils vnstat ;;
    yum)  yum install -y curl jq iproute iproute-tc coreutils vnstat ;;
    apk)  apk add --no-cache curl jq iproute2 coreutils vnstat ;;
  esac
}

download_orig_if_missing() {
  # 来自你之前的一键命令：ypq123456789/TrafficCop
  if [ ! -f "$ORIG_MONITOR" ]; then
    c_green "[2/6] 未发现原TrafficCop，拉取并初始化..."
    mkdir -p "$ORIG_DIR"
    # 下载原始trafficcop.sh为traffic_monitor.sh
    curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop.sh" \
      | tr -d '\r' > "$ORIG_MONITOR"
    chmod +x "$ORIG_MONITOR"
    # 首次执行原脚本，进入交互生成配置（你可按需点回车/设定）
    c_yellow "即将运行原脚本以生成配置（如已安装可Ctrl+C跳过）"
    bash "$ORIG_MONITOR" || true
  else
    c_green "[2/6] 检测到原TrafficCop脚本：$ORIG_MONITOR"
  fi
}

# -------- 从原配置/系统里提取节点别名、网卡、流量限额 --------
trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }

parse_from_config() {
  local key regex value
  key="$1"; regex="$2"
  if [ -f "$CONFIG_FILE" ]; then
    value="$(grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim)"
    [ -n "${value:-}" ] && echo "$value" && return 0
  fi
  return 1
}

detect_iface() {
  # 先从配置猜
  local v
  v="$(parse_from_config IFACE '(IFACE|iface|网卡)')" || true
  if [ -n "$v" ]; then echo "$v"; return; fi
  # 退化为默认路由网卡
  v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "$v" ] && echo "$v" || echo "eth0"
}

# 尽最大努力从配置里读到“别名/主机名”；找不到用 hostname
detect_node_alias() {
  local v
  v="$(parse_from_config HOSTNAME '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|alias|别名|主机名)')" || true
  [ -z "$v" ] && v="$(parse_from_config ALIAS '(ALIAS|alias|别名)')" || true
  [ -z "$v" ] && v="$(hostname 2>/dev/null)" || true
  echo "$v"
}

# 尝试解析“限额”，支持 500G/1T/800M 等；统一换算为字节
parse_quota_bytes() {
  local raw unit num bytes
  raw="$(parse_from_config LIMIT '(LIMIT|QUOTA|上限|限制|配额)')" || true
  if [ -z "$raw" ]; then echo 0; return; fi
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ' )"
  # 提取数值和单位
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [ -z "$num" ] && { echo 0; return; }
  case "$unit" in
    TB|T) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}') ;;
    GB|G|"") bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}') ;; # 默认按GB
    MB|M) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}') ;;
    KB|K) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}') ;;
    B)     bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n}') ;;
    *)     bytes=0 ;;
  esac
  echo "${bytes:-0}"
}

detect_instance() {
  # 以“自定义别名”为 instance；没有就用主机名；最后用IP
  local a ip
  a="$(detect_node_alias)"
  if [ -n "$a" ]; then echo "$a"; return; fi
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] && echo "$ip" || echo "unknown"
}

# -------- 写入 agent 主程序 --------
write_agent() {
  c_green "[3/6] 写入 agent 主程序：$AGENT_DIR/agent.sh"
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/agent.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# 从 env 文件读取
: "${ENV_FILE:=/etc/trafficcop-agent.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${PG_URL:?缺少 PG_URL}"
: "${JOB_NAME:=trafficcop}"
: "${PUSH_INTERVAL:=10}"
: "${CONFIG_FILE:=/root/TrafficCop/traffic_monitor_config.txt}"

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }
parse_from_config() {
  local key="$1" regex="$2" value
  if [ -f "$CONFIG_FILE" ]; then
    value="$(grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim)"
    [ -n "${value:-}" ] && echo "$value" && return 0
  fi
  return 1
}

detect_iface() {
  local v
  v="$(parse_from_config IFACE '(IFACE|iface|网卡)')" || true
  [ -z "$v" ] && v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [ -n "$v" ] && echo "$v" || echo "eth0"
}
detect_instance() {
  local v
  v="$(parse_from_config HOSTNAME '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|alias|别名|主机名)')" || true
  [ -z "$v" ] && v="$(parse_from_config ALIAS '(ALIAS|alias|别名)')" || true
  [ -z "$v" ] && v="$(hostname 2>/dev/null)" || true
  echo "$v"
}
parse_quota_bytes() {
  local raw unit num bytes
  raw="$(parse_from_config LIMIT '(LIMIT|QUOTA|上限|限制|配额)')" || true
  [ -z "$raw" ] && { echo 0; return; }
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [ -z "$num" ] && { echo 0; return; }
  case "$unit" in
    TB|T) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}') ;;
    GB|G|"") bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}') ;;
    MB|M) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}') ;;
    KB|K) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}') ;;
    B)     bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n}') ;;
    *)     bytes=0 ;;
  esac
  echo "${bytes:-0}"
}

push_metrics() {
  local iface="$1" instance="$2" quota_bytes="$3"
  # counters since boot
  local rx tx
  rx="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"

  # 月累计(可选) — 依赖 vnstat，抓当月 rx/tx
  local month_rx=0 month_tx=0
  if command -v vnstat >/dev/null 2>&1; then
    # 取当前月份的条目(第一个 month 对象)
    read -r month_rx month_tx < <(
      vnstat --json 2>/dev/null \
      | jq -r --arg IF "$iface" '
          .interfaces[] | select(.name==$IF) | .traffic.months[0] // {} |
          "\(.rx*1024) \(.tx*1024)"' 2>/dev/null || echo "0 0"
    )
  fi

  # 方便在Grafana里展示“节点元信息”
  # 注：配额也以 gauge 形式上报；quota_bytes=0 表示未知
  cat <<METRICS >/tmp/trafficcop_metrics.txt
traffic_rx_bytes_total{job="$JOB_NAME",instance="$instance",iface="$iface"} $rx
traffic_tx_bytes_total{job="$JOB_NAME",instance="$instance",iface="$iface"} $tx
traffic_month_rx_bytes{job="$JOB_NAME",instance="$instance",iface="$iface"} ${month_rx:-0}
traffic_month_tx_bytes{job="$JOB_NAME",instance="$instance",iface="$iface"} ${month_tx:-0}
traffic_node_quota_bytes{job="$JOB_NAME",instance="$instance",iface="$iface"} ${quota_bytes:-0}
traffic_agent_up{job="$JOB_NAME",instance="$instance"} 1
METRICS

  # 分组键：/job/<job>/instance/<instance>
  # iface 作为指标label
  curl -fsS --retry 2 --data-binary @/tmp/trafficcop_metrics.txt \
    "$PG_URL/metrics/job/$JOB_NAME/instance/$(printf "%s" "$instance" | sed 's/[ /]/_/g')"
}

main_loop() {
  local iface instance quota
  iface="$(detect_iface)"
  instance="${INSTANCE_OVERRIDE:-$(detect_instance)}"
  quota="${QUOTA_BYTES_OVERRIDE:-$(parse_quota_bytes)}"
  [ -n "${IFACE_OVERRIDE:-}" ] && iface="$IFACE_OVERRIDE"
  while true; do
    push_metrics "$iface" "$instance" "$quota" || true
    sleep "$PUSH_INTERVAL"
  done
}

main_loop
EOF
  chmod +x "$AGENT_DIR/agent.sh"
}

# -------- 写入 agent 环境变量 --------
write_env() {
  c_green "[4/6] 写入环境变量：$ENV_FILE"
  local IFACE DETECT_INSTANCE QUOTA
  IFACE="$(detect_iface)"
  DETECT_INSTANCE="$(detect_instance)"
  QUOTA="$(parse_quota_bytes)"

  cat > "$ENV_FILE" <<EOF
# trafficcop-agent 环境变量（可手动调整）
PG_URL="$PG_URL"
JOB_NAME="$JOB_NAME"
PUSH_INTERVAL="$PUSH_INTERVAL"
CONFIG_FILE="$CONFIG_FILE"

# 自动探测结果（如需覆盖可修改）
IFACE_OVERRIDE="$IFACE"
INSTANCE_OVERRIDE="$DETECT_INSTANCE"
QUOTA_BYTES_OVERRIDE="$QUOTA"
EOF
}

# -------- 写入 systemd 服务 --------
write_service() {
  c_green "[5/6] 创建 systemd 服务：$SERVICE_NAME"
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target

[Service]
User=$AGENT_USER
EnvironmentFile=$ENV_FILE
ExecStart=$AGENT_DIR/agent.sh
Restart=always
RestartSec=5
RuntimeMaxSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME" --now
}

show_status() {
  hr
  systemctl --no-pager status "$SERVICE_NAME" || true
  hr
  echo "环境变量：$ENV_FILE"
  cat "$ENV_FILE" || true
  hr
  echo "如需手动测试："
  echo "  PG_URL=$PG_URL $AGENT_DIR/agent.sh (Ctrl+C 结束)"
}

uninstall_all() {
  c_yellow "卸载 agent（不动原TrafficCop限制/通知）"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload
  rm -rf "$AGENT_DIR" "$ENV_FILE"
  c_green "已卸载 Pushgateway agent。"
}

menu() {
  cat <<'M'
[ TrafficCop 合并安装器 ]
1) 安装/更新 TrafficCop 原脚本(若缺失) + 安装/更新 Pushgateway agent
2) 仅安装/更新 Pushgateway agent
3) 查看 agent 运行状态
4) 卸载 Pushgateway agent
0) 退出
M
  read -rp "请选择 [0-4]: " ch
  case "$ch" in
    1) install_deps; download_orig_if_missing; write_agent; write_env; write_service; show_status ;;
    2) install_deps; write_agent; write_env; write_service; show_status ;;
    3) show_status ;;
    4) uninstall_all ;;
    0) exit 0 ;;
    *) echo "无效选项";;
  esac
}

# ---------------- 主流程 ----------------
ensure_root

if [ "${1:-}" = "install" ]; then
  install_deps; download_orig_if_missing; write_agent; write_env; write_service; show_status
elif [ "${1:-}" = "agent-only" ]; then
  install_deps; write_agent; write_env; write_service; show_status
elif [ "${1:-}" = "uninstall-agent" ]; then
  uninstall_all
else
  menu
fi
