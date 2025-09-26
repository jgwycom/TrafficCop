#!/usr/bin/env bash
# TrafficCop + Prometheus Pushgateway Agent 合并安装器（自愈版）
# - 强制 bash，非交互装依赖，systemd 失败自动降级 cron @reboot
# - 继承原 TrafficCop 配置的 别名/网卡/配额
# - 幂等可重跑；提供 install / agent-only / uninstall-agent / status

# ------------------ 严格模式 & 错误展示 ------------------
set -Eeuo pipefail
trap 'echo -e "\033[31m[ERR]\033[0m 行号:$LINENO 命令:${BASH_COMMAND}" >&2' ERR

# ------------------ 默认参数（可用 env 覆盖） ------------------
: "${PG_URL:=http://45.78.23.232:19091}"         # Pushgateway 地址（按你的中心机）
: "${JOB_NAME:=trafficcop}"                      # Prometheus job 名
: "${AGENT_DIR:=/opt/trafficcop-agent}"          # agent 安装目录
: "${AGENT_USER:=root}"                          # 运行用户
: "${CONFIG_FILE:=/root/TrafficCop/traffic_monitor_config.txt}"  # 原 TrafficCop 配置
: "${ORIG_DIR:=/root/TrafficCop}"
: "${ORIG_MONITOR:=/root/TrafficCop/traffic_monitor.sh}"         # 原主程序（如果需要）
: "${ENV_FILE:=/etc/trafficcop-agent.env}"       # agent 环境变量文件
: "${SERVICE_NAME:=trafficcop-agent.service}"    # systemd 服务名
: "${PUSH_INTERVAL:=10}"                         # 推送间隔秒
: "${ENABLE_VNSTAT:=1}"                          # 1=尝试月累计；0=跳过
: "${DOWNLOAD_ORIGINAL:=0}"                      # 1=缺失时尝试拉取原脚本并短暂运行；0=跳过

# ------------------ 小工具 ------------------
green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
red(){ echo -e "\033[31m$*\033[0m"; }
hr(){ echo "------------------------------------------------------------"; }

ensure_root(){
  if [[ "$(id -u)" -ne 0 ]]; then red "请用 root 运行"; exit 1; fi
}

pm_detect(){
  command -v apt >/dev/null && echo apt && return
  command -v dnf >/dev/null && echo dnf && return
  command -v yum >/dev/null && echo yum && return
  command -v apk >/devnull 2>&1 && echo apk && return
  echo "unknown"
}

install_deps(){
  local pm; pm="$(pm_detect)"
  green "[1/6] 安装依赖（$pm）"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y
      apt-get install -y -o Dpkg::Options::=--force-confnew \
        curl jq iproute2 coreutils ca-certificates cron bash
      [[ "$ENABLE_VNSTAT" = "1" ]] && apt-get install -y vnstat || true
      ;;
    dnf)  dnf install -y curl jq iproute coreutils ca-certificates cronie bash; [[ "$ENABLE_VNSTAT" = "1" ]] && dnf install -y vnstat || true; systemctl enable --now crond 2>/dev/null || true ;;
    yum)  yum install -y curl jq iproute coreutils ca-certificates cronie bash; [[ "$ENABLE_VNSTAT" = "1" ]] && yum install -y vnstat || true; systemctl enable --now crond 2>/dev/null || true ;;
    apk)  apk add --no-cache curl jq iproute2 coreutils ca-certificates busybox-initscripts bash; [[ "$ENABLE_VNSTAT" = "1" ]] && apk add --no-cache vnstat || true; rc-update add crond default; rc-service crond start ;;
    *)
      yellow "[WARN] 未识别包管理器。请手动安装：curl jq iproute2/coreutils cron bash（可选 vnstat）"
      ;;
  esac
}

download_original_if_missing(){
  [[ "$DOWNLOAD_ORIGINAL" = "1" ]] || { yellow "[跳过] 原 TrafficCop 自动下载（DOWNLOAD_ORIGINAL=0）"; return; }
  if [[ ! -f "$ORIG_MONITOR" ]]; then
    green "[2/6] 拉取原 TrafficCop（可选）"
    mkdir -p "$ORIG_DIR"
    curl -fsSL "https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop.sh" \
      | tr -d '\r' > "$ORIG_MONITOR"
    chmod +x "$ORIG_MONITOR"
    # 防止阻塞：最多跑 20 秒（用于生成/刷新配置），超时即跳过
    timeout 20s bash "$ORIG_MONITOR" || true
  else
    green "[2/6] 已检测到原 TrafficCop：$ORIG_MONITOR"
  fi
}

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }

from_cfg(){
  # 从原配置提取键值（支持多种关键词）
  local regex="$1"
  [[ -f "$CONFIG_FILE" ]] || { echo ""; return; }
  grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' \
    | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true
}

detect_iface(){
  local v; v="$(from_cfg '(IFACE|iface|网卡)')"
  [[ -n "${v:-}" ]] && { echo "$v"; return; }
  ip route 2>/dev/null | awk '/default/ {print $5; exit}' || echo eth0
}

detect_instance(){
  # 优先别名/主机名字段；否则 hostname；再退化为 IP 或 unknown
  local v ip
  v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"
  [[ -z "$v" ]] && v="$(hostname 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] && v="$ip" || v="unknown"
  fi
  echo "$v"
}

parse_quota_bytes(){
  # 支持 LIMIT/QUOTA/上限/配额 等，支持 500G/1T/800M/123B
  local raw unit num bytes
  raw="$(from_cfg '(LIMIT|QUOTA|上限|限制|配额)')" || true
  [[ -z "$raw" ]] && { echo 0; return; }
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [[ -z "$num" ]] && { echo 0; return; }
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

write_agent(){
  green "[3/6] 写入 agent：$AGENT_DIR/agent.sh"
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/agent.sh" <<"EOS"
#!/usr/bin/env bash
set -Eeuo pipefail

: "${ENV_FILE:=/etc/trafficcop-agent.env}"
[[ -f "$ENV_FILE" ]] && . "$ENV_FILE"

: "${PG_URL:?缺少 PG_URL}"
: "${JOB_NAME:=trafficcop}"
: "${PUSH_INTERVAL:=10}"
: "${CONFIG_FILE:=/root/TrafficCop/traffic_monitor_config.txt}"

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' ; }

from_cfg(){
  local regex="$1"
  [[ -f "$CONFIG_FILE" ]] || { echo ""; return; }
  grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' \
    | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true
}

detect_iface(){
  local v; v="$(from_cfg '(IFACE|iface|网卡)')"
  [[ -z "$v" ]] && v="$(ip route 2>/dev/null | awk "/default/ {print \$5; exit}")"
  [[ -n "$v" ]] && echo "$v" || echo "eth0"
}

detect_instance(){
  local v; v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"
  [[ -z "$v" ]] && v="$(hostname 2>/dev/null || true)"
  [[ -n "$v" ]] && echo "$v" || echo "unknown"
}

parse_quota_bytes(){
  local raw unit num bytes
  raw="$(from_cfg '(LIMIT|QUOTA|上限|限制|配额)')" || true
  [[ -z "$raw" ]] && { echo 0; return; }
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [[ -z "$num" ]] && { echo 0; return; }
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

push_metrics(){
  local iface="$1" instance="$2" quota="$3"

  local rx tx
  rx="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"

  local month_rx=0 month_tx=0
  if command -v vnstat >/dev/null 2>&1; then
    read -r month_rx month_tx < <(
      vnstat --json 2>/dev/null | jq -r --arg IF "$iface" '
        .interfaces[] | select(.name==$IF) | .traffic.months[0] // {} |
        "\(.rx*1024) \(.tx*1024)"' 2>/dev/null || echo "0 0"
    )
  fi

  cat > /tmp/trafficcop_metrics.txt <<METRICS
# TYPE traffic_rx_bytes_total counter
traffic_rx_bytes_total{job="$JOB_NAME",instance="$instance",iface="$iface"} $rx
# TYPE traffic_tx_bytes_total counter
traffic_tx_bytes_total{job="$JOB_NAME",instance="$instance",iface="$iface"} $tx
# TYPE traffic_month_rx_bytes gauge
traffic_month_rx_bytes{job="$JOB_NAME",instance="$instance",iface="$iface"} ${month_rx:-0}
# TYPE traffic_month_tx_bytes gauge
traffic_month_tx_bytes{job="$JOB_NAME",instance="$instance",iface="$iface"} ${month_tx:-0}
# TYPE traffic_node_quota_bytes gauge
traffic_node_quota_bytes{job="$JOB_NAME",instance="$instance"} ${quota:-0}
# TYPE traffic_agent_up gauge
traffic_agent_up{job="$JOB_NAME",instance="$instance"} 1
METRICS

  curl -fsS --retry 2 --data-binary @/tmp/trafficcop_metrics.txt \
    "$PG_URL/metrics/job/$JOB_NAME/instance/$(printf "%s" "$instance" | sed 's/[ /]/_/g')"
}

main_loop(){
  local iface instance quota
  iface="${IFACE_OVERRIDE:-$(detect_iface)}"
  instance="${INSTANCE_OVERRIDE:-$(detect_instance)}"
  quota="${QUOTA_BYTES_OVERRIDE:-$(parse_quota_bytes)}"
  while true; do
    push_metrics "$iface" "$instance" "$quota" || true
    sleep "${PUSH_INTERVAL}"
  done
}

main_loop
EOS
  chmod +x "$AGENT_DIR/agent.sh"
}

write_env(){
  green "[4/6] 写入环境文件：$ENV_FILE"
  local IFACE DETECT_INSTANCE QUOTA
  IFACE="$(detect_iface)"
  DETECT_INSTANCE="$(detect_instance)"
  QUOTA="$(parse_quota_bytes)"
  cat > "$ENV_FILE" <<EOF
# trafficcop-agent 环境变量（可覆盖）
PG_URL="$PG_URL"
JOB_NAME="$JOB_NAME"
PUSH_INTERVAL="$PUSH_INTERVAL"
CONFIG_FILE="$CONFIG_FILE"

# 自动探测结果（可按需覆盖）
IFACE_OVERRIDE="$IFACE"
INSTANCE_OVERRIDE="$DETECT_INSTANCE"
QUOTA_BYTES_OVERRIDE="$QUOTA"
EOF
}

write_service(){
  green "[5/6] 注册 systemd/crond"
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

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload || true

  # 先尝试 systemd
  if systemctl enable --now "$SERVICE_NAME" 2>/dev/null; then
    green "[OK] systemd 已启用 $SERVICE_NAME"
  else
    yellow "[WARN] systemd 启动失败，切换 cron @reboot 兜底"
    echo "@reboot root nohup $AGENT_DIR/agent.sh >/var/log/trafficcop-agent.log 2>&1 &" \
      > /etc/cron.d/trafficcop-agent
    # 立即启动一次
    nohup "$AGENT_DIR/agent.sh" >/var/log/trafficcop-agent.log 2>&1 &
    # 确保 cron 存在并运行
    (service cron restart 2>/dev/null || systemctl restart cron 2>/dev/null || true)
  fi
}

show_status(){
  hr
  systemctl status "$SERVICE_NAME" --no-pager -n 30 2>/dev/null || yellow "[info] 无 systemd 或未启用（可能已使用 cron 兜底）"
  hr
  echo "== 环境文件：$ENV_FILE =="; cat "$ENV_FILE" 2>/dev/null || true
  hr
  echo "== 关键路径 =="; ls -l "$AGENT_DIR/agent.sh" 2>/dev/null || true; ls -l "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null || true
  hr
  local HN; HN="$(hostname -s || echo unknown)"
  echo "== Pushgateway 快速检查（匹配本机名：$HN） =="
  curl -fsSL "$PG_URL/metrics" | grep -E '^traffic_(rx|tx)_bytes_total' | grep -i "$HN" | head -n 3 || echo "(稍等 15s 再试)"
}

uninstall_agent(){
  yellow "[卸载] 仅移除 Pushgateway agent，不影响原 TrafficCop"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/cron.d/trafficcop-agent
  pkill -f "$AGENT_DIR/agent.sh" 2>/dev/null || true
  rm -rf "$AGENT_DIR" "$ENV_FILE"
  green "[完成] agent 已卸载"
}

cmd_install(){
  ensure_root
  install_deps
  download_original_if_missing
  write_agent
  write_env
  write_service
  show_status
}

cmd_agent_only(){
  ensure_root
  install_deps
  write_agent
  write_env
  write_service
  show_status
}

cmd_status(){
  show_status
}

case "${1:-install}" in
  install)         cmd_install ;;
  agent-only)      cmd_agent_only ;;
  uninstall-agent) uninstall_agent ;;
  status)          cmd_status ;;
  *) echo "用法: $0 [install|agent-only|uninstall-agent|status]"; exit 1 ;;
esac
