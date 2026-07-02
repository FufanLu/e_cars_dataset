"""
db.py — 数据库连接、维度读取、事实批量写入
读取现有维度(BOM/供应商/桥表/工厂产线), 供生成模块使用。
"""

import os
import psycopg2
import psycopg2.extras
import config


def get_conn():
    cfg = dict(config.DB_CONFIG)
    # 允许环境变量覆盖
    cfg["host"] = os.getenv("PGHOST", cfg["host"])
    cfg["port"] = int(os.getenv("PGPORT", cfg["port"]))
    cfg["dbname"] = os.getenv("PGDATABASE", cfg["dbname"])
    cfg["user"] = os.getenv("PGUSER", cfg["user"])
    cfg["password"] = os.getenv("PGPASSWORD", cfg["password"])
    conn = psycopg2.connect(**cfg)
    conn.autocommit = False
    return conn


def _fetch_all(conn, sql, params=None):
    with conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
        cur.execute(sql, params or ())
        return [dict(r) for r in cur.fetchall()]


def load_dimensions(conn):
    """一次性读入所有维度, 返回一个 dict, 供各生成模块共享。"""
    dims = {}

    # 币种/国家
    dims["currency"] = {r["currency_code"]: r["currency_id"]
                        for r in _fetch_all(conn, "SELECT currency_id, currency_code FROM geo.dim_currency")}
    dims["country"] = {r["country_code"]: r["country_id"]
                       for r in _fetch_all(conn, "SELECT country_id, country_code FROM geo.dim_country")}

    # 工厂 / 产线
    dims["factory"] = {r["factory_code"]: r for r in _fetch_all(
        conn, "SELECT factory_id, factory_code, opened_date, country_id FROM production.dim_factory")}
    dims["line"] = _fetch_all(conn, """
        SELECT l.line_id, l.line_code, l.factory_id, l.designed_takt_sec,
               l.shift_count, l.primary_category_id, f.factory_code, f.opened_date
        FROM production.dim_production_line l
        JOIN production.dim_factory f ON f.factory_id = l.factory_id
    """)

    # 品类
    dims["category"] = {r["category_code"]: r["category_id"] for r in _fetch_all(
        conn, "SELECT category_id, category_code FROM product.dim_component_category")}

    # 零件(含整车)
    dims["component"] = {r["component_code"]: r for r in _fetch_all(conn, """
        SELECT component_id, component_code, component_name, category_id, uom,
               weight_kg, standard_cost_usd, list_price_usd, is_finished_good,
               lifecycle_stage, manufacturing_strategy
        FROM product.dim_component
    """)}
    dims["component_by_id"] = {c["component_id"]: c for c in dims["component"].values()}

    # 原材料
    dims["material"] = {r["material_code"]: r for r in _fetch_all(conn, """
        SELECT material_id, material_code, material_name, uom, category
        FROM product.dim_raw_material
    """)}
    dims["material_by_id"] = {m["material_id"]: m for m in dims["material"].values()}

    # BOM: parent_component_id -> [(child_component_id, qty, scrap_rate), ...]
    bom_rows = _fetch_all(conn, """
        SELECT h.parent_component_id, i.child_component_id, i.qty_per_parent, i.scrap_rate
        FROM product.bom_header h
        JOIN product.bom_item i ON i.bom_id = h.bom_id
        WHERE h.is_current = TRUE
    """)
    bom = {}
    for r in bom_rows:
        bom.setdefault(r["parent_component_id"], []).append(
            (r["child_component_id"], float(r["qty_per_parent"]), float(r["scrap_rate"])))
    dims["bom"] = bom

    # 零件->原材料用量: component_id -> [(material_id, usage_kg), ...]
    usage_rows = _fetch_all(conn, """
        SELECT component_id, material_id, usage_kg_per_unit
        FROM product.component_material_usage
    """)
    usage = {}
    for r in usage_rows:
        usage.setdefault(r["component_id"], []).append(
            (r["material_id"], float(r["usage_kg_per_unit"])))
    dims["material_usage"] = usage

    # 供应商
    dims["supplier"] = {r["supplier_code"]: r for r in _fetch_all(conn, """
        SELECT supplier_id, supplier_code, supplier_name, risk_rating,
               supplier_type, country_id, tier
        FROM procurement.dim_supplier
    """)}
    dims["supplier_by_id"] = {s["supplier_id"]: s for s in dims["supplier"].values()}

    # 供应桥表: 用于采购分配
    dims["bridge"] = _fetch_all(conn, """
        SELECT supplier_id, component_id, material_id, supplier_rank,
               allocation_pct, max_monthly_capacity, lead_time_days,
               switch_over_days, qualification_status
        FROM procurement.bridge_supplier_component
        WHERE is_active = TRUE
    """)

    # 仓库
    dims["warehouse"] = _fetch_all(conn, """
        SELECT warehouse_id, warehouse_code, warehouse_type, factory_id, country_id
        FROM inventory.dim_warehouse
    """)

    # 客户(按类型和国家索引, 供订单分配)
    dims["customer"] = _fetch_all(conn, """
        SELECT customer_id, customer_code, customer_type, country_id
        FROM sales.dim_customer
    """)

    # 销售渠道
    dims["channel"] = {r["channel_code"]: r["channel_id"] for r in _fetch_all(
        conn, "SELECT channel_id, channel_code FROM sales.dim_sales_channel")}

    return dims


def truncate_fact_tables(conn):
    """清空所有事实表, 重新生成前调用。dim表和桥表保留。"""
    fact_tables = [
        "product.fact_raw_material_price_daily",
        "finance.fact_exchange_rate_daily",
        "finance.fact_interest_rate_daily",
        "finance.fact_receivable_aging",
        "finance.fact_inventory_carrying_cost",
        "production.fact_production_order",
        "production.fact_quality_inspection",
        "production.fact_scrap_event",
        "procurement.fact_purchase_order",
        "procurement.fact_purchase_order_item",
        "procurement.fact_supplier_delivery",
        "procurement.fact_supplier_quality",
        "sales.fact_sales_order",
        "sales.fact_sales_order_item",
        "inventory.fact_inventory_snapshot",
        "inventory.fact_inventory_movement",
        "inventory.fact_stockout_event",
    ]
    with conn.cursor() as cur:
        # RESTART IDENTITY 重置自增, CASCADE 处理外键依赖
        cur.execute("TRUNCATE " + ", ".join(fact_tables) + " RESTART IDENTITY CASCADE;")
    conn.commit()
    print(f"  已清空 {len(fact_tables)} 张事实表")


def bulk_insert(conn, table, columns, rows, batch_size=None):
    """高效批量插入。rows 为 list[tuple], 顺序与 columns 一致。返回插入行数。"""
    if not rows:
        return 0
    batch_size = batch_size or config.BATCH_SIZE
    col_sql = ", ".join(columns)
    placeholder = "(" + ", ".join(["%s"] * len(columns)) + ")"
    sql = f"INSERT INTO {table} ({col_sql}) VALUES %s"
    total = 0
    with conn.cursor() as cur:
        for i in range(0, len(rows), batch_size):
            batch = rows[i:i + batch_size]
            psycopg2.extras.execute_values(cur, sql, batch, template=placeholder, page_size=batch_size)
            total += len(batch)
    conn.commit()
    return total
