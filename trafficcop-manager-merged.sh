#!/usr/bin/env bash
# trafficcop-manager-merged.sh
# =============== 整合版 ===============
# 1) 保留【原有 Agent 安装逻辑】（PG 残余清理、唯一 NODE_ID、迁移助手、自检等）
# 2) 追加【面板/Prometheus/PG/Grafana 部署】+【systemd 重置日“双保险”】+【菜单】
# =====================================

set -Eeuo pipefail

# -------- 通用工具 --------
log()  { echo -e "\e[32m[$(date '+%F %T')] $*\e[0m"; }
warn() { echo -e "\e[33m[$(date '+%F %T')] $*\e[0m"; }
err()  { echo -e "\e[31m[$(date '+%F %T')] $*\e[0m"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || err "缺少依赖：$1"; }
root() { [[ $EUID -eq 0 ]] || err "请用 root 运行"; }

# =============================================================================
#                               ① 你的 Agent 安装
# =============================================================================
install_agent() {
  # === 你原始脚本的全部变量/函数/流程（未删减） ===
  # AGENT_VERSION=2.5-final
  # set -Eeuo pipefail  #（已在文件头开启）

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
  # 清理 PG 残余（不带 node_id 的路径 & 带 node_id 的路径）
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
  if curl -s "$PG_URL_INPUT/metrics" | grep -q "instance=\"$INSTANCE\".*node_id=\"$NODE_ID\""; then
    log "✅ 自检成功: $INSTANCE (node_id=$NODE_ID) 已在 Pushgateway 注册"
  else
    log "⚠️ 未检测到 $INSTANCE (node_id=$NODE_ID)，请检查 agent 日志"
  fi
}

# =============================================================================
#                           ② 面板/PG/Prom/Grafana 部署
# =============================================================================
# 这些是我补充的“栈”部署，独立于 Agent，不会覆盖你已有逻辑
PG_URL_DEFAULT="${PG_URL:-http://127.0.0.1:19091}"
REPO_RAW="https://raw.githubusercontent.com/jgwycom/TrafficCop/main"
INSTALL_DIR="/opt/trafficcop"
DB_DIR="$INSTALL_DIR/data"
DB_PATH="$DB_DIR/trafficcop.db"
ENV_PATH="$INSTALL_DIR/settings.env"
PROM_PORT_DEFAULT="19090"
PANEL_PORT_DEFAULT="8000"

fetch_to() { # fetch_to <url> <dst>
  local url="$1" dst="$2"
  curl -fsSL "$url" -o "$dst"
}
ensure_dir() { install -d "$1"; }
replace_line() { # replace_line <file> <key=> <new_line>
  local f="$1" key="$2" line="$3"
  if [[ -f "$f" ]] && grep -q "^${key}" "$f"; then
    sed -i "s|^${key}.*|${line}|g" "$f"
  else
    echo "$line" >>"$f"
  fi
}
write_if_absent() { # write_if_absent <url> <dst>
  local url="$1" dst="$2"
  if [[ -f "$dst" ]]; then
    log "保留已存在文件：$dst"
  else
    fetch_to "$url" "$dst"
    log "已写入：$dst"
  fi
}
docker_compose_up() {
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      (cd "$INSTALL_DIR" && docker compose up -d)
    elif command -v docker-compose >/dev/null 2>&1; then
      (cd "$INSTALL_DIR" && docker-compose up -d)
    else
      warn "未发现 docker compose 插件，已跳过自动拉起。请手动在 $INSTALL_DIR 运行：docker compose up -d"
    fi
  else
    warn "未安装 docker；已跳过容器编排。你可在本机直接以 Python 方式运行面板，或安装 Docker 后再 docker compose up -d。"
  fi
}

install_or_upgrade_stack() {
  root
  need curl
  ensure_dir "$INSTALL_DIR"
  ensure_dir "$DB_DIR"
  log "获取最新面板与编排文件（保留已有 settings.env）..."
  fetch_to        "$REPO_RAW/docker-compose.yml"        "$INSTALL_DIR/docker-compose.yml"
  write_if_absent "$REPO_RAW/settings.env"              "$ENV_PATH"
  fetch_to        "$REPO_RAW/app.py"                    "$INSTALL_DIR/app.py"
  write_if_absent "$REPO_RAW/trafficcop.json"           "$INSTALL_DIR/trafficcop.json"
  if curl -fsI "$REPO_RAW/trafficcop-dashboard.txt" >/dev/null 2>&1; then
    write_if_absent "$REPO_RAW/trafficcop-dashboard.txt" "$INSTALL_DIR/trafficcop-dashboard.txt"
  fi

  # 注入/覆盖 Pushgateway（仅替换 PG_URL 行，其它保持）
  replace_line "$ENV_PATH" "PG_URL=" "PG_URL=${PG_URL_DEFAULT}"

  log "尝试启动/重启容器编排（Prometheus $PROM_PORT_DEFAULT / Pushgateway 19091 / Grafana 3000 / 面板 $PANEL_PORT_DEFAULT）..."
  docker_compose_up

  # 落地 systemd 双保险
  setup_systemd_reset_timer

  log "面板/监控栈安装或升级完成 ✅"
}

# =============================================================================
#                       ③ systemd 双保险：重置日月度基线
# =============================================================================
setup_systemd_reset_timer() {
  root
  need python3
  cat >/usr/local/bin/trafficcop-reset.py <<'PY'
#!/usr/bin/env python3
# 每日 00:10 执行：对“到达 reset_day 的节点”写入当月基线（rx_base/tx_base）
# 数据源：Prometheus traffic_rx_bytes_total/traffic_tx_bytes_total（job=trafficcop, instance=<node>, iface=<if>）
# 目标库：/opt/trafficcop/data/trafficcop.db  表：baselines(instance, iface, month_key, rx_base, tx_base)
import os, json, sqlite3, urllib.request, urllib.parse
from datetime import datetime, timezone, timedelta

INSTALL_DIR="/opt/trafficcop"
ENV_PATH=f"{INSTALL_DIR}/settings.env"
DB_PATH=f"{INSTALL_DIR}/data/trafficcop.db"

def load_env(path):
    env={}
    if os.path.exists(path):
        for line in open(path, 'r', encoding='utf-8'):
            line=line.strip()
            if not line or line.startswith('#') or '=' not in line: continue
            k,v=line.split('=',1); env[k.strip()]=v.strip()
    return env

def prom_query(prom_url, expr):
    q=urllib.parse.urlencode({"query": expr})
    url=f"{prom_url}/api/v1/query?{q}"
    with urllib.request.urlopen(url, timeout=10) as r:
        data=json.loads(r.read().decode())
    if data.get("status")!="success": return []
    return data["data"]["result"]

def main():
    # 使用上海时区与面板保持一致
    cst = timezone(timedelta(hours=8))
    now = datetime.now(cst)
    today = now.day
    month_key = now.strftime("%Y-%m")
    env=load_env(ENV_PATH)
    prom_url=env.get("PROM_URL","http://127.0.0.1:19090")

    if not os.path.exists(DB_PATH): return
    conn=sqlite3.connect(DB_PATH)
    conn.row_factory=sqlite3.Row
    cur=conn.cursor()
    # 取到期节点
    try:
        cur.execute("SELECT instance, reset_day FROM nodes")
    except sqlite3.Error:
        conn.close(); return
    nodes=[dict(r) for r in cur.fetchall()]
    due=[n["instance"] for n in nodes if int(n.get("reset_day") or 1)==today]
    if not due:
      conn.close(); return

    # 拉取 rx/tx 指标（按节点聚合 iface）
    def pull_latest(metric, inst):
        res=prom_query(prom_url, f'{metric}{{job="trafficcop",instance="{inst}"}}')
        out={}
        for s in res:
            iface=s.get("metric",{}).get("iface") or "eth0"
            v = int(float(s.get("value",[0,"0"])[1]))
            out[iface]=v
        return out

    upserts=0
    for inst in due:
        rx=pull_latest("traffic_rx_bytes_total", inst)
        tx=pull_latest("traffic_tx_bytes_total", inst)
        for iface in set(list(rx.keys())+list(tx.keys())):
            rxv=rx.get(iface,0); txv=tx.get(iface,0)
            cur.execute("""
                INSERT INTO baselines(instance, iface, month_key, rx_base, tx_base)
                VALUES(?,?,?,?,?)
                ON CONFLICT(instance,iface,month_key) DO UPDATE SET
                    rx_base=excluded.rx_base,
                    tx_base=excluded.tx_base,
                    created_at=datetime('now')
            """, (inst, iface, month_key, rxv, txv))
            upserts+=1
    conn.commit(); conn.close()
    print(f"[trafficcop-reset] month_key={month_key} updated rows={upserts} for nodes={due}")

if __name__=="__main__":
    try: main()
    except Exception as e:
        print(f"[trafficcop-reset] error: {e}")
PY
  chmod +x /usr/local/bin/trafficcop-reset.py

  cat >/etc/systemd/system/trafficcop-reset.service <<EOF
[Unit]
Description=TrafficCop 月度基线重置（systemd 双保险）
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/bin/trafficcop-reset.py

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/systemd/system/trafficcop-reset.timer <<'EOF'
[Unit]
Description=每日 00:10 触发 baselines upsert（与面板 APScheduler 保持一致）

[Timer]
OnCalendar=*-*-* 00:10:00
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now trafficcop-reset.timer
  log "已启用 systemd 双保险：trafficcop-reset.timer（每日 00:10）"
}

# =============================================================================
#                              ④ 常用辅助/菜单
# =============================================================================
uninstall_stack() {
  root
  if command -v docker >/dev/null 2>&1; then
    if docker compose version >/dev/null 2>&1; then
      (cd "$INSTALL_DIR" && docker compose down || true)
    elif command -v docker-compose >/dev/null 2>&1; then
      (cd "$INSTALL_DIR" && docker-compose down || true)
    fi
  fi
  systemctl disable --now trafficcop-reset.timer 2>/dev/null || true
  rm -f /etc/systemd/system/trafficcop-reset.{service,timer}
  systemctl daemon-reload
  log "已停止面板/监控栈与定时任务；未删除 $INSTALL_DIR 与数据（如需清理请手动删除）。"
}

status_stack() {
  echo "===== TrafficCop 栈状态 ====="
  if command -v docker >/dev/null 2>&1; then
    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}' || true
  else
    echo "Docker 未安装/未在用；若以裸跑方式启动面板，请检查 Python 进程与端口。"
  fi
  systemctl status trafficcop-reset.timer 2>/dev/null || echo "未检测到 reset 定时任务"
  [[ -f "$ENV_PATH" ]] && { echo; echo "settings.env（前 120 行）:"; sed -n '1,120p' "$ENV_PATH"; }
  echo "============================="
}

config_telegram() {
  root
  ensure_dir "$(dirname "$ENV_PATH")"
  touch "$ENV_PATH"
  read -rp "请输入 TG_BOT_TOKEN: " token
  read -rp "请输入 TG_CHAT_ID: " chatid
  replace_line "$ENV_PATH" "TG_BOT_TOKEN=" "TG_BOT_TOKEN=${token}"
  replace_line "$ENV_PATH" "TG_CHAT_ID="    "TG_CHAT_ID=${chatid}"
  log "已写入 $ENV_PATH；容器模式请 docker compose up -d 以加载最新环境。"
}

config_daily_times() {
  root
  ensure_dir "$(dirname "$ENV_PATH")"
  touch "$ENV_PATH"
  read -rp "每日汇总小时(0-23) [默认 00]: " sH; sH="${sH:-00}"
  read -rp "每日汇总分钟(0-59) [默认 20]: " sM; sM="${sM:-20}"
  read -rp "基线重置小时(0-23) [默认 00]: " bH; bH="${bH:-00}"
  read -rp "基线重置分钟(0-59) [默认 10]: " bM; bM="${bM:-10}"
  replace_line "$ENV_PATH" "DAILY_SUMMARY_HOUR="   "DAILY_SUMMARY_HOUR=${sH}"
  replace_line "$ENV_PATH" "DAILY_SUMMARY_MINUTE=" "DAILY_SUMMARY_MINUTE=${sM}"
  replace_line "$ENV_PATH" "DAILY_BASELINE_HOUR="  "DAILY_BASELINE_HOUR=${bH}"
  replace_line "$ENV_PATH" "DAILY_BASELINE_MINUTE=" "DAILY_BASELINE_MINUTE=${bM}"
  # 同步 systemd timer（双保险）
  if [[ -f /etc/systemd/system/trafficcop-reset.timer ]]; then
    sed -i "s|^OnCalendar=.*|OnCalendar=*-*-* ${bH}:${bM}:00|" /etc/systemd/system/trafficcop-reset.timer
    systemctl daemon-reload
    systemctl restart trafficcop-reset.timer
  fi
  log "已更新每日任务时间；容器模式请 up -d 让面板重载环境。"
}

menu() {
  clear
  echo -e "\e[36m============ TrafficCop 管理面板 ============\e[0m"
  echo "1. 安装/升级（先 Agent 后面板栈 + systemd 双保险）"
  echo "2. 卸载面板/监控栈（不删数据）"
  echo "3. 查看状态"
  echo "4. 配置 Telegram 推送"
  echo "5. 调整每日任务时间（汇总/基线）"
  echo "6. 退出"
  echo "============================================"
  read -rp "请输入选项: " num
  case "$num" in
    1) install_agent; install_or_upgrade_stack ;;
    2) uninstall_stack ;;
    3) status_stack ;;
    4) config_telegram ;;
    5) config_daily_times ;;
    6) exit 0 ;;
    *) echo "输入错误"; sleep 1; menu ;;
  esac
}

# =============================================================================
#                                   入口
# =============================================================================
SHOW_MENU=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --menu) SHOW_MENU=1; shift ;;
    -y|--yes|--overwrite) shift ;;  # 兼容你旧的一键参数，不做破坏
    *) shift ;;
  esac
done

if [[ $SHOW_MENU -eq 1 ]]; then
  menu
else
  # 默认一键：跟你的预期一致，直接跑 Agent + 栈
  install_agent
  install_or_upgrade_stack
fi
