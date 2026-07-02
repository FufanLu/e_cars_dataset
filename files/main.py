"""
main.py — 编排器
按因果链顺序: 价格 -> 需求 -> 销售 -> 生产 -> 采购 -> 衍生, 分批写库。
处理自增ID回填(so_id / prod_order_id / po_id)。

用法:
  export PGHOST=localhost PGPORT=15432 PGDATABASE=ev_parts PGUSER=ev_user PGPASSWORD=ev_password
  python main.py
"""

import sys
import time
import numpy as np

import config
import db
import demand as demand_mod
import pricing as pricing_mod
import sales as sales_mod
import production as production_mod
import procurement as procurement_mod
import derived as derived_mod


def main():
    t0 = time.time()
    rng = np.random.default_rng(config.RANDOM_SEED)

    print("连接数据库...")
    conn = db.get_conn()

    print("读取维度...")
    dims = db.load_dimensions(conn)
    print(f"  组件 {len(dims['component'])} / 原材料 {len(dims['material'])} / "
          f"供应商 {len(dims['supplier'])} / 桥表 {len(dims['bridge'])} 行")

    print("清空事实表...")
    db.truncate_fact_tables(conn)

    # ---- 1. 价格(底层输入) ----
    print("生成原材料价格(GBM)...")
    price_rows, price_lookup = pricing_mod.generate_material_prices(rng, dims)
    n = db.bulk_insert(conn, "product.fact_raw_material_price_daily",
                       ["material_id", "price_date", "price_usd_per_mt", "price_source"], price_rows)
    print(f"  原材料价格 {n} 行")
    material_cost_of, full_cost_of = pricing_mod.build_cost_calculator(dims, price_lookup)

    # ---- 2. 需求(顶层输入) ----
    print("生成月度需求...")
    demand_rows = demand_mod.generate_demand(rng)
    total_demand = sum(d["demand_qty"] for d in demand_rows)
    print(f"  需求记录 {len(demand_rows)} 条, 整车总需求 {total_demand} 辆")

    # ---- 3. 销售订单 ----
    print("生成销售订单...")
    so_rows, so_item_rows, vehicle_units = sales_mod.generate_sales(
        rng, dims, demand_rows, full_cost_of)
    # 写销售订单头, 拿回自增so_id映射
    so_cols = ["so_number", "customer_id", "channel_id", "order_date",
               "requested_delivery_date", "actual_delivery_date",
               "ship_from_factory_id", "ship_to_country_id", "currency_id",
               "total_gross_revenue", "total_discount", "total_net_revenue",
               "total_std_material_cost", "total_freight_cost", "total_tariff_cost",
               "vin", "status", "incoterm"]
    so_id_map = _insert_returning(conn, "sales.fact_sales_order", so_cols, so_rows,
                                  "so_id", "so_number")
    print(f"  销售订单 {len(so_rows)} 条")
    # 回填 so_item 的 so_id(so_item_rows里第一列是so_seq, 需映射到真实so_id)
    # so_rows 顺序即 so_seq 1..N; 用 so_number 定位
    seq_to_soid = {i + 1: so_id_map[row[0]] for i, row in enumerate(so_rows)}
    fixed_items = []
    for it in so_item_rows:
        seq = it[0]
        fixed_items.append((seq_to_soid[seq],) + it[1:])
    soi_cols = ["so_id", "item_seq", "component_id", "qty", "list_price", "discount_pct",
                "net_unit_price", "gross_line_amount", "net_line_amount",
                "std_material_cost", "manufacturing_cost"]
    db.bulk_insert(conn, "sales.fact_sales_order_item", soi_cols, fixed_items)
    print(f"  销售订单行 {len(fixed_items)} 条")

    # ---- 4. 生产 ----
    print("生成生产订单(数量守恒+良率爬坡)...")
    po_rows, qi_rows, scrap_rows, line_output_index = production_mod.generate_production(
        rng, dims, vehicle_units, full_cost_of)
    po_cols = ["prod_order_no", "component_id", "line_id", "factory_id",
               "planned_qty", "actual_qty", "scrap_qty",
               "planned_start", "planned_end", "actual_start", "actual_end", "status",
               "std_material_cost_usd", "actual_material_cost_usd",
               "std_labor_cost_usd", "actual_labor_cost_usd",
               "std_overhead_cost_usd", "actual_overhead_cost_usd"]
    prod_id_map = _insert_returning(conn, "production.fact_production_order", po_cols, po_rows,
                                    "prod_order_id", "prod_order_no")
    print(f"  生产订单 {len(po_rows)} 条")
    # 回填质量检验/报废的 prod_order_id(引用po_seq 1..N)
    seq_to_prodid = {i + 1: prod_id_map[row[0]] for i, row in enumerate(po_rows)}
    qi_fixed = [(seq_to_prodid[q[0]],) + q[1:] for q in qi_rows]
    qi_cols = ["prod_order_id", "inspection_date", "inspected_qty", "passed_qty",
               "failed_qty", "rework_qty", "scrap_qty", "defect_code", "inspector_id"]
    db.bulk_insert(conn, "production.fact_quality_inspection", qi_cols, qi_fixed)
    print(f"  质量检验 {len(qi_fixed)} 条")
    scrap_fixed = [(seq_to_prodid[s[0]],) + s[1:] for s in scrap_rows]
    scrap_cols = ["prod_order_id", "scrap_date", "component_id", "scrap_qty",
                  "scrap_reason", "scrap_cost_usd"]
    db.bulk_insert(conn, "production.fact_scrap_event", scrap_cols, scrap_fixed)
    print(f"  报废事件 {len(scrap_fixed)} 条")

    # ---- 5. 采购 ----
    print("生成采购订单(读桥表份额)...")
    pur_po, pur_poi, pur_deliv, pur_squal = procurement_mod.generate_procurement(
        rng, dims, line_output_index, price_lookup)
    po2_cols = ["po_number", "supplier_id", "factory_id", "po_date", "delivery_date",
                "currency_id", "total_amount", "status", "incoterm"]
    po2_id_map = _insert_returning(conn, "procurement.fact_purchase_order", po2_cols, pur_po,
                                   "po_id", "po_number")
    print(f"  采购订单 {len(pur_po)} 条")
    seq_to_poid = {i + 1: po2_id_map[row[0]] for i, row in enumerate(pur_po)}
    poi_fixed = [(seq_to_poid[p[0]],) + p[1:] for p in pur_poi]
    poi_cols = ["po_id", "item_seq", "component_id", "ordered_qty", "received_qty",
                "unit_price", "discount_pct", "net_unit_price", "line_amount"]
    db.bulk_insert(conn, "procurement.fact_purchase_order_item", poi_cols, poi_fixed)
    print(f"  采购订单行 {len(poi_fixed)} 条")
    deliv_fixed = [(seq_to_poid[d[0]],) + d[1:] for d in pur_deliv]
    deliv_cols = ["po_id", "supplier_id", "promised_date", "actual_date",
                  "qty_delivered", "is_on_time"]
    db.bulk_insert(conn, "procurement.fact_supplier_delivery", deliv_cols, deliv_fixed)
    print(f"  供应商交货 {len(deliv_fixed)} 条")
    squal_cols = ["supplier_id", "component_id", "inspection_date", "lot_qty",
                  "defect_qty", "rejection_reason"]
    db.bulk_insert(conn, "procurement.fact_supplier_quality", squal_cols, pur_squal)
    print(f"  来料质量 {len(pur_squal)} 条")

    # ---- 6. 衍生 ----
    print("生成衍生事实(汇率/利率/库存)...")
    fx = derived_mod.generate_fx_rates(rng, dims)
    db.bulk_insert(conn, "finance.fact_exchange_rate_daily",
                   ["rate_date", "from_currency_id", "to_currency_id", "rate", "rate_source"], fx)
    ir = derived_mod.generate_interest_rates(rng, dims)
    db.bulk_insert(conn, "finance.fact_interest_rate_daily",
                   ["rate_date", "country_id", "rate_type", "rate_pct"], ir)
    inv = derived_mod.generate_inventory_snapshots(rng, dims, line_output_index)
    db.bulk_insert(conn, "inventory.fact_inventory_snapshot",
                   ["snapshot_date", "warehouse_id", "component_id", "qty_on_hand",
                    "qty_reserved", "avg_cost_usd", "inventory_value_usd"], inv)
    print(f"  汇率 {len(fx)} / 利率 {len(ir)} / 库存快照 {len(inv)} 行")

    # ANALYZE
    with conn.cursor() as cur:
        cur.execute("ANALYZE;")
    conn.commit()

    total_rows = (len(price_rows) + len(so_rows) + len(fixed_items) + len(po_rows) +
                  len(qi_fixed) + len(scrap_fixed) + len(pur_po) + len(poi_fixed) +
                  len(deliv_fixed) + len(pur_squal) + len(fx) + len(ir) + len(inv))
    print(f"\n=== 完成! 总计约 {total_rows} 行, 耗时 {time.time()-t0:.1f}s ===")
    conn.close()


def _insert_returning(conn, table, columns, rows, id_col, key_col):
    """
    批量插入并返回 {key_col值: id_col值} 映射。
    用于拿回自增主键(so_id/prod_order_id/po_id)以回填子表。
    """
    if not rows:
        return {}
    import psycopg2.extras
    col_sql = ", ".join(columns)
    placeholder = "(" + ", ".join(["%s"] * len(columns)) + ")"
    key_idx = columns.index(key_col)
    sql = f"INSERT INTO {table} ({col_sql}) VALUES %s RETURNING {id_col}, {key_col}"
    id_map = {}
    with conn.cursor() as cur:
        # execute_values 分页会打乱RETURNING顺序, 故用key_col作为映射键(唯一)
        for i in range(0, len(rows), config.BATCH_SIZE):
            batch = rows[i:i + config.BATCH_SIZE]
            result = psycopg2.extras.execute_values(
                cur, sql, batch, template=placeholder, page_size=config.BATCH_SIZE, fetch=True)
            for r in result:
                id_map[r[1]] = r[0]  # {key_col: id_col}
    conn.commit()
    return id_map


if __name__ == "__main__":
    main()
