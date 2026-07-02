"""
procurement.py — 采购订单生成(数量守恒 + 读桥表份额)
逻辑:
  1. 从生产的零件产量, 按 component_material_usage 算原材料总需求
  2. 外购零件(BUY)本身也是采购对象
  3. 按桥表 allocation_pct 把需求拆给主供/备选
  4. 生成采购单 + 采购行 + 交货记录 + 来料质量
"""

from collections import defaultdict
from datetime import date, timedelta
import numpy as np
import config


def _month_mid(ym):
    return date(ym[0], ym[1], 15)


def generate_procurement(rng, dims, line_output_index, price_lookup):
    """
    返回:
      po_rows: fact_purchase_order
      poi_rows: fact_purchase_order_item(引用采购单序号)
      deliv_rows: fact_supplier_delivery(引用采购单序号)
      squal_rows: fact_supplier_quality
    """
    usage = dims["material_usage"]         # comp_id -> [(material_id, kg)]
    comp_by_id = dims["component_by_id"]
    material_by_id = dims["material_by_id"]
    mid_to_code = {m["material_id"]: m["material_code"] for m in material_by_id.values()}
    supplier_by_id = dims["supplier_by_id"]
    factories = list(dims["factory"].values())
    currency_usd = dims["currency"]["USD"]

    # 构建桥表索引:
    #   material_id -> [(supplier_id, rank, alloc), ...]
    #   component_id -> [(supplier_id, rank, alloc), ...]
    bridge_mat = defaultdict(list)
    bridge_comp = defaultdict(list)
    for b in dims["bridge"]:
        entry = (b["supplier_id"], b["supplier_rank"], float(b["allocation_pct"] or 0),
                 b["lead_time_days"], b["qualification_status"])
        if b["material_id"] is not None:
            bridge_mat[b["material_id"]].append(entry)
        elif b["component_id"] is not None:
            bridge_comp[b["component_id"]].append(entry)

    # ---- 1. 汇总每月原材料需求 ----
    # (ym, material_id) -> kg
    mat_need = defaultdict(float)
    # (ym, component_id) -> qty  (外购零件)
    buy_comp_need = defaultdict(float)

    for (ym, comp_id), qty in line_output_index.items():
        comp_info = comp_by_id.get(comp_id)
        if not comp_info:
            continue
        # 外购/代工零件: 记为零件采购或代工供给
        if comp_info.get("manufacturing_strategy") in ("BUY", "CONTRACT"):
            buy_comp_need[(ym, comp_id)] += qty
        # 自产零件消耗的原材料
        for (mid, kg) in usage.get(comp_id, []):
            mat_need[(ym, mid)] += qty * kg

    po_rows = []
    poi_rows = []
    deliv_rows = []
    squal_rows = []
    po_seq = 0

    def _alloc_and_emit(ym, target_kind, target_id, total_qty, bridge_entries, unit_price_fn):
        """把 total_qty 按桥表份额拆给各供应商, 生成采购单。"""
        nonlocal po_seq
        if total_qty <= 0 or not bridge_entries:
            return
        # 只对已认证(QUALIFIED)且alloc>0的供应商下单; 归一化份额
        active = [(sid, rk, al, lt) for (sid, rk, al, lt, qs) in bridge_entries
                  if qs == "QUALIFIED" and al > 0]
        if not active:
            # 全是备选未认证, 退回给rank最小的
            be = sorted(bridge_entries, key=lambda x: x[1])[0]
            active = [(be[0], be[1], 1.0, be[3])]
        alloc_sum = sum(a[2] for a in active)
        month_mid = _month_mid(ym)

        for (sid, rank, alloc, lead) in active:
            share = alloc / alloc_sum
            qty = total_qty * share
            if qty <= 0:
                continue
            sup = supplier_by_id.get(sid)
            if not sup:
                continue
            risk = sup.get("risk_rating") or "MEDIUM"
            lead = lead or 30

            po_date = month_mid
            delivery_date = po_date + timedelta(days=int(lead))
            unit_price = unit_price_fn(month_mid)
            line_amount = qty * unit_price

            # 状态
            if delivery_date < config.AS_OF_DATE - timedelta(days=45):
                status = "CLOSED"
            elif delivery_date < config.AS_OF_DATE - timedelta(days=10):
                status = "RECEIVED"
            else:
                status = "OPEN"

            fac = factories[int(rng.integers(0, len(factories)))]
            po_seq += 1
            po_number = f"PRC-{po_date.strftime('%Y%m%d')}-{sid:03d}-{po_seq:06d}"
            incoterm = ['FOB', 'CIF', 'DDP', 'EXW', 'DAP'][sid % 5]

            po_rows.append((
                po_number, sid, fac["factory_id"], po_date, delivery_date,
                currency_usd, round(line_amount, 2), status, incoterm
            ))
            poi_rows.append((
                po_seq, 10, target_id if target_kind == "comp" else _material_proxy_component(dims, target_id),
                round(qty, 2), round(qty * 0.99, 2), round(unit_price, 4), 0.0,
                round(unit_price, 4), round(line_amount, 2)
            ))

            # 交货记录(仅已收货)
            if status in ("CLOSED", "RECEIVED"):
                otd_base = config.SUPPLIER_OTD_BASE.get(risk, 0.88)
                on_time = rng.random() < otd_base
                if on_time:
                    actual = delivery_date
                    late_days = 0
                else:
                    lam = config.SUPPLIER_LATE_LAMBDA.get(risk, 2.5)
                    late_days = int(rng.poisson(lam)) + 1
                    actual = delivery_date + timedelta(days=late_days)
                deliv_rows.append((
                    po_seq, sid, delivery_date, actual, round(qty * 0.99, 2), on_time
                ))

            # 来料质量(部分批次)
            if status in ("CLOSED", "RECEIVED") and rng.random() < 0.5:
                ppm_base = config.SUPPLIER_PPM_BASE.get(risk, 250)
                lot = max(1, int(qty))
                # 偶发批次性质量事件(5%概率PPM飙高)
                if rng.random() < 0.05:
                    ppm = ppm_base * rng.uniform(3, 6)
                else:
                    ppm = max(0, ppm_base * rng.uniform(0.5, 1.5))
                defect = int(lot * ppm / 1e6)
                reasons = ['DIMENSIONAL_OOT', 'ELECTRICAL_FAIL', 'SURFACE_DEFECT',
                           'CONTAMINATION', 'MISSING_LABEL']
                squal_rows.append((
                    sid, target_id if target_kind == "comp" else _material_proxy_component(dims, target_id),
                    po_date, lot, defect,
                    None if defect == 0 else reasons[int(rng.integers(0, len(reasons)))]
                ))

    # ---- 2. 原材料采购 ----
    for (ym, mid), kg in mat_need.items():
        mcode = mid_to_code.get(mid)
        if not mcode:
            continue
        entries = bridge_mat.get(mid, [])
        if not entries:
            continue

        def price_fn(d, _mcode=mcode):
            return _price_on(price_lookup, _mcode, d)

        _alloc_and_emit(ym, "mat", mid, kg, entries, price_fn)

    # ---- 3. 外购零件采购 ----
    for (ym, comp_id), qty in buy_comp_need.items():
        entries = bridge_comp.get(comp_id, [])
        comp_info = comp_by_id.get(comp_id)
        std_cost = float(comp_info.get("standard_cost_usd") or 0) if comp_info else 0
        if not entries:
            continue

        def price_fn(d, _c=std_cost):
            return _c  # 外购件用标准成本作单价基准(可后续接roll-up)

        _alloc_and_emit(ym, "comp", comp_id, qty, entries, price_fn)

    return po_rows, poi_rows, deliv_rows, squal_rows


def _price_on(price_lookup, mcode, dte):
    if (mcode, dte) in price_lookup:
        return price_lookup[(mcode, dte)]
    d = dte
    for _ in range(15):
        d -= timedelta(days=1)
        if (mcode, d) in price_lookup:
            return price_lookup[(mcode, d)]
    return float(config.MATERIAL_PRICE.get(mcode, {}).get("base", 100.0))


# 采购行必须指向 dim_component(表结构限制), 原材料采购找一个代理零件挂靠
_proxy_cache = {}
def _material_proxy_component(dims, material_id):
    """
    fact_purchase_order_item.component_id 是 NOT NULL 且外键指向 dim_component。
    原材料采购没有直接对应的component, 这里用第一个消耗该材料的零件作为代理挂靠。
    (这是现有表结构的局限; 更规范应给采购行增加 material_id 字段, 见文末说明)
    """
    if material_id in _proxy_cache:
        return _proxy_cache[material_id]
    for cid, lst in dims["material_usage"].items():
        for (mid, _kg) in lst:
            if mid == material_id:
                _proxy_cache[material_id] = cid
                return cid
    # 兜底: 任意非成品零件
    for c in dims["component_by_id"].values():
        if not c["is_finished_good"]:
            _proxy_cache[material_id] = c["component_id"]
            return c["component_id"]
    return None
