# AGENT_VERSION=2.0-stable
#!/usr/bin/env bash
set -Eeuo pipefail

### ================================
### 基本参数 & 常量
### ================================
UNIT_NAME="trafficcop-agent.service"
SERVICE_FILE="/etc/systemd/system/${UNIT_NAME}"
ENV_FILE="/etc/trafficcop-agent.env"
AGENT_DIR="/opt/trafficcop-agent"
RUN_DIR="/run/trafficcop"
METRICS_FILE="${RUN_DIR}/metrics.prom"

# 可通过环境变量传入 PG_URL（推荐一键命令时传入）
PG_URL_DEFAULT="${PG_URL:-http://127.0.0.1:9091}"
JOB_DEFAULT="trafficcop"
INTERVAL_DEFAULT="10"
IFACES_DEFAULT="AUTO"         # AUTO = 默认路由网卡 + 所有UP网卡
RESET_DAY_DEFAULT="1"         # 每月重置日（1-28）
LIMIT_BYTES_DEFAULT="0"       # 0=不启用（单位：字节；可在交互里按GiB输入自动换算）

YES_ALL="${YES_ALL:-0}"       # 非交互：YES_ALL=1 全部默认“是”
NUKE_PG="${NUKE_PG:-0}"       # 非交互：NUKE_PG=1 安装前清空整个 job
CLEAR_ONLY="${CLEAR_ONLY:-0}" # 非交互：CLEAR_ONLY=1 仅清理后退出（不安装）

### ================================
### 工具函数
### ================================
log(){ echo "[$(date +'%F %T')] $*"; }
die(){ echo "❌ $*" >&2; exit 1; }
need_root(){ [[ $EUID -eq 0 ]] || die "需要 root 权限运行"; }

# URL encode（用于 /job/<J>/instance/<I> 路径）
urlenc() {
  local s="$1" o="" c
  for ((i=0;i<${#s};i++)); do
    c="${s:i:1}"
    case "$c" in [a-zA-Z0-9._~-]) o+="$c";; *) printf -v o '%s%%%02X' "$o" "'$c";; esac
  done
  echo "$o"
}

yn() {
  local prompt="$1"
  local d="${2:-N}"
  [[ "$YES_ALL" = "1" ]] && { echo "y"; return; }
  read -r -p "$prompt [y/N]: " ans || true
  ans="${ans:-$d}"
  [[ "$ans" =~ ^[Yy]$ ]] && echo "y" || echo "n"
}

### ================================
### 残余清理（Pushgateway）
### ================================
pg_delete_job() {
  local pg="$1" job="$2"
  local J; J="$(urlenc "$job")"
  curl -s -X DELETE "${pg%/}/metrics/job/${J}" >/dev/null || true
}
pg_delete_instance() {
  local pg="$1" job="$2" inst="$3"
  local J; J="$(urlenc "$job")"
  local I; I="$(urlenc "$inst")"
  curl -s -X DELETE "${pg%/}/metrics/job/${J}/instance/${I}" >/dev/null || true
}
pg_has_instance() {
  local pg="$1" job="$2" inst="$3"
  curl -s "${pg%/}/metrics" | grep -q "job=\"${job}\"" | grep -q "instance=\"${inst}\""
}

### ================================
### 交互采集
### ================================
ask_instance() {
  local v=""
  while true; do
    echo "=============================="
    echo "请输入当前节点的唯一标识 INSTANCE"
    echo "⚠️ 仅允许字母、数字、点、横杠、下划线，必须全局唯一"
    echo "示例：node-01, db_02, proxy-kr.03"
    echo "=============================="
    read -r -p "INSTANCE: " v || true
    [[ -z "$v" ]] && { echo "❌ 不允许为空"; continue; }
    [[ ! "$v" =~ ^[A-Za-z0-9._-]+$ ]] && { echo "❌ 仅允许 [A-Za-z0-9._-]"; continue; }
    break
  done
  INSTANCE="$v"
}

ask_reset_day_and_limit() {
  local d l g
  read -r -p "每月重置日 (1-28) [默认 ${RESET_DAY_DEFAULT}]: " d || true
  d="${d:-$RESET_DAY_DEFAULT}"
  [[ "$d" =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || d="$RESET_DAY_DEFAULT"
  RESET_DAY="$d"

  echo "流量总配额（GiB，0 表示不启用）。例如：100"
  read -r -p "配额GiB [默认 0]: " g || true
  g="${g:-0}"
  if [[ "$g" =~ ^[0-9]+$ ]] && [[ "$g" -gt 0 ]]; then
    # GiB -> bytes
    LIMIT_BYTES="$(( g * 1024 * 1024 * 1024 ))"
  else
    LIMIT_BYTES="0"
  fi
}

ask_pg_url_job_interval() {
  local p j itf
  read -r -p "Pushgateway 地址 [默认 ${PG_URL_DEFAULT}]: " p || true
  PG_URL="${p:-$PG_URL_DEFAULT}"

  read -r -p "Prometheus job 名称 [默认 ${JOB_DEFAULT}]: " j || true
  JOB="${j:-$JOB_DEFAULT}"

  read -r -p "Push 间隔秒 [默认 ${INTERVAL_DEFAULT}]: " itf || true
  [[ "$itf" =~ ^[1-9][0-9]*$ ]] || itf="$INTERVAL_DEFAULT"
  INTERVAL="$itf"

  IFACES="$IFACES_DEFAULT"
}

### ================================
### 写入配置 & agent & systemd
### ================================
write_env() {
  install -d -m 0755 "$(dirname "$ENV_FILE")"
  cat > "$ENV_FILE" <<EOF
# AGENT_VERSION=2.0-stable
PG_URL="${PG_URL}"
JOB="${JOB}"
INSTANCE="${INSTANCE}"
INTERVAL="${INTERVAL}"
IFACES="${IFACES}"
RUN_DIR="${RUN_DIR}"
METRICS_FILE="${METRICS_FILE}"

# 限额/重置逻辑（供扩展用）
RESET_DAY="${RESET_DAY}"
LIMIT_BYTES="${LIMIT_BYTES}"
EOF
  chmod 0644 "$ENV_FILE"
  log "已写入配置 ${ENV_FILE}"
}

write_agent() {
  install -d -m 0755 "$AGENT_DIR" "$RUN_DIR"
  cat > "${AGENT_DIR}/agent.sh" <<'EOS'
# AGENT_VERSION=2.0-stable
#!/usr/bin/env bash
set -Eeuo pipefail
. /etc/trafficcop-agent.env

log(){ echo "[$(date +'%F %T')] [$1] ${*:2}"; }
urlenc(){ local s="$1" o="" c; for((i=0;i<${#s};i++));do c="${s:i:1}"; case "$c" in [a-zA-Z0-9._~-]) o+="$c";; *) printf -v o '%s%%%02X' "$o" "'$c";; esac; done; echo "$o"; }

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
  local tmp="${METRICS_FILE}.tmp"; : >"$tmp"
  # 固定指标类型，避免 Pushgateway 400
  echo "# HELP traffic_rx_bytes_total Total received bytes."            >>"$tmp"
  echo "# TYPE traffic_rx_bytes_total counter"                          >>"$tmp"
  echo "# HELP traffic_tx_bytes_total Total transmitted bytes."         >>"$tmp"
  echo "# TYPE traffic_tx_bytes_total counter"                          >>"$tmp"
  echo "# HELP traffic_iface_up Interface state (1=up,0=down)."         >>"$tmp"
  echo "# TYPE traffic_iface_up gauge"                                  >>"$tmp"

  local cards=()
  if [[ "${IFACES:-AUTO}" == "AUTO" ]]; then
    mapfile -t cards < <(list_ifaces)
  else
    IFS=',' read -r -a cards <<<"$IFACES"
  fi

  for nic in "${cards[@]}"; do
    local rx tx up
    rx="$(read_stat "$nic" rx)"; tx="$(read_stat "$nic" tx)"; up="$(iface_up "$nic")"
    echo "traffic_rx_bytes_total{iface=\"$nic\"} $rx" >>"$tmp"
    echo "traffic_tx_bytes_total{iface=\"$nic\"} $tx" >>"$tmp"
    echo "traffic_iface_up{iface=\"$nic\"} $up"      >>"$tmp"
  done
  mv -f "$tmp" "$METRICS_FILE"
}

push_once(){
  local J I url code
  J="$(urlenc "$JOB")"; I="$(urlenc "$INSTANCE")"
  url="${PG_URL%/}/metrics/job/${J}/instance/${I}"

  code="$(curl -sS -m 6 -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: text/plain; version=0.0.4' \
      -X PUT --data-binary @"${METRICS_FILE}" "$url" || true)"
  if [[ "$code" != "202" && "$code" != "200" ]]; then
    log error "Pushgateway HTTP $code，尝试清理该 instance 后重试一次"
    curl -s -X DELETE "$url" >/dev/null || true
    code="$(curl -sS -m 6 -o /dev/null -w '%{http_code}' \
      -H 'Content-Type: text/plain; version=0.0.4' \
      -X PUT --data-binary @"${METRICS_FILE}" "$url" || true)"
    [[ "$code" == "202" || "$code" == "200" ]] || log error "重试仍失败 (HTTP $code)"
  fi
}

main(){
  log info "Agent started (JOB=${JOB}, INSTANCE=${INSTANCE}, PG=${PG_URL}, INTERVAL=${INTERVAL}, IFACES=${IFACES})"
  while true; do
    write_metrics
    push_once
    sleep "${INTERVAL}"
  done
}
main
EOS
  chmod 0755 "${AGENT_DIR}/agent.sh"
  log "已生成 ${AGENT_DIR}/agent.sh"
}

write_service() {
  cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=TrafficCop Pushgateway Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-${ENV_FILE}
ExecStart=${AGENT_DIR}/agent.sh
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SERVICE_FILE"
  systemctl daemon-reload
  log "已写入 systemd 单元 ${SERVICE_FILE}"
}

### ================================
### 安装/覆盖逻辑
### ================================
stop_disable(){
  systemctl stop "${UNIT_NAME}" 2>/dev/null || true
  systemctl disable "${UNIT_NAME}" 2>/dev/null || true
}

maybe_cleanup_old_layout(){
  # 老版本痕迹清理（/root/TrafficCop）
  if [[ -d "/root/TrafficCop" ]]; then
    log "检测到老版本目录 /root/TrafficCop"
    if [[ "$(yn '是否删除旧目录 /root/TrafficCop ?')" == "y" ]]; then
      rm -rf /root/TrafficCop || true
      log "已删除旧目录 /root/TrafficCop"
    else
      log "保留旧目录 /root/TrafficCop（不会再使用）"
    fi
  fi
}

install_fresh(){
  log "开始全新安装 ..."
  ask_instance
  ask_pg_url_job_interval
  ask_reset_day_and_limit

  # 强制清理 Pushgateway 残余（该 instance）
  log "安装前清理 Pushgateway: job='${JOB}', instance='${INSTANCE}'"
  pg_delete_instance "${PG_URL}" "${JOB}" "${INSTANCE}"

  # 可选：清空整个 job（环境变量或手动导出设置）
  if [[ "$NUKE_PG" = "1" ]]; then
    log "NUKE_PG=1 -> 清空整个 job ${JOB}"
    pg_delete_job "${PG_URL}" "${JOB}"
  fi

  write_env
  write_agent
  write_service
  systemctl enable "${UNIT_NAME}"
  systemctl start "${UNIT_NAME}"
}

install_overwrite_or_reuse(){
  log "检测到已存在配置：${ENV_FILE}"
  # 读取旧配置（供展示/继承）
  # shellcheck disable=SC1090
  . "${ENV_FILE}" || true

  echo "当前检测到旧配置："
  echo " PG_URL=${PG_URL:-$PG_URL_DEFAULT}"
  echo " JOB=${JOB:-$JOB_DEFAULT}"
  echo " INSTANCE(旧)=${INSTANCE:-<未设>}"
  echo " INTERVAL=${INTERVAL:-$INTERVAL_DEFAULT}"
  echo " IFACES=${IFACES:-$IFACES_DEFAULT}"
  echo " RESET_DAY=${RESET_DAY:-$RESET_DAY_DEFAULT}"
  echo " LIMIT_BYTES=${LIMIT_BYTES:-$LIMIT_BYTES_DEFAULT}"
  echo

  if [[ "$(yn '是否沿用旧配置(除 INSTANCE)？选择 n 表示覆盖安装')" == "y" ]]; then
    # 沿用旧配置，但**仍强制重新输入 INSTANCE**
    ask_instance
    PG_URL="${PG_URL:-$PG_URL_DEFAULT}"
    JOB="${JOB:-$JOB_DEFAULT}"
    INTERVAL="${INTERVAL:-$INTERVAL_DEFAULT}"
    IFACES="${IFACES:-$IFACES_DEFAULT}"
    RESET_DAY="${RESET_DAY:-$RESET_DAY_DEFAULT}"
    LIMIT_BYTES="${LIMIT_BYTES:-$LIMIT_BYTES_DEFAULT}"
  else
    # 覆盖安装：全部重新询问
    ask_instance
    ask_pg_url_job_interval
    ask_reset_day_and_limit
  fi

  log "安装前清理 Pushgateway: job='${JOB}', instance='${INSTANCE}'"
  pg_delete_instance "${PG_URL}" "${JOB}" "${INSTANCE}"

  write_env
  write_agent
  write_service
  systemctl enable "${UNIT_NAME}"
  systemctl restart "${UNIT_NAME}"
}

self_check_and_residual(){
  log "安装后自检：查询 Pushgateway 是否存在 instance='${INSTANCE}'"
  sleep 2
  if curl -s "${PG_URL%/}/metrics" | grep -q "job=\"${JOB}\"" | grep -q "instance=\"${INSTANCE}\""; then
    log "✅ 已在 Pushgateway 中发现 ${INSTANCE}"
  else
    log "⚠️ 未发现 ${INSTANCE}，请查看日志：journalctl -u ${UNIT_NAME} -n 50 --no-pager"
  fi

  # 残余节点检测（node-01 等）
  if curl -s "${PG_URL%/}/metrics" | grep -q 'instance="node-01"'; then
    log "⚠️ 检测到残余 instance=node-01"
    if [[ "$(yn '是否立即清理 node-01 残余？')" == "y" ]]; then
      pg_delete_instance "${PG_URL}" "${JOB}" "node-01"
      log "已尝试清理 node-01"
    else
      log "已忽略 node-01 清理"
    fi
    echo "👉 如果 Grafana 下拉仍残影，请考虑清空 Prometheus TSDB（数据卷路径与部署有关）。"
  fi
}

### ================================
### 主流程
### ================================
main(){
  need_root
  stop_disable
  maybe_cleanup_old_layout

  if [[ "$CLEAR_ONLY" = "1" ]]; then
    # 仅清空 job 或 instance 后退出（运维辅助）
    local pg="${PG_URL_DEFAULT}" job="${JOB_DEFAULT}"
    read -r -p "PG_URL [默认 ${pg}]: " _v || true; pg="${_v:-$pg}"
    read -r -p "JOB [默认 ${job}]: " _j || true; job="${_j:-$job}"
    if [[ "$(yn '清空整个 job ?')" == "y" ]]; then
      pg_delete_job "$pg" "$job"; log "已清空 job=${job}"
    else
      read -r -p "要清理的 instance: " _i || true
      [[ -z "${_i:-}" ]] && die "未提供 instance"
      pg_delete_instance "$pg" "$job" "$_i"; log "已清理 job=${job}, instance=${_i}"
    fi
    exit 0
  fi

  if [[ -f "$ENV_FILE" ]]; then
    install_overwrite_or_reuse
  else
    install_fresh
  fi

  self_check_and_residual
  log "完成。可在 Grafana 中查看：若下拉仍有旧实例，请在 Prometheus 侧清理历史 TSDB。"
}

main "$@"
