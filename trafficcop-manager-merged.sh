#!/usr/bin/env bash
# TrafficCop 交互管理器 + Pushgateway Agent 一体化脚本
# - 未安装过原代码：先进入原脚本交互（保持一机一配置），再自动装上报Agent
# - 已安装过原代码：可仅装/重装Agent
# - 支持 curl | bash 管道执行下的交互（重连stdin到/dev/tty）
set -Eeuo pipefail
trap 'echo -e "\033[31m[ERR]\033[0m line:$LINENO cmd:${BASH_COMMAND}" >&2' ERR

# —— 关键：如通过管道执行，确保交互读取来自你的终端而不是管道 ——
{ tty >/dev/null 2>&1 && [ ! -t 0 ]; } && exec </dev/tty || true

# ================= 可调参数（也可用环境变量覆盖） =================
: "${PG_URL:=http://45.78.23.232:19091}"   # Pushgateway 地址（可用环境变量 PG_URL 覆盖）
: "${JOB_NAME:=trafficcop}"                 # Prometheus job
: "${PUSH_INTERVAL:=10}"                    # 上报间隔(秒)
: "${ENABLE_VNSTAT:=1}"                     # 采集当月累计 1=开 0=关
WORK_DIR="/root/TrafficCop"
REPO_URL="https://raw.githubusercontent.com/ypq123456789/TrafficCop/main"

ENV_FILE="/etc/trafficcop-agent.env"
AGENT_DIR="/opt/trafficcop-agent"
SERVICE_NAME="trafficcop-agent.service"
CONFIG_FILE_CANDIDATES=(
  "/root/TrafficCop/traffic_monitor_config.txt"
  "/etc/trafficcop/traffic_monitor_config.txt"
  "/etc/trafficcop/config"
  "/opt/trafficcop/traffic_monitor_config.txt"
)
# ===============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; PURPLE='\033[0;35m'; NC='\033[0m'
hr(){ echo "------------------------------------------------------------"; }
check_root(){ [ "$(id -u)" -eq 0 ] || { echo -e "${RED}请用 root 运行${NC}"; exit 1; }; }

pm_detect(){
  command -v apt >/dev/null 2>&1 && { echo apt; return; }
  command -v dnf >/dev/null 2>&1 && { echo dnf; return; }
  command -v yum >/dev/null 2>&1 && { echo yum; return; }
  command -v apk >/dev/null 2>&1 && { echo apk; return; }
  echo unknown
}
install_deps(){
  local pm; pm="$(pm_detect)"
  echo -e "${GREEN}[依赖] 包管理器: ${pm}${NC}"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null
      apt-get install -y -o Dpkg::Options::=--force-confnew curl jq iproute2 coreutils ca-certificates cron bash >/dev/null
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
    *) echo -e "${YELLOW}[WARN] 未识别包管理器，请手工确保 curl/jq/iproute2/cron 可用${NC}" ;;
  esac
}

create_work_dir(){ mkdir -p "$WORK_DIR"; }

# ======（合入原 trafficcop-manager.sh 的核心功能）======
install_script(){ # 下载并保存原仓库脚本（保持交互式安装）
  local script_name="$1" out="${2:-$script_name}" out_path="$WORK_DIR/$out"
  echo -e "${YELLOW}下载 $script_name ...${NC}"
  curl -fsSL "$REPO_URL/$script_name" | tr -d '\r' > "$out_path"
  chmod +x "$out_path"
  echo -e "${GREEN}已保存 $out → $out_path${NC}"
}
run_script(){ # 运行已下载脚本（交互保持）
  local p="$1"
  if [ -f "$p" ]; then
    echo -e "${YELLOW}运行 $p ...${NC}"
    bash "$p"
  else
    echo -e "${RED}脚本不存在: $p${NC}"
  fi
}
install_monitor(){ # 原“安装流量监控”
  echo -e "${CYAN}正在安装流量监控（原脚本）...${NC}"
  install_script "trafficcop.sh" "traffic_monitor.sh"
  run_script "$WORK_DIR/traffic_monitor.sh"
  echo -e "${GREEN}流量监控安装完成！${NC}"
  read -r -p "按回车继续..." _ || true
}
install_tg_notifier(){
  echo -e "${CYAN}安装 Telegram 通知...${NC}"
  install_script "tg_notifier.sh"
  run_script "$WORK_DIR/tg_notifier.sh"
  echo -e "${GREEN}Telegram 通知安装完成${NC}"
  read -r -p "按回车继续..." _ || true
}
install_pushplus_notifier(){
  echo -e "${CYAN}安装 PushPlus 通知...${NC}"
  install_script "pushplus_notifier.sh"
  run_script "$WORK_DIR/pushplus_notifier.sh"
  echo -e "${GREEN}PushPlus 通知安装完成${NC}"
  read -r -p "按回车继续..." _ || true
}
install_serverchan_notifier(){
  echo -e "${CYAN}安装 Server酱 通知...${NC}"
  # 若仓库不存在则使用本地同名文件
  if curl -s --head "$REPO_URL/serverchan_notifier.sh" | grep -q "HTTP/2 200\|HTTP/1.1 200"; then
    install_script "serverchan_notifier.sh"
  elif [ -f "serverchan_notifier.sh" ]; then
    cp "serverchan_notifier.sh" "$WORK_DIR/serverchan_notifier.sh" && chmod +x "$WORK_DIR/serverchan_notifier.sh"
  else
    echo -e "${RED}未找到 serverchan_notifier.sh${NC}"; read -r -p "按回车继续..." _ || true; return
  fi
  run_script "$WORK_DIR/serverchan_notifier.sh"
  echo -e "${GREEN}Server酱 通知安装完成${NC}"
  read -r -p "按回车继续..." _ || true
}
remove_traffic_limit(){
  echo -e "${CYAN}解除流量限速...${NC}"
  install_script "remove_traffic_limit.sh"
  run_script "$WORK_DIR/remove_traffic_limit.sh"
  echo -e "${GREEN}已解除限速${NC}"
  read -r -p "按回车继续..." _ || true
}
view_logs(){
  echo -e "${CYAN}查看日志${NC}"
  echo "1) 流量监控日志"
  echo "2) Telegram 通知日志"
  echo "3) PushPlus 通知日志"
  echo "4) Server酱 通知日志"
  echo "0) 返回"
  read -r -p "选择 [0-4]: " c
  case "$c" in
    1) [ -f "$WORK_DIR/traffic_monitor.log" ] && tail -n 30 "$WORK_DIR/traffic_monitor.log" || echo -e "${RED}无日志${NC}" ;;
    2) [ -f "$WORK_DIR/tg_notifier_cron.log" ] && tail -n 30 "$WORK_DIR/tg_notifier_cron.log" || echo -e "${RED}无日志${NC}" ;;
    3) [ -f "$WORK_DIR/pushplus_notifier_cron.log" ] && tail -n 30 "$WORK_DIR/pushplus_notifier_cron.log" || echo -e "${RED}无日志${NC}" ;;
    4) [ -f "$WORK_DIR/serverchan_notifier_cron.log" ] && tail -n 30 "$WORK_DIR/serverchan_notifier_cron.log" || echo -e "${RED}无日志${NC}" ;;
  esac
  read -r -p "按回车继续..." _ || true
}
view_config(){
  echo -e "${CYAN}查看当前配置${NC}"
  echo "1) 流量监控"
  echo "2) Telegram 通知"
  echo "3) PushPlus 通知"
  echo "4) Server酱 通知"
  echo "0) 返回"
  read -r -p "选择 [0-4]: " c
  case "$c" in
    1) [ -f "$WORK_DIR/traffic_monitor_config.txt" ] && cat "$WORK_DIR/traffic_monitor_config.txt" || echo -e "${RED}无配置${NC}" ;;
    2) [ -f "$WORK_DIR/tg_notifier_config.txt" ] && cat "$WORK_DIR/tg_notifier_config.txt" || echo -e "${RED}无配置${NC}" ;;
    3) [ -f "$WORK_DIR/pushplus_notifier_config.txt" ] && cat "$WORK_DIR/pushplus_notifier_config.txt" || echo -e "${RED}无配置${NC}" ;;
    4) [ -f "$WORK_DIR/serverchan_notifier_config.txt" ] && cat "$WORK_DIR/serverchan_notifier_config.txt" || echo -e "${RED}无配置${NC}" ;;
  esac
  read -r -p "按回车继续..." _ || true
}
use_preset_config(){
  echo -e "${CYAN}使用预设配置${NC}"
  cat <<'EOP'
1) 阿里云CDT 200G     2) 阿里云CDT 20G     3) 阿里云轻量 1T
4) Azure 学生 15G     5) Azure 学生 115G   6) GCP 625G
7) GCP 200G           8) Alice 1500G       9) 亚洲云 300G
0) 返回
EOP
  read -r -p "选择 [0-9]: " c
  case "$c" in
    1) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/ali-200g" ;;
    2) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/ali-20g" ;;
    3) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/ali-1T" ;;
    4) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/az-15g" ;;
    5) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/az-115g" ;;
    6) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/GCP-625g" ;;
    7) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/GCP-200g" ;;
    8) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/alice-1500g" ;;
    9) curl -fsSL -o "$WORK_DIR/traffic_monitor_config.txt" "$REPO_URL/asia-300g" ;;
    0) return ;;
    *) echo -e "${RED}无效选择${NC}" ;;
  esac
  [ -f "$WORK_DIR/traffic_monitor_config.txt" ] && cat "$WORK_DIR/traffic_monitor_config.txt" || true
  read -r -p "按回车继续..." _ || true
}
stop_all_services(){
  echo -e "${CYAN}停止所有 TrafficCop 相关服务...${NC}"
  pkill -f traffic_monitor.sh 2>/dev/null || true
  pkill -f tg_notifier.sh 2>/dev/null || true
  pkill -f pushplus_notifier.sh 2>/dev/null || true
  pkill -f serverchan_notifier.sh 2>/dev/null || true
  crontab -l | grep -v -E "traffic_monitor.sh|tg_notifier.sh|pushplus_notifier.sh|serverchan_notifier.sh" | crontab - || true
  echo -e "${GREEN}已停止${NC}"; read -r -p "按回车继续..." _ || true
}
# ====== 原管理器菜单（增加了第9项：Agent 管理） ======
show_main_menu(){
  clear
  echo -e "${PURPLE}================ TrafficCop 管理工具 ================${NC}"
  echo -e "${YELLOW}1) 安装流量监控${NC}"
  echo -e "${YELLOW}2) 安装 Telegram 通知${NC}"
  echo -e "${YELLOW}3) 安装 PushPlus 通知${NC}"
  echo -e "${YELLOW}4) 安装 Server酱 通知${NC}"
  echo -e "${YELLOW}5) 解除流量限制${NC}"
  echo -e "${YELLOW}6) 查看日志${NC}"
  echo -e "${YELLOW}7) 查看当前配置${NC}"
  echo -e "${YELLOW}8) 使用预设配置${NC}"
  echo -e "${YELLOW}9) 安装/管理 Pushgateway Agent（新增）${NC}"
  echo -e "${YELLOW}0) 退出${NC}"
  echo -e "${PURPLE}====================================================${NC}"
  echo ""
}

# ========= Pushgateway Agent（新增部分） =========
trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
pick_config(){ for p in "${CONFIG_FILE_CANDIDATES[@]}"; do [ -f "$p" ] && { echo "$p"; return; }; done; echo ""; }
from_cfg(){ local re="$1" v c; c="$(pick_config)"; [ -n "$c" ] || { echo ""; return; }
  v="$(grep -E "$re" "$c" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true)"; echo "$v"; }
detect_iface(){ local v; v="$(from_cfg '(IFACE|iface|网卡)')"; [ -n "$v" ] || v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"; echo "${v:-eth0}"; }
detect_instance(){ local v; v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"; [ -n "$v" ] || v="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"; echo "$v"; }
parse_quota_bytes(){ local raw unit num bytes; raw="$(from_cfg '(LIMIT|QUOTA|上限|限制|配额)')" || true
  [ -n "$raw" ] || { echo 0; return; }
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [ -n "$num" ] || { echo 0; return; }
  case "$unit" in
    TB|T) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}') ;;
    GB|G|"") bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}') ;;
    MB|M) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}') ;;
    KB|K) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}') ;;
    B) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n}') ;;
    *) bytes=0 ;;
  esac
  echo "${bytes:-0}"
}

write_agent(){
  echo -e "${GREEN}[Agent] 写入 $AGENT_DIR/agent.sh${NC}"
  mkdir -p "$AGENT_DIR"
  cat > "$AGENT_DIR/agent.sh" <<"EOS"
#!/usr/bin/env bash
set -Eeuo pipefail
: "${ENV_FILE:=/etc/trafficcop-agent.env}"
[ -f "$ENV_FILE" ] && . "$ENV_FILE"

: "${PG_URL:?缺少 PG_URL}"
: "${JOB_NAME:=trafficcop}"
: "${PUSH_INTERVAL:=10}"
: "${CONFIG_FILE:=/root/TrafficCop/traffic_monitor_config.txt}"

trim(){ sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }
from_cfg(){ local re="$1" v; [ -f "$CONFIG_FILE" ] || { echo ""; return; }
  v="$(grep -E "$re" "$CONFIG_FILE" 2>/dev/null | head -n1 | sed 's/^[#[:space:]]*//' | awk -F'[=:]' '{print $2}' | tr -d "\"'" | trim || true)"; echo "$v"; }
detect_iface(){ local v; v="$(from_cfg '(IFACE|iface|网卡)')"; [ -n "$v" ] || v="$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')"; echo "${v:-eth0}"; }
detect_instance(){ local v; v="$(from_cfg '(HOSTNAME_ALIAS|HOST_NAME|HOSTNAME|ALIAS|alias|别名|主机名)')"; [ -n "$v" ] || v="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"; echo "$v"; }
parse_quota(){ local raw unit num bytes; raw="$(from_cfg '(LIMIT|QUOTA|上限|限制|配额)')" || true
  [ -n "$raw" ] || { echo 0; return; }
  raw="$(echo "$raw" | tr '[:lower:]' '[:upper:]' | tr -d ' ')"
  num="$(echo "$raw" | grep -oE '[0-9]+(\.[0-9]+)?' | head -n1)"
  unit="$(echo "$raw" | grep -oE '(TB|T|GB|G|MB|M|KB|K|B)$' | head -n1)"
  [ -n "$num" ] || { echo 0; return; }
  case "$unit" in
    TB|T) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}') ;;
    GB|G|"") bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}') ;;
    MB|M) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}') ;;
    KB|K) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}') ;;
    B) bytes=$(awk -v n="$num" 'BEGIN{printf "%.0f", n}') ;;
    *) bytes=0 ;;
  esac; echo "${bytes:-0}"
}

push_once(){
  local iface="$1" instance="$2" quota="$3"
  local rx tx; rx="$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)"
  tx="$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)"

  local month_rx=0 month_tx=0
  if command -v vnstat >/dev/null 2>&1; then
    read -r month_rx month_tx < <(vnstat --json 2>/dev/null | jq -r --arg IF "$iface" \
      '.interfaces[] | select(.name==$IF) | .traffic.months[0] // {} | "\(.rx*1024) \(.tx*1024)"' 2>/dev/null || echo "0 0")
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
  while true; do push_once "$iface" "$instance" "$quota" || true; sleep "${PUSH_INTERVAL}"; done
}
main
EOS
  chmod +x "$AGENT_DIR/agent.sh"
}

write_env(){
  echo -e "${GREEN}[Agent] 写入环境: $ENV_FILE${NC}"
  local IFACE DETECT_INSTANCE QUOTA
  IFACE="$(detect_iface)"; DETECT_INSTANCE="$(detect_instance)"; QUOTA="$(parse_quota_bytes)"
  cat > "$ENV_FILE" <<EOF
PG_URL="$PG_URL"
JOB_NAME="$JOB_NAME"
PUSH_INTERVAL="$PUSH_INTERVAL"
CONFIG_FILE="$(pick_config || echo /root/TrafficCop/traffic_monitor_config.txt)"

# 自动探测（可手动覆盖）
IFACE_OVERRIDE="$IFACE"
INSTANCE_OVERRIDE="$DETECT_INSTANCE"
QUOTA_BYTES_OVERRIDE="$QUOTA"
EOF
}

write_service(){
  echo -e "${GREEN}[Agent] 注册常驻（systemd优先，失败用cron兜底）${NC}"
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
    echo -e "${YELLOW}[WARN] systemd 不可用/失败，启用 cron @reboot 兜底${NC}"
    echo "@reboot root nohup $AGENT_DIR/agent.sh >/var/log/trafficcop-agent.log 2>&1 &" >/etc/cron.d/trafficcop-agent
    nohup "$AGENT_DIR/agent.sh" >/var/log/trafficcop-agent.log 2>&1 & disown
    service cron restart 2>/dev/null || systemctl restart cron 2>/dev/null || true
  fi
}

show_status(){
  hr
  systemctl status "$SERVICE_NAME" --no-pager -n 20 2>/dev/null || echo "(可能在用 cron 兜底)"
  hr
  echo "ENV : $ENV_FILE"; [ -f "$ENV_FILE" ] && cat "$ENV_FILE" || true
  echo "UNIT: /etc/systemd/system/$SERVICE_NAME"; ls -l "/etc/systemd/system/$SERVICE_NAME" 2>/dev/null || true
  echo "AGENT: $AGENT_DIR/agent.sh"; ls -l "$AGENT_DIR/agent.sh" 2>/dev/null || true
  hr
  local HN; HN="$(hostname -s || echo unknown)"
  echo "Pushgateway 快速检查（匹配本机：$HN）"
  curl -fsSL "$PG_URL/metrics" | grep -E '^traffic_(rx|tx)_bytes_total' | grep -i "$HN" | head -n 3 || echo "(稍等十秒再刷新 Grafana)"
}

uninstall_agent(){
  echo -e "${YELLOW}[Agent] 卸载...${NC}"
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME"; systemctl daemon-reload 2>/dev/null || true
  rm -f /etc/cron.d/trafficcop-agent
  pkill -f "$AGENT_DIR/agent.sh" 2>/dev/null || true
  rm -rf "$AGENT_DIR" "$ENV_FILE"
  echo -e "${GREEN}[Agent] 卸载完成${NC}"
}

menu_agent(){
  while true; do
    clear
    echo -e "${PURPLE}===== Pushgateway Agent 管理 =====${NC}"
    echo "1) 安装/重装 Agent"
    echo "2) 查看状态"
    echo "3) 卸载 Agent"
    echo "0) 返回主菜单"
    read -r -p "选择 [0-3]: " a
    case "$a" in
      1) install_deps; write_agent; write_env; write_service; show_status ;;
      2) show_status ;;
      3) uninstall_agent ;;
      0) break ;;
      *) echo "无效选择" ;;
    esac
    read -r -p "按回车继续..." _ || true
  done
}
# ============= 顶层命令 =============
cmd_install(){ check_root; install_deps; create_work_dir; install_monitor; write_agent; write_env; write_service; show_status; }
cmd_menu(){ check_root; create_work_dir; while true; do show_main_menu; read -r -p "请选择 [0-9]: " ch; case "$ch" in
  1) install_monitor ;;
  2) install_tg_notifier ;;
  3) install_pushplus_notifier ;;
  4) install_serverchan_notifier ;;
  5) remove_traffic_limit ;;
  6) view_logs ;;
  7) view_config ;;
  8) use_preset_config ;;
  9) menu_agent ;;
  0) echo -e "${GREEN}Bye${NC}"; exit 0 ;;
  *) echo -e "${RED}无效选择${NC}" ;;
esac; done; }
cmd_agent_only(){ check_root; install_deps; write_agent; write_env; write_service; show_status; }
cmd_status(){ show_status; }

case "${1:-install}" in
  install) cmd_install ;;
  menu) cmd_menu ;;
  agent-only) cmd_agent_only ;;
  uninstall-agent) uninstall_agent ;;
  status) cmd_status ;;
  *) echo "用法: $0 [install|menu|agent-only|uninstall-agent|status]"; exit 1 ;;
esac
