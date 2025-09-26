#!/usr/bin/env bash
# TrafficCop + Prometheus Pushgateway Agent 合并安装器
# 目标：
# - 若节点未安装原代码：先安装原TrafficCop（默认交互，亦可通过环境变量预置配置无交互），再装推送Agent
# - 若节点已安装原代码：直接装推送Agent
# - 非交互安装依赖；systemd优先，失败自动降级cron @reboot；幂等可重跑
set -Eeuo pipefail
trap 'echo -e "\033[31m[ERR]\033[0m line:$LINENO cmd:${BASH_COMMAND}" >&2' ERR

#==================== 可通过环境变量覆盖的默认项 ====================
: "${PG_URL:=http://45.78.23.232:19091}"      # 中央Pushgateway地址
: "${JOB_NAME:=trafficcop}"                    # Prometheus job
: "${PUSH_INTERVAL:=10}"                       # 上报间隔秒
: "${ENABLE_VNSTAT:=1}"                        # 1=抓取当月累计；0=关闭

# 原TrafficCop安装脚本（先尝试manager，失败回退到主脚本）
: "${ORIG_URL_MANAGER:=https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop-manager.sh}"
: "${ORIG_URL_FALLBACK:=https://raw.githubusercontent.com/ypq123456789/TrafficCop/main/trafficcop.sh}"

# 目录/文件
: "${AGENT_DIR:=/opt/trafficcop-agent}"
: "${ENV_FILE:=/etc/trafficcop-agent.env}"
: "${SERVICE_NAME:=trafficcop-agent.service}"

# 自动探测原配置可能路径
CONFIG_CANDIDATES=(
  "/root/TrafficCop/traffic_monitor_config.txt"
  "/etc/trafficcop/traffic_monitor_config.txt"
  "/etc/trafficcop/config"
  "/opt/trafficcop/traffic_monitor_config.txt"
)

# ===（可选）为“无交互安装原代码”提供的变量（不设则走交互）===
# TC_ALIAS="上海-1"     # 节点显示名/别名
# TC_IFACE="eth0"       # 网卡名
# TC_LIMIT="500G"       # 每月配额，如 500G / 1T / 800M
# TC_NOTIFY="off"       # off 或 telegram 或 其他原脚本支持的方式
# TC_TG_TOKEN="xxx"     # 若走telegram通知，填BOT TOKEN
# TC_TG_CHAT_ID="123"   # 若走telegram通知，填CHAT ID
#====================================================================

green(){ echo -e "\033[32m$*\033[0m"; }
yellow(){ echo -e "\033[33m$*\033[0m"; }
hr(){ echo "------------------------------------------------------------"; }
ensure_root(){ [[ "$(id -u)" -eq 0 ]] || { echo "请用 root 运行"; exit 1; }; }

pm_detect(){
  command -v apt  >/dev/null 2>&1 && { echo apt;  return; }
  command -v dnf  >/dev/null 2>&1 && { echo dnf;  return; }
  command -v yum  >/dev/null 2>&1 && { echo yum;  return; }
  command -v apk  >/dev/null 2>&1 && { echo apk;  return; }
  echo unknown
}

install_deps(){
  local pm; pm="$(pm_detect)"
  green "[1/6] 安装依赖：$pm"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y -o Dpkg::Options::=--force-confnew \
        curl jq iproute2 coreutils ca-certificates cron bash >/dev/null
      [[ "$ENABLE_VNSTAT" = "1" ]] && apt-get install -y vnstat >/dev/null || true
      ;;
    dnf)
      dnf install -y curl jq iproute coreutils ca-certificates cronie bash >/dev/null
      [[ "$ENABLE_VNSTAT" = "1" ]] && dnf install -y vnstat >/dev/null || true
      systemctl enable --now crond >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y curl jq iproute coreutils ca-certificates cronie bash >/dev/null
      [[ "$ENABLE_VNSTAT" = "1" ]] && yum install -y vnstat >/dev/null || true
      systemctl enable --now crond >/dev/null 2>&1 || true
      ;;
    apk)
      apk add --no-cache curl jq iproute2 coreutils ca-certificates bash busybox-initscripts >/dev/null
      [[ "$ENABLE_VNSTAT" = "1" ]] && apk add --no-cache vnstat >/dev/null || true
      rc-update add crond default; rc-service crond start
      ;;
    *)
      yellow "[WARN] 未识别包管理器，请自行确保 curl jq iproute2 coreutils cron bash 可用"
      ;;
  esac
}

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
pick_config(){
  for p in "${CONFIG_CANDIDATES[@]}"; do [[ -f "$p" ]] && { echo "$p"; return; }; done
  echo ""
}

CONFIG_FILE="${CONFIG_FILE:-$(pick_config)}"

from_cfg(){
  local regex="$1" v
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] || { echo ""; return; }
  v="$(grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' \
      | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true)"
  echo "$v"
}

detect_iface(){
  local v; v="$(from_cfg '(IFACE|iface|网卡)')"
  [[ -z "$v" ]] && v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "$v" ]] && echo "$v" || echo "eth0"
}

detect_instance(){
  local v ip
  v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"
  [[ -z "$v" ]] && v="$(hostname -s 2>/dev/null || hostname 2>/dev/null || true)"
  if [[ -z "$v" ]]; then
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    [[ -n "$ip" ]] && v="$ip" || v="unknown"
  fi
  echo "$v"
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

#==================== 原代码：安装/预置配置/检测 ====================
orig_installed(){
  # 只要配置文件或主目录存在，视为已安装（避免重复装）
  [[ -n "${CONFIG_FILE:-}" && -f "$CONFIG_FILE" ]] && return 0
  [[ -d "/root/TrafficCop" ]] && return 0
  return 1
}

write_orig_config_if_preseed(){
  # 若设置了 TC_ALIAS/TC_IFACE/TC_LIMIT 等，则生成配置文件，尽量跳过交互
  [[ -z "${TC_ALIAS:-}" && -z "${TC_IFACE:-}" && -z "${TC_LIMIT:-}" && -z "${TC_NOTIFY:-}" ]] && return 0
  local dir="/root/TrafficCop"
  mkdir -p "$dir"
  CONFIG_FILE="${CONFIG_FILE:-$dir/traffic_monitor_config.txt}"
  yellow "[原代码] 发现预置变量，写入配置：$CONFIG_FILE"
  {
    [[ -n "${TC_ALIAS:-}"  ]]  && echo "HOSTNAME_ALIAS=$TC_ALIAS"
    [[ -n "${TC_IFACE:-}"  ]]  && echo "IFACE=$TC_IFACE"
    [[ -n "${TC_LIMIT:-}"  ]]  && echo "LIMIT=$TC_LIMIT"
    [[ -n "${TC_NOTIFY:-}" ]]  && echo "NOTIFY=$TC_NOTIFY"
    [[ -n "${TC_TG_TOKEN:-}"   ]] && echo "TG_BOT_TOKEN=$TC_TG_TOKEN"
    [[ -n "${TC_TG_CHAT_ID:-}" ]] && echo "TG_CHAT_ID=$TC_TG_CHAT_ID"
  } > "$CONFIG_FILE"
}

install_original_if_needed(){
  if orig_installed; then
    green "[2/6] 检测到原TrafficCop已安装，跳过安装原代码"
    return 0
  fi

  # 尝试预置配置（若提供了无交互变量）
  write_orig_config_if_preseed

  green "[2/6] 未检测到原TrafficCop，开始安装（默认交互；如已预置配置将自动跳过大部分交互）"
  local ok=0
  # 先尝试 manager 脚本
  if curl -fsSL -o /tmp/orig.sh "$ORIG_URL_MANAGER"; then
    sed -i 's/\r$//' /tmp/orig.sh; chmod +x /tmp/orig.sh
    bash /tmp/orig.sh || true
    ok=1
  fi
  # 回退主脚本
  if [[ $ok -eq 0 ]] && curl -fsSL -o /tmp/orig_fallback.sh "$ORIG_URL_FALLBACK"; then
    sed -i 's/\r$//' /tmp/orig_fallback.sh; chmod +x /tmp/orig_fallback.sh
    bash /tmp/orig_fallback.sh || true
    ok=1
  fi

  # 简单等待配置/目录出现
  for i in {1..20}; do
    CONFIG_FILE="$(pick_config)"
    [[ -n "$CONFIG_FILE" ]] && break
    sleep 1
  done
  if [[ -z "$CONFIG_FILE" ]]; then
    yellow "[WARN] 未找到原TrafficCop配置文件，但仍将继续安装推送Agent；你可稍后再运行本脚本自动补齐。"
  else
    green "[OK] 原TrafficCop已安装/配置：$CONFIG_FILE"
  fi
}

#==================== Agent 写入/注册（含兜底） ====================
write_agent(){
  green "[3/6] 写入 Agent：$AGENT_DIR/agent.sh"
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

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
from_cfg(){
  local regex="$1" v
  [[ -f "$CONFIG_FILE" ]] || { echo ""; return; }
  v="$(grep -E "$regex" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' \
     | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true)"
  echo "$v"
}
detect_iface(){
  local v; v="$(from_cfg '(IFACE|iface|网卡)')"
  [[ -z "$v" ]] && v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"
  [[ -n "$v" ]] && echo "$v" || echo "eth0"
}
detect_instance(){
  local v; v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"
  [[ -z "$v" ]] && v="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
  echo "$v"
}
parse_quota(){
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

push_once(){
  local iface="$1" instance="$2" quota="$3"
  local rx tx
  rx="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"

  local month_rx=0 month_tx=0
  if command -v vnstat >/dev/null 2>&1; then
    read -r month_rx month_tx < <(
      vnstat --json 2>/dev/null | jq -r --arg IF "$iface" \
      '.interfaces[] | select(.name==$IF) | .traffic.months[0] // {} | "\(.rx*1024) \(.tx*1024)"' 2>/dev/null || echo "0 0"
    )
  fi

  cat >/tmp/trafficcop_metrics.txt <<METRICS
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
    "$PG_URL/metrics/job/$JOB_NAME/instance/${instance//[ \/]/_}"
}

main(){
  local iface="${IFACE_OVERRIDE:-$(detect_iface)}"
  local instance="${INSTANCE_OVERRIDE:-$(detect_instance)}"
  local quota="${QUOTA_BYTES_OVERRIDE:-$(parse_quota)}"
  while true; do
    push_once "$iface" "$instance" "$quota" || true
    sleep "${PUSH_INTERVAL}"
  done
}
main
EOS
  chmod +x "$AGENT_DIR/agent.sh"
}

write_env(){
  green "[4/6] 写入环境：$ENV_FILE"
  local IFACE DETECT_INSTANCE QUOTA
  IFACE="$(detect_iface)"
  DETECT_INSTANCE="$(detect_instance)"
  QUOTA="$(parse_quota_bytes)"
  cat > "$ENV_FILE" <<EOF
PG_URL="$PG_URL"
JOB_NAME="$JOB_NAME"
PUSH_INTERVAL="$PUSH_INTERVAL"
CONFIG_FILE="${CONFIG_FILE:-/root/TrafficCop/traffic_monitor_config.txt}"

# 自动探测结果（可按需覆盖）
IFACE_OVERRIDE="$IFACE"
INSTANCE_OVERRIDE="$DETECT_INSTANCE"
QUOTA_BYTES_OVERRIDE="$QUOTA"
EOF
}

write_service(){
  green "[5/6] 注册常驻（systemd优先，失败降级cron）"
  cat > "/etc/systemd/system/$SERVICE_NAME" <<EOF
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target
[Service]
User=root
EnvironmentFile=$ENV_FILE
ExecStart=$AGENT_DIR/agent.sh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload >/dev/null 2>&1 || true
  if ! systemctl enable --now "$SERVICE_NAME" >/dev/null 2>&1; then
    yellow "[WARN] systemd 不可用/启用失败，启用 cron @reboot 兜底"
    echo "@reboot root nohup $AGENT_DIR/agent.sh >/var/log/trafficcop-agent.log 2>&1 &" >/etc/cron.d/trafficcop-agent
    nohup "$AGENT_DIR/agent.sh" >/var/log/trafficcop-agent.log 2>&1 & disown
    service cron restart 2>/dev/null || systemctl restart cron 2>/dev/null || true
  fi
}

show_status(){
  hr
  systemctl status "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || yellow "(无 systemd 或未启用，可能在用 cron 兜底)"
  hr
  echo "ENV  => $ENV_FILE";   [[ -f "$ENV_FILE" ]] && cat "$ENV_FILE" || true
  echo "AGENT=> $AGENT_DIR/agent.sh"; ls -l "$AGENT_DIR/agent.sh" 2>/dev/null || true
  echo "UNIT => /etc/systemd/system/$SERVICE_NAME"; ls -l "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null || true
  hr
  local HN; HN="$(hostname -s || echo unknown)"
  echo "Pushgateway 快速检查（匹配本机：$HN）"
  curl -fsSL "$PG_URL/metrics" | grep -E '^traffic_(rx|tx)_bytes_total' | grep -i "$HN" | head -n 3 || echo "(稍等 10 秒再刷新 Grafana)"
}

uninstall_agent(){
  yellow "[卸载] 仅移除 Pushgateway agent（不影响原TrafficCop）"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"; systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/cron.d/trafficcop-agent
  pkill -f "$AGENT_DIR/agent.sh" 2>/dev/null || true
  rm -rf "$AGENT_DIR" "$ENV_FILE"
  green "[完成] agent 已卸载"
}

cmd_install(){ ensure_root; install_deps; install_original_if_needed; write_agent; write_env; write_service; show_status; }
cmd_agent_only(){ ensure_root; install_deps; write_agent; write_env; write_service; show_status; }
cmd_status(){ show_status; }

case "${1:-install}" in
  install)         cmd_install ;;
  agent-only)      cmd_agent_only ;;
  uninstall-agent) uninstall_agent ;;
  status)          cmd_status ;;
  *) echo "用法: $0 [install|agent-only|uninstall-agent|status]"; exit 1 ;;
esac
