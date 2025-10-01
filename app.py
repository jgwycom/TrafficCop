#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# 面板机：TrafficCop 管控后端（Flask + SQLite + APScheduler）
# 功能：
# - 节点 CRUD / 配置下发 / 在线状态
# - 管理操作：Prometheus reload、清空 TSDB、Grafana 刷新
# - 调度任务：自动同步 Prometheus 节点、月度基线、每日汇总
# - "模式二：面板管控"——节点每分钟从 /config/<instance> 拉配置

import os
import sqlite3
import subprocess
from contextlib import contextmanager
import requests
from flask import Flask, jsonify, request, Response
from flask_cors import CORS
from apscheduler.schedulers.background import BackgroundScheduler
from dotenv import load_dotenv
from datetime import datetime, timedelta
import logging

# ========== 环境变量 ==========
load_dotenv("settings.env")
PROM_URL = os.getenv("PROM_URL", "http://127.0.0.1:19090")
PG_URL = os.getenv("PG_URL", "http://127.0.0.1:19091")
GRAFANA_URL = os.getenv("GRAFANA_URL", "http://127.0.0.1:3000")
GRAFANA_API_TOKEN = os.getenv("GRAFANA_API_TOKEN", "")

# 【新增】同步时使用的 job 名称（默认 trafficcop）
PROM_JOB_NAME = os.getenv("PROM_JOB_NAME", "trafficcop")

TG_BOT_TOKEN = os.getenv("TG_BOT_TOKEN", "")
TG_CHAT_ID = os.getenv("TG_CHAT_ID", "")

DAILY_SUMMARY_HOUR = int(os.getenv("DAILY_SUMMARY_HOUR", "0"))
DAILY_SUMMARY_MINUTE = int(os.getenv("DAILY_SUMMARY_MINUTE", "20"))
DAILY_BASELINE_HOUR = int(os.getenv("DAILY_BASELINE_HOUR", "0"))
DAILY_BASELINE_MINUTE = int(os.getenv("DAILY_BASELINE_MINUTE", "10"))

PANEL_HOST = os.getenv("PANEL_HOST", "0.0.0.0")
PANEL_PORT = int(os.getenv("PANEL_PORT", "8000"))

DB_PATH = "/app/data/trafficcop.db"   # ✅ 修改：容器实际使用的数据库路径

# ========== Flask ==========
app = Flask(__name__)
CORS(app)

# ========== 配置日志 ==========
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# ========== DB ==========
@contextmanager
def db_conn():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    try:
        yield conn
    finally:
        conn.commit()
        conn.close()

def init_db():
    with db_conn() as db:
        db.execute("""
        CREATE TABLE IF NOT EXISTS nodes (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sort_order INTEGER DEFAULT 0,
            instance TEXT UNIQUE NOT NULL,
            display_name TEXT DEFAULT '',
            reset_day INTEGER DEFAULT 1,
            limit_bytes INTEGER DEFAULT 0,
            limit_mode TEXT DEFAULT 'double',
            bandwidth_bps INTEGER DEFAULT 0,
            created_at TEXT DEFAULT (datetime('now'))
        );
        """)
        db.execute("CREATE INDEX IF NOT EXISTS idx_nodes_sort ON nodes(sort_order DESC, id DESC);")

        db.execute("""
        CREATE TABLE IF NOT EXISTS baselines (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            instance TEXT NOT NULL,
            iface TEXT NOT NULL,
            month_key TEXT NOT NULL,
            rx_base INTEGER NOT NULL,
            tx_base INTEGER NOT NULL,
            created_at TEXT DEFAULT (datetime('now')),
            UNIQUE(instance, iface, month_key)
        );
        """)

# 确保数据目录存在
os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
init_db()

# ========== 工具 ==========
def now_ts():
    return datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")

def get_current_date_tag():
    """获取当前日期标签，格式：YYYYMMDD"""
    return datetime.now().strftime("%Y%m%d")

def get_date_tag_from_timestamp(timestamp):
    """从时间戳获取日期标签"""
    if isinstance(timestamp, (int, float)):
        return datetime.fromtimestamp(timestamp).strftime("%Y%m%d")
    return datetime.now().strftime("%Y%m%d")

def prom_instant_query(expr: str):
    url = f"{PROM_URL}/api/v1/query"
    r = requests.get(url, params={"query": expr}, timeout=10)
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError(f"Prom query failed: {data}")
    return data["data"]["result"]

def prom_range_query(expr: str, start: str, end: str, step: str = "1h"):
    """范围查询，支持带日期标签的指标"""
    url = f"{PROM_URL}/api/v1/query_range"
    params = {
        "query": expr,
        "start": start,
        "end": end,
        "step": step
    }
    r = requests.get(url, params=params, timeout=30)
    r.raise_for_status()
    data = r.json()
    if data.get("status") != "success":
        raise RuntimeError(f"Prom range query failed: {data}")
    return data["data"]["result"]

def pg_delete_instance(job: str, instance: str):
    try:
        url = f"{PG_URL}/metrics/job/{job}/instance/{instance}"
        requests.delete(url, timeout=8)
    except Exception:
        pass

def tg_send(text: str):
    """
    Telegram 消息推送
    统一使用环境变量：TG_BOT_TOKEN + TG_CHAT_ID
    """
    token = os.getenv("TG_BOT_TOKEN")
    chat_id = os.getenv("TG_CHAT_ID")

    if not token or not chat_id:
        logger.warning("TG_BOT_TOKEN 或 TG_CHAT_ID 未配置，跳过推送")
        return

    url = f"https://api.telegram.org/bot{token}/sendMessage"
    params = {
        "chat_id": chat_id,
        "text": text
    }

    try:
        resp = requests.get(url, params=params, timeout=10)
        if resp.status_code == 200:
            logger.info("✅ TG 推送成功")
        else:
            logger.error(f"❌ TG 推送失败: {resp.status_code}, {resp.text}")
    except Exception as e:
        logger.exception("TG 推送异常", exc_info=e)

def hostport_from_url(url: str) -> str:
    """
    提取 URL 中的 host:port 部分
    例如: http://127.0.0.1:19091 -> 127.0.0.1:19091
    """
    try:
        from urllib.parse import urlparse
        u = urlparse(url)
        return f"{u.hostname}:{u.port}" if u.port else u.hostname
    except Exception:
        return url

# ========== 修复：统一使用 node_id 获取流量数据 ==========
def get_traffic_by_node_id(node_id):
    """
    根据 node_id 获取流量数据
    """
    try:
        # 查询 RX 流量
        rx_query = f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}}'
        rx_results = prom_instant_query(rx_query)
        
        # 查询 TX 流量  
        tx_query = f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}}'
        tx_results = prom_instant_query(tx_query)
        
        rx_total = 0
        tx_total = 0
        
        # 累加所有接口的 RX 流量
        for s in rx_results:
            if "value" in s:
                rx_total += float(s["value"][1])
        
        # 累加所有接口的 TX 流量
        for s in tx_results:
            if "value" in s:
                tx_total += float(s["value"][1])
                
        return rx_total, tx_total
        
    except Exception as e:
        logger.warning(f"获取节点 {node_id} 流量失败: {e}")
        return 0, 0

# ========== 节点发现（增强版） ==========
def discover_instances():
    """
    优先：/api/v1/label/instance/values?match[]=up{job="<PROM_JOB_NAME>"}
    其次：/api/v1/targets -> data.activeTargets[*].labels.instance （job 匹配）
    兜底：/api/v1/query?query=up -> metric.instance
    """
    inst = set()

    # 1) label values（带 match 过滤到指定 job）
    try:
        url = f"{PROM_URL}/api/v1/label/instance/values"
        r = requests.get(url, params={"match[]": f'up{{job="{PROM_JOB_NAME}"}}'}, timeout=8)
        r.raise_for_status()
        data = r.json()
        if data.get("status") == "success":
            for v in data.get("data", []):
                if v:
                    inst.add(v)
    except Exception as e:
        logger.warning(f"discover via label values failed: {e}")

    # 2) targets
    if not inst:
        try:
            r = requests.get(f"{PROM_URL}/api/v1/targets", timeout=8)
            r.raise_for_status()
            data = r.json()
            targets = data.get("data", {}).get("activeTargets", []) or []
            for t in targets:
                labels = t.get("labels", {})
                if labels.get("job") == PROM_JOB_NAME:
                    iv = labels.get("instance")
                    if iv:
                        inst.add(iv)
        except Exception as e:
            logger.warning(f"discover via targets failed: {e}")

    # 3) up 查询兜底（不限制 job，但能把 instance 找出来）
    if not inst:
        try:
            res = prom_instant_query("up")
            for s in res:
                iv = s.get("metric", {}).get("instance")
                if iv:
                    inst.add(iv)
        except Exception as e:
            logger.warning(f"discover via query up failed: {e}")

    return sorted(inst)

# ========== 修复：节点自动同步 ==========
def sync_nodes_from_prometheus():
    """
    从 Prometheus 抓取节点信息并同步到数据库
    基于 node_id 进行同步，instance 名称可以随时编辑
    """
    try:
        # 修复：使用正确的 Prometheus series 查询格式
        series = prom_series([
            f'push_time_seconds{{job="{PROM_JOB_NAME}"}}',
            f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}"}}',
            f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}"}}'
        ])
    except Exception as e:
        logger.warning(f"sync_nodes_from_prometheus/series failed: {e}")
        return

    pg_hp = hostport_from_url(PG_URL)
    prom_self = "localhost:9090"

    for s in series:
        labels = dict(s)
        inst = labels.get("instance")
        nid = labels.get("node_id")

        # 跳过 pushgateway / prometheus 自身
        if inst in (pg_hp, prom_self):
            continue

        # 必须有 node_id 才处理
        if not nid or not nid.isdigit():
            continue
            
        nid = int(nid)
        
        with db_conn() as db:
            cur = db.execute("SELECT id, instance FROM nodes WHERE id=?", (nid,))
            existing = cur.fetchone()
            
            if not existing:
                # 新节点注册
                db.execute("""
                    INSERT INTO nodes(id, instance, display_name, sort_order, reset_day, limit_bytes, limit_mode, bandwidth_bps)
                    VALUES(?,?,?,?,?,?,?,?)
                """, (nid, inst, inst, 0, 1, 0, "double", 0))
                logger.info(f"新节点注册: node_id={nid}, instance={inst}")
            else:
                # 已存在节点，更新 instance（如果不同）
                existing_inst = existing["instance"]
                if existing_inst != inst:
                    db.execute("UPDATE nodes SET instance=? WHERE id=?", (inst, nid))
                    logger.info(f"更新实例名称: node_id={nid}, 从 {existing_inst} 改为 {inst}")

# === 修复：Prometheus /api/v1/series 多匹配查询 ===
def prom_series(matchers):
    """
    matchers: list[str], 例如 [
        'push_time_seconds{job="trafficcop"}',
        'traffic_rx_bytes_total{job="trafficcop"}',
    ]
    返回：list[dict]，每个元素是一个 label-set（直接可 dict(s)）
    """
    try:
        params = []
        for m in matchers:
            params.append(("match[]", m))
        resp = requests.get(f"{PROM_URL}/api/v1/series", params=params, timeout=5)
        resp.raise_for_status()
        js = resp.json()
        if js.get("status") != "success":
            raise RuntimeError(f"bad status: {js}")
        return js.get("data", [])
    except Exception as e:
        logger.warning(f"prom_series failed: {e}")
        return []

# ========== 节点 CRUD ==========
@app.post("/nodes/register")
def register_node():
    """
    节点初次安装时调用：
    - 若已有 node_id（例如重装后保留），传入则直接返回该节点信息；
    - 若没有，面板创建一条记录并分配自增 ID（SQLite AUTOINCREMENT 保证不复用）。
    请求JSON：
      { "instance": "node-01", "display_name": "node-01" }
    响应JSON：
      { "ok": true, "node_id": 12, "push_path": "/metrics/job/trafficcop/node_id/12/instance/node-01" }
    """
    data = request.get_json(force=True) if request.data else {}
    instance = (data.get("instance") or "").strip() or None
    display_name = (data.get("display_name") or instance or "").strip()

    with db_conn() as db:
        # 建一条空位即可（不要求 instance 必填，后续可改名）
        cur = db.execute("""
            INSERT INTO nodes(instance, display_name, sort_order, reset_day, limit_bytes, limit_mode, bandwidth_bps)
            VALUES(?,?,?,?,?,?,?)
        """, (instance or f"pending-{datetime.utcnow().timestamp():.0f}", display_name or "", 0, 1, 0, "double", 0))
        node_id = cur.lastrowid

        # 取回完整记录
        cur = db.execute("SELECT * FROM nodes WHERE id=?", (node_id,))
        row = dict(cur.fetchone())

    # 告诉安装脚本：Pushgateway 分组路径要带 node_id（终身ID）+ instance
    # 例：http://<PG_URL>/metrics/job/trafficcop/node_id/12/instance/node-01
    push_path = f"/metrics/job/trafficcop/node_id/{node_id}/instance/{instance or f'node-{node_id}'}"
    return jsonify({"ok": True, "node_id": node_id, "push_path": push_path, "row": row})

@app.post("/admin/force-update/<int:node_id>")
def force_update_node(node_id: int):
    """强制更新指定节点的流量数据 - 使用 node_id"""
    try:
        # 先删除该节点的 Pushgateway 数据
        url = f"{PG_URL}/metrics/job/{PROM_JOB_NAME}/node_id/{node_id}"
        requests.delete(url, timeout=8)

        # 立即写入 0 值，保证面板立刻归零
        metrics = f"""
traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}} 0
traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}} 0
"""
        requests.post(url, data=metrics.encode("utf-8"), timeout=8)

        log_msg = f"已强制更新并清零节点 {node_id} 的流量数据"
        logger.info(log_msg)
        return jsonify({"ok": True, "msg": log_msg})
    except Exception as e:
        return jsonify({"ok": False, "msg": str(e)}), 500

@app.get("/admin/force-update-web/<int:node_id>")
def force_update_node_web(node_id: int):
    """Web 版本的强制更新（清零后立即归零显示）"""
    try:
        with db_conn() as db:
            cur = db.execute("SELECT instance FROM nodes WHERE id=?", (node_id,))
            row = cur.fetchone()
            if not row:
                return Response("<h3>节点不存在</h3>", mimetype="text/html", status=404)
            instance = row["instance"]

        # 删除 Pushgateway 数据
        url = f"{PG_URL}/metrics/job/{PROM_JOB_NAME}/node_id/{node_id}"
        requests.delete(url, timeout=8)

        # 写入 0 值
        metrics = f"""
traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}} 0
traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}} 0
"""
        requests.post(url, data=metrics.encode("utf-8"), timeout=8)

        html = f"""<html><body style="font-family:system-ui; padding:24px;">
        <h3>✅ 已强制更新并清零节点 {node_id}({instance})</h3>
        <p>节点的流量数据已被清零，并立即在面板归零。</p>
        <p><a href="/nodes" target="_blank">返回节点列表</a></p>
        </body></html>"""
        return Response(html, mimetype="text/html")
    except Exception as e:
        return Response(f"<pre>更新失败: {e}</pre>", mimetype="text/html", status=500)

def get_traffic_with_date_tags(node_id=None, instance=None, date_tag=None):
    """
    查询带日期标签的流量数据 - 优先使用 node_id
    """
    if not date_tag:
        date_tag = get_current_date_tag()
    
    # 优先使用 node_id
    if node_id:
        base_query = f'{{job="{PROM_JOB_NAME}", date="{date_tag}", node_id="{node_id}"}}'
    elif instance:
        base_query = f'{{job="{PROM_JOB_NAME}", date="{date_tag}", instance="{instance}"}}'
    else:
        return {}
    
    queries = {
        'rx': f'traffic_rx_bytes_total{base_query}',
        'tx': f'traffic_tx_bytes_total{base_query}',
        'push_time': f'push_time_seconds{base_query}'
    }
    
    results = {}
    for metric, query in queries.items():
        try:
            data = prom_instant_query(query)
            results[metric] = data
        except Exception as e:
            logger.warning(f"Query failed for {metric}: {e}")
            results[metric] = []
    
    return results

def get_traffic_history(node_id, days=7):
    """
    获取节点历史流量数据 - 使用 node_id
    """
    end_time = datetime.now()
    start_time = end_time - timedelta(days=days)
    
    start_str = start_time.isoformat() + 'Z'
    end_str = end_time.isoformat() + 'Z'
    
    # 使用 node_id 查询
    rx_query = f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}}'
    tx_query = f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", node_id="{node_id}"}}'
    
    try:
        rx_data = prom_range_query(rx_query, start_str, end_str, "1h")
        tx_data = prom_range_query(tx_query, start_str, end_str, "1h")
        
        return {
            'rx': rx_data,
            'tx': tx_data,
            'period': {
                'start': start_str,
                'end': end_str,
                'days': days
            }
        }
    except Exception as e:
        logger.error(f"Failed to get traffic history for node {node_id}: {e}")
        return None

#  === 工具函数，人类可读字节 ===
def human_bytes(n: int) -> str:
    if not n:
        return "0 B"
    units = ["B","KB","MB","GB","TB","PB"]
    v = float(n)
    i = 0
    while v >= 1024 and i < len(units)-1:
        v /= 1024.0
        i += 1
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return f"{s} {units[i]}"

def gb_str_from_bytes(b: int) -> str:
    gb = (b or 0) / (1024**3)
    return f"{gb:.2f}".rstrip("0").rstrip(".")

@app.get("/nodes")
def list_nodes():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM nodes ORDER BY sort_order ASC, id ASC")
    rows = cur.fetchall()
    conn.close()

    out = []
    for x in rows:
        node_id = str(x["id"])
        inst = x["instance"]
        online = True

        rx, tx = get_traffic_by_node_id(node_id)
        row_dict = dict(x)  # ✅ 转换成 dict，方便用 .get()

        limit_mode = row_dict.get("limit_mode", "double")
        if limit_mode == "upload":
            used_val = tx
        elif limit_mode == "download":
            used_val = rx
        else:
            used_val = rx + tx

        limit_bytes = row_dict.get("limit_bytes", 0)
        usage_ratio = None
        if limit_bytes and limit_bytes > 0:
            usage_ratio = round(used_val / limit_bytes * 100, 2)

        mode_map = {"double": "双向", "download": "下行", "upload": "上行"}
        limit_mode_cn = mode_map.get(limit_mode, limit_mode)

        row = {
            "排序ID":        x["sort_order"],
            "节点ID":        x["id"],
            "显示名称":      x["display_name"],
            "实例":          x["instance"],
            "限额(GB)":      gb_str_from_bytes(limit_bytes),
            "bandwidth_bps": row_dict.get("bandwidth_bps", 0),
            "限流模式":      limit_mode_cn,
            "在线状态":      online,
            "重置日":        row_dict.get("reset_day", 1),
            "used_bytes":    used_val,   # ✅ 新增数值字段
            "已用流量":      human_bytes(used_val),
            "使用比例(%)":   usage_ratio if usage_ratio is not None else "不限",
            "编辑":          f"http://45.78.23.232:8000/edit-node?id={x['id']}"
        }
        out.append(row)

    return jsonify(out)


@app.get("/admin/debug-date-metrics")
def admin_debug_date_metrics():
    """调试日期标签指标"""
    current_date = get_current_date_tag()
    out = {
        "current_date_tag": current_date,
        "prom_job": PROM_JOB_NAME
    }
    
    # 测试各种日期标签查询
    test_queries = [
        f'push_time_seconds{{job="{PROM_JOB_NAME}", date="{current_date}"}}',
        f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", date="{current_date}"}}',
        f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", date="{current_date}"}}',
        f'push_time_seconds{{job="{PROM_JOB_NAME}"}}',  # 无日期标签对比
    ]
    
    for query in test_queries:
        try:
            result = prom_instant_query(query)
            out[query] = {
                "count": len(result),
                "samples": result[:3]  # 前3个样本
            }
        except Exception as e:
            out[query] = {"error": str(e)}
    
    return jsonify(out)

# === 工具函数：人类可读字节、GB 字符串 ===
def _human_bytes(n: float) -> str:
    try:
        v = float(n or 0)
    except Exception:
        v = 0.0
    units = ["B", "KB", "MB", "GB", "TB", "PB"]
    i = 0
    while v >= 1024 and i < len(units) - 1:
        v /= 1024.0
        i += 1
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return f"{s} {units[i]}"

def _gb_str_from_bytes(b: int) -> str:
    try:
        gb = (b or 0) / (1024 ** 3)
    except Exception:
        gb = 0.0
    # 保留两位小数，但去掉尾随 0
    return f"{gb:.2f}".rstrip("0").rstrip(".")

# === 新增：仅用于 Grafana 表格的精简视图，不影响 /nodes ===
@app.get("/nodes_table")
def list_nodes_table():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    cur = conn.cursor()
    cur.execute("SELECT * FROM nodes ORDER BY sort_order ASC, id ASC")
    rows = cur.fetchall()
    conn.close()

    rx_map, tx_map = {}, {}
    # 可以根据 Prometheus 或数据库数据更新 rx_map/tx_map

    out = []
    mode_map = {"double": "双向", "download": "下行", "upload": "上行"}
    for x in rows:
        node_id = str(x["id"])
        inst = x["instance"]
        online = True
        row_dict = dict(x)  # ✅ 转换成 dict

        rx = rx_map.get("id:" + node_id) or rx_map.get("inst:" + inst, 0)
        tx = tx_map.get("id:" + node_id) or tx_map.get("inst:" + inst, 0)

        limit_mode = row_dict.get("limit_mode", "double")
        if limit_mode == "upload":
            used_val = tx
        elif limit_mode == "download":
            used_val = rx
        else:
            used_val = (rx or 0) + (tx or 0)

        limit_bytes = row_dict.get("limit_bytes", 0)
        usage_ratio = None
        if limit_bytes and limit_bytes > 0:
            usage_ratio = round(used_val / limit_bytes * 100, 2)

        row = {
            "排序ID":      x["sort_order"],
            "节点ID":      x["id"],
            "显示名称":    x["display_name"],
            "实例":        x["instance"],
            "限额(GB)":    _gb_str_from_bytes(limit_bytes),
            "限流模式":    mode_map.get(limit_mode, limit_mode),
            "在线状态":    online,
            "重置日":      row_dict.get("reset_day", 1),
            "used_bytes":  used_val,   # ✅ 新增数值字段
            "已用流量":    _human_bytes(used_val),
            "使用比例(%)": usage_ratio if usage_ratio is not None else "不限",
            "编辑":        f"http://45.78.23.232:8000/edit-node?id={x['id']}",
        }
        out.append(row)

    return jsonify(out)


@app.post("/nodes")
def create_node():
    data = request.get_json(force=True)
    instance = data.get("instance", "").strip()
    if not instance or not all(c.isalnum() or c in "._-" for c in instance):
        return jsonify({"error":"invalid instance"}), 400

    display_name = data.get("display_name", instance)  # ⚡ 如果没传，用 instance 作为默认显示名
    sort_order = int(data.get("sort_order", 0))
    reset_day = int(data.get("reset_day", 1))
    limit_bytes = int(data.get("limit_bytes", 0))
    limit_mode = data.get("limit_mode", "double")
    bandwidth_bps = int(data.get("bandwidth_bps", 0))

    with db_conn() as db:
        db.execute("""
            INSERT INTO nodes(instance, display_name, sort_order, reset_day, limit_bytes, limit_mode, bandwidth_bps)
            VALUES(?,?,?,?,?,?,?)
        """, (instance, display_name, sort_order, reset_day, limit_bytes, limit_mode, bandwidth_bps))

        cur = db.execute("SELECT * FROM nodes WHERE instance=?", (instance,))
        node = dict(cur.fetchone())

    return jsonify(node), 201

@app.patch("/nodes/<int:node_id>")
def update_node(node_id: int):
    data = request.get_json(force=True)
    cols = ["sort_order", "display_name", "reset_day", "limit_bytes", "limit_mode", "bandwidth_bps", "instance"]
    sets, vals = [], []
    for c in cols:
        if c in data:
            sets.append(f"{c}=?")
            vals.append(data[c])
    if not sets:
        return jsonify({"error":"empty update"}), 400

    vals.append(node_id)
    with db_conn() as db:
        db.execute(f"UPDATE nodes SET {', '.join(sets)} WHERE id=?", vals)
        cur = db.execute("SELECT * FROM nodes WHERE id=?", (node_id,))
        row = cur.fetchone()
        if not row:
            return jsonify({"error":"not found"}), 404
        node = dict(row)

    return jsonify(node)

# —— 节点编辑（表单） ————————————————————————————————————————————————
# 同时支持两种路由：
# 1) /edit-node?id=<id>    （配合 Grafana 按钮的 query 形式）
# 2) /edit-node/<id>       （直接路径形式）
def _coerce_int(v, default=0, min_value=None, max_value=None):
    try:
        x = int(v)
    except Exception:
        x = default
    if min_value is not None:
        x = max(min_value, x)
    if max_value is not None:
        x = min(max_value, x)
    return x

def _limit_mode_options(current):
    # (值, 中文名, 是否选中)
    opts = [
        ("double",  "双向",   current == "double"),
        ("download","仅下行", current == "download"),
        ("upload",  "仅上行", current == "upload"),
    ]
    return "\n".join(
        f'<option value="{v}" {"selected" if sel else ""}>{cn}</option>'
        for v, cn, sel in opts
    )

@app.get("/edit-node")
@app.get("/edit-node/<int:path_node_id>")
def edit_node_form(path_node_id=None):
    from html import escape
    node_id = path_node_id or _coerce_int(request.args.get("id"), 0)
    if not node_id:
        return Response("<h3>缺少 node_id</h3>", mimetype="text/html", status=400)

    with db_conn() as db:
        cur = db.execute("SELECT * FROM nodes WHERE id=?", (node_id,))
        row = cur.fetchone()
        if not row:
            return Response("<h3>节点不存在</h3>", mimetype="text/html", status=404)
        n = dict(row)

    # 展示时用 GiB，保留整数输入更直观；小数可支持到 2 位
    limit_gb = 0 if int(n["limit_bytes"]) == 0 else (float(n["limit_bytes"]) / (1024**3))
    limit_gb_str = f"{limit_gb:.2f}".rstrip("0").rstrip(".")  # 去掉无用小数

    html = f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8" />
  <title>编辑节点 {node_id}</title>
  <style>
    body {{ font-family: system-ui, -apple-system, Segoe UI, Roboto, sans-serif; padding: 24px; }}
    form {{ max-width: 560px; }}
    label {{ display:block; margin: 10px 0 4px; color:#333; }}
    input, select {{ width: 100%; padding: 8px 10px; box-sizing: border-box; }}
    .row {{ display:flex; gap:12px; }}
    .row .col {{ flex:1; }}
    .actions {{ margin-top:16px; display:flex; gap:8px; }}
    button {{ padding: 8px 12px; cursor: pointer; }}
    .hint {{ color:#888; font-size:12px; }}
  </style>
</head>
<body>
  <h2>编辑节点 ID {node_id}</h2>
  <form method="post" action="/edit-node?id={node_id}">
    <label>排序ID</label>
    <input type="number" name="sort_order" value="{n['sort_order']}" />

    <label>显示名称</label>
    <input type="text" name="display_name" value="{escape(n['display_name'] or '')}" />

    <label>节点名称</label>
    <input type="text" name="display_name" value="{escape(n['instance'] or '')}" />

    <div class="row">
      <div class="col">
        <label>限额 (GB)</label>
        <input type="text" name="limit_gb" value="{limit_gb_str}" />
        <div class="hint">0 表示不限制；支持小数，如 10.5</div>
      </div>
      <div class="col">
        <label>限流模式</label>
 <select name="limit_mode">
  {_limit_mode_options(n['limit_mode'])}
</select>
      </div>
    </div>

    <div class="row">
      <div class="col">
        <label>重置日</label>
        <input type="number" name="reset_day" min="1" max="31" value="{n['reset_day']}" />
        <div class="hint">每月 1–31 日自动重置</div>
      </div>
      <div class="col">
        <label>带宽 (Mbps)</label>
       <input type="number" name="bandwidth_mbps" value="{int(n['bandwidth_bps'] / 1000000) if n['bandwidth_bps'] else 0}" />
      <div class="hint">示例：100 = 100 Mbps，1000 = 1 Gbps</div>
      </div>
    </div>

    <div class="actions">
      <button type="submit">保存修改</button>
      <a href="/nodes" target="_blank"><button type="button">查看 /nodes</button></a>
    </div>
  </form>
</body>
</html>"""
    return Response(html, mimetype="text/html")

@app.post("/edit-node")
@app.post("/edit-node/<int:path_node_id>")
def edit_node_submit(path_node_id=None):
    node_id = path_node_id or _coerce_int(request.args.get("id"), 0)
    if not node_id:
        return jsonify({"error": "missing node_id"}), 400

    # 取表单并做基本校验/转换
    sort_order    = _coerce_int(request.form.get("sort_order", 0), 0)
    display_name  = (request.form.get("display_name") or "").strip()

    # 限额：支持小数 GB
    try:
        limit_gb = float((request.form.get("limit_gb") or "0").strip())
        limit_bytes = 0 if limit_gb <= 0 else int(limit_gb * (1024**3))
    except Exception:
        limit_bytes = 0

    limit_mode    = (request.form.get("limit_mode") or "double").strip()
    if limit_mode not in ("double", "download", "upload"):
        limit_mode = "double"

    reset_day     = _coerce_int(request.form.get("reset_day", 1), 1, 1, 28)
    bandwidth_mbps = _coerce_int(request.form.get("bandwidth_mbps", 0), 0)
    bandwidth_bps = bandwidth_mbps * 1000000  # Mbps 转 bps

    with db_conn() as db:
        db.execute(
            """
            UPDATE nodes
               SET sort_order=?, display_name=?, limit_bytes=?, limit_mode=?, reset_day=?, bandwidth_bps=?
             WHERE id=?
            """,
            (sort_order, display_name, limit_bytes, limit_mode, reset_day, bandwidth_bps, node_id),
        )

    # 简单成功页
    html = f"""<!doctype html>
<html><body style="font-family: system-ui; padding:24px;">
  <h3>节点 {node_id} 已更新 ✅</h3>
  <p><a href="/nodes" target="_blank">查看 /nodes JSON</a></p>
  <p><a href="javascript:window.close()">关闭窗口</a></p>
</body></html>"""
    return Response(html, mimetype="text/html")
# ——————————————————————————————————————————————————————————————

@app.delete("/nodes/<int:node_id>")
def delete_node(node_id: int):
    with db_conn() as db:
        cur = db.execute("SELECT instance FROM nodes WHERE id=?", (node_id,))
        row = cur.fetchone()
        if not row:
            return jsonify({"error":"not found"}), 404
        instance = row["instance"]
        db.execute("DELETE FROM nodes WHERE id=?", (node_id,))
    pg_delete_instance("trafficcop", instance)  # 保持你现有调用
    return jsonify({"ok": True})

@app.get("/config/id/<int:node_id>")
def get_config_by_id(node_id: int):
    with db_conn() as db:
        cur = db.execute("SELECT * FROM nodes WHERE id=?", (node_id,))
        row = cur.fetchone()
        if not row:
            return jsonify({"error": "node_id not found"}), 404
        node = dict(row)

    cfg = {
        "node_id": node["id"],
        "instance": node["instance"],
        "display_name": node["display_name"],
        "reset_day": node["reset_day"],
        "limit_bytes": node["limit_bytes"],
        "limit_mode": node["limit_mode"],
        "bandwidth_bps": node["bandwidth_bps"],
        "updated_at": now_ts(),
    }
    return jsonify(cfg)


@app.get("/config/<instance>")
def get_config(instance: str):
    with db_conn() as db:
        cur = db.execute("SELECT * FROM nodes WHERE instance=?", (instance,))
        row = cur.fetchone()
        if not row:
            return jsonify({"error":"instance not registered"}), 404
        node = dict(row)
    cfg = {
        "instance": node["instance"],
        "display_name": node["display_name"],
        "reset_day": node["reset_day"],
        "limit_bytes": node["limit_bytes"],
        "limit_mode": node["limit_mode"],
        "bandwidth_bps": node["bandwidth_bps"],
        "updated_at": now_ts()
    }
    return jsonify(cfg)

# ========== 管理操作 ==========
@app.post("/admin/reload-prom")
def reload_prom():
    try:
        out = subprocess.run(
            ["docker", "exec", "trafficcop-prometheus", "kill", "-HUP", "1"],
            capture_output=True, text=True, check=False
        )
        return jsonify({"ok": True, "stdout": out.stdout, "stderr": out.stderr})
    except Exception as e:
        return jsonify({"ok": False, "msg": str(e)}), 500

@app.post("/admin/clear-tsdb")
def clear_tsdb():
    try:
        subprocess.run(["docker", "stop", "trafficcop-prometheus"], check=True)
        subprocess.run("rm -rf /www/trafficcop-panel/prometheus_data/*", shell=True, check=False)
        subprocess.run(["docker", "start", "trafficcop-prometheus"], check=True)
        return jsonify({"ok": True, "msg": "TSDB cleared and prometheus restarted"})
    except Exception as e:
        return jsonify({"ok": False, "msg": str(e)}), 500

@app.post("/admin/refresh-grafana")
def refresh_grafana():
    if not GRAFANA_API_TOKEN:
        return jsonify({"ok": True, "msg": "no grafana token; nothing to do"})
    try:
        headers = {"Authorization": f"Bearer {GRAFANA_API_TOKEN}"}
        r = requests.get(f"{GRAFANA_URL}/api/datasources", headers=headers, timeout=10)
        _ = r.json()
        return jsonify({"ok": True, "msg": "grafana ping ok"})
    except Exception as e:
        return jsonify({"ok": False, "msg": str(e)}), 500

# ⚡ 立即触发节点同步（保留你的路由名，但内部用增强发现）
@app.post("/admin/sync-nodes")
def admin_sync_nodes():
    try:
        before = []
        with db_conn() as db:
            cur = db.execute("SELECT instance FROM nodes")
            before = [r["instance"] for r in cur.fetchall()]
        sync_nodes_from_prometheus()
        after = []
        with db_conn() as db:
            cur = db.execute("SELECT instance FROM nodes")
            after = [r["instance"] for r in cur.fetchall()]
        added = sorted(set(after) - set(before))
        return jsonify({"ok": True, "added": added, "total": len(after)})
    except Exception as e:
        return jsonify({"ok": False, "msg": str(e)}), 500

# 【新增】GET 版，适合在 Grafana 文本面板里放一个“同步节点”链接
@app.get("/admin/sync-nodes-web")
def admin_sync_nodes_web():
    try:
        sync_nodes_from_prometheus()
        html = """<html><body style="font-family:system-ui">
        <h3>同步已触发</h3>
        <p>已尝试从 Prometheus 同步节点。返回 Grafana 刷新表格即可。</p>
        <p><a href="/nodes" target="_blank">查看当前 /nodes</a></p>
        </body></html>"""
        return Response(html, mimetype="text/html")
    except Exception as e:
        return Response(f"<pre>sync failed: {e}</pre>", mimetype="text/html", status=500)

# 【新增】SQL 调试接口：看发现结果 + DB 现状
@app.get("/admin/debug-nodes")
def admin_debug_nodes():
    out = {"job": PROM_JOB_NAME}

    # label values
    try:
        r = requests.get(
            f"{PROM_URL}/api/v1/label/instance/values",
            params={"match[]": f'up{{job="{PROM_JOB_NAME}"}}'},
            timeout=8,
        )
        r.raise_for_status()
        data = r.json()
        out["label_values"] = data.get("data", []) if data.get("status") == "success" else []
    except Exception as e:
        out["label_values_error"] = str(e)

    # targets
    try:
        r = requests.get(f"{PROM_URL}/api/v1/targets", timeout=8)
        r.raise_for_status()
        data = r.json()
        targets = data.get("data", {}).get("activeTargets", []) or []
        out["targets_instances"] = sorted(
            {t.get("labels", {}).get("instance")
             for t in targets if t.get("labels", {}).get("job") == PROM_JOB_NAME and t.get("labels", {}).get("instance")}
        )
    except Exception as e:
        out["targets_error"] = str(e)

    # up 兜底
    try:
        res = prom_instant_query("up")
        out["query_up_instances"] = sorted({s.get("metric", {}).get("instance") for s in res if s.get("metric", {}).get("instance")})
    except Exception as e:
        out["query_up_error"] = str(e)

    # series 检查 node_id 是否出现
    try:
        series = prom_series([f'push_time_seconds{{job="{PROM_JOB_NAME}"}}'])
        out["series_samples"] = series[:10]  # 取前 10 个，避免太长
    except Exception as e:
        out["series_error"] = str(e)

    # DB
    with db_conn() as db:
        cur = db.execute("SELECT * FROM nodes ORDER BY sort_order DESC, id DESC")
        rows = [dict(r) for r in cur.fetchall()]
        out["db_count"] = len(rows)
        out["db_instances"] = [r["instance"] for r in rows]
        out["db_ids"] = [r["id"] for r in rows]

    return jsonify(out)


# ========== 调度器 ==========
from datetime import datetime
import sqlite3
import logging

logger = logging.getLogger(__name__)

DB_PATH = os.getenv("DB_PATH", "./data/trafficcop.db")

def baseline_monthly_for_due_nodes():
    """
    每月基线重置任务 - 使用 baselines 表记录重置点
    而不是直接更新 nodes.used_bytes
    """
    try:
        today = datetime.now().day
        logger.info(f"[baseline] 开始检查到期节点 (today={today})")

        with db_conn() as db:
            # 找出 reset_day = 今天的节点
            cur = db.execute("SELECT id, instance, reset_day FROM nodes WHERE reset_day = ?", (today,))
            due_nodes = cur.fetchall()

            if not due_nodes:
                logger.info("[baseline] 没有到期节点")
                return

            current_date = get_current_date_tag()

            for node_id, instance, reset_day in due_nodes:
                logger.info(f"[baseline] 节点 {instance} (id={node_id}) 到期，准备写入基线")

                # 获取 Prometheus 当前流量作为基线
                rx_query = f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", instance="{instance}"}}'
                tx_query = f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", instance="{instance}"}}'

                try:
                    rx_data = prom_instant_query(rx_query)
                    tx_data = prom_instant_query(tx_query)

                    rx_val = float(rx_data[0]["value"][1]) if rx_data else 0
                    tx_val = float(tx_data[0]["value"][1]) if tx_data else 0

                    db.execute("""
                        INSERT OR REPLACE INTO baselines(instance, iface, month_key, rx_base, tx_base)
                        VALUES(?,?,?,?,?)
                    """, (instance, "total", datetime.now().strftime("%Y%m"), int(rx_val), int(tx_val)))

                    tg_send(f"📊 节点 {instance} (ID={node_id}) 已重置月度基线 RX={rx_val} TX={tx_val}")

                except Exception as e2:
                    logger.error(f"[baseline] 获取 {instance} 流量失败: {e2}")

    except Exception as e:
        logger.exception("[baseline] 执行异常", exc_info=e)


def daily_summary_to_tg():
    """
    每日汇总任务 - 从 Prometheus 获取流量并推送到 TG
    """
    try:
        current_date = get_current_date_tag()

        # 优先使用带日期标签的指标
        rx_results = prom_instant_query(
            f'traffic_rx_bytes_total{{job="{PROM_JOB_NAME}", date="{current_date}"}}'
        )
        tx_results = prom_instant_query(
            f'traffic_tx_bytes_total{{job="{PROM_JOB_NAME}", date="{current_date}"}}'
        )

        usage_map = {}
        detail_map = {}

        # 累加 RX
        for s in rx_results:
            inst = s["metric"].get("instance")
            if not inst or "value" not in s:
                continue
            val = float(s["value"][1])
            usage_map[inst] = usage_map.get(inst, 0) + val
            if inst not in detail_map:
                detail_map[inst] = [0, 0]
            detail_map[inst][0] = val  # RX

        # 累加 TX
        for s in tx_results:
            inst = s["metric"].get("instance")
            if not inst or "value" not in s:
                continue
            val = float(s["value"][1])
            usage_map[inst] = usage_map.get(inst, 0) + val
            if inst not in detail_map:
                detail_map[inst] = [0, 0]
            detail_map[inst][1] = val  # TX

        if not usage_map:
            tg_send("📊 今日汇总：没有获取到节点流量数据")
            return

        # ✅ 同步保存到 history 表
        save_daily_history(detail_map)

        # 排序并格式化前 10 个节点
        summary_lines = ["📊 今日流量汇总"]
        for inst, total in sorted(usage_map.items(), key=lambda x: x[1], reverse=True)[:10]:
            rx_val = detail_map.get(inst, [0, 0])[0]
            tx_val = detail_map.get(inst, [0, 0])[1]
            used_gb = round(total / (1024**3), 2)
            summary_lines.append(
                f"• {inst}: {used_gb} GB (Rx {round(rx_val/1024**3, 2)} / Tx {round(tx_val/1024**3, 2)})"
            )

        if len(usage_map) > 10:
            summary_lines.append(f"... 其余 {len(usage_map) - 10} 个节点省略")

        tg_send("\n".join(summary_lines))

    except Exception as e:
        logger.exception("[summary] 执行异常", exc_info=e)


scheduler = BackgroundScheduler(timezone="Asia/Shanghai")
scheduler.add_job(baseline_monthly_for_due_nodes, "cron",
                  hour=DAILY_BASELINE_HOUR, minute=DAILY_BASELINE_MINUTE, id="monthly_baseline")
scheduler.add_job(daily_summary_to_tg, "cron",
                  hour=DAILY_SUMMARY_HOUR, minute=DAILY_SUMMARY_MINUTE, id="daily_summary")
# ⚡ 每 5 分钟自动同步
scheduler.add_job(sync_nodes_from_prometheus, "interval", minutes=5, id="sync_nodes")

scheduler.start()


def save_daily_history(usage_map, date_str=None):
    """
    保存每日流量统计到 history 表
    usage_map: { instance: (rx_bytes, tx_bytes) }
    date_str: 指定日期（默认今天）
    """
    if not date_str:
        date_str = datetime.now().strftime("%Y-%m-%d")

    try:
        with db_conn() as db:
            for inst, (rx, tx) in usage_map.items():
                node = db.execute("SELECT id FROM nodes WHERE instance=?", (inst,)).fetchone()
                if node:
                    db.execute("""
                        INSERT INTO history (node_id, date, rx_bytes, tx_bytes, total_bytes)
                        VALUES (?,?,?,?,?)
                    """, (node[0], date_str, int(rx), int(tx), int(rx+tx)))
        logger.info(f"[history] {date_str} 已保存 {len(usage_map)} 个节点的流量数据")
    except Exception as e:
        logger.exception("[history] 保存异常", exc_info=e)


@app.get("/healthz")
def healthz():
    return jsonify({"ok": True, "ts": now_ts()})

if __name__ == "__main__":
    print(f"[{now_ts()}] TrafficCop Panel API starting at {PANEL_HOST}:{PANEL_PORT}")
    app.run(host=PANEL_HOST, port=PANEL_PORT)
