"""
production.py — 生产订单生成(数量守恒核心)
逻辑:
  1. 按月按工厂按车型汇总整车需求 -> 整车产量(考虑良率, 投产量>交付量)
  2. 按BOM递归展开: 造N辆车需要多少个电池包/电驱/FSD等零件 -> 零件产量
  3. 把零件产量排产到对应产线, 生成生产订单 + 质量检验 + 报废
  良率 = 按产线投产日期的学习曲线(新线低老线高)
"""

import math
from collections import defaultdict
from datetime import date, timedelta
import numpy as np
import config


def _months_since(open_date, cur_date):
    if open_date is None:
        return 999  # 视为老线
    return max(0, (cur_date.year - open_date.year) * 12 + (cur_date.month - open_date.month))


def _yield_rate(rng, line_open_date, cur_date):
    """学习曲线良率: steady - (steady-start)*exp(-t/tau) + 噪声"""
    t = _months_since(line_open_date, cur_date)
    # 老线(2020年前投产)用更高稳态
    if line_open_date is not None and line_open_date.year <= 2019:
        steady = config.YIELD_STEADY_MATURE
    else:
        steady = config.YIELD_STEADY_NEW
    y = steady - (steady - config.YIELD_START) * math.exp(-t / config.YIELD_TAU_MONTHS)
    y += rng.normal(0, config.YIELD_NOISE_STD)
    return min(0.995, max(0.40, y))


def _expand_bom(bom, comp_id, qty, acc):
    """递归展开BOM: 造qty个comp_id, 累加各子件需求到acc(child_id -> qty)"""
    for (child_id, per, scrap) in bom.get(comp_id, []):
        need = qty * per * (1.0 + scrap)
        acc[child_id] += need
        _expand_bom(bom, child_id, need, acc)


def _find_line_for_category(lines, category_id, factory_id):
    """给零件品类找对应产线(优先同工厂)。"""
    cands = [l for l in lines if l["primary_category_id"] == category_id]
    same_fac = [l for l in cands if l["factory_id"] == factory_id]
    if same_fac:
        return same_fac[0]
    return cands[0] if cands else None


def generate_production(rng, dims, vehicle_units, full_cost_of):
    """
    返回:
      po_rows: fact_production_order 行
      qi_rows: fact_quality_inspection 行(引用生产订单序号, main回填id)
      scrap_rows: fact_scrap_event 行(引用生产订单序号)
      line_output_index: 供后续采购计算的零件产量索引
    """
    bom = dims["bom"]
    lines = dims["line"]
    comp_by_id = dims["component_by_id"]
    cat_of = {c["component_id"]: c["category_id"] for c in comp_by_id.values()}

    # ---- 1. 按 (年月, 工厂, 零件) 汇总产量需求 ----
    # 先把整车按月+工厂汇总
    veh_month_fac = defaultdict(float)  # (ym, factory_id, vehicle_component_id) -> qty
    for u in vehicle_units:
        ym = (u["produce_date"].year, u["produce_date"].month)
        veh_month_fac[(ym, u["factory_id"], u["component_id"])] += u["qty"]

    # 展开BOM: 每个(ym,工厂)下, 所有零件的需求量
    # comp_need[(ym, factory_id, comp_id)] = qty
    comp_need = defaultdict(float)
    for (ym, fid, veh_cid), vqty in veh_month_fac.items():
        # 整车本身也要"总装产出"
        comp_need[(ym, fid, veh_cid)] += vqty
        acc = defaultdict(float)
        _expand_bom(bom, veh_cid, vqty, acc)
        for child_id, cqty in acc.items():
            comp_need[(ym, fid, child_id)] += cqty

    # ---- 2. 生成生产订单 ----
    po_rows = []
    qi_rows = []
    scrap_rows = []
    po_seq = 0

    # 零件产量索引(供采购): (ym, comp_id) -> 合格产出量
    line_output_index = defaultdict(float)

    for (ym, fid, comp_id), need_qty in comp_need.items():
        comp_info = comp_by_id.get(comp_id)
        if not comp_info:
            continue
        # 外购/代工件不自产, 跳过生产(走采购/代工供应)
        if comp_info.get("manufacturing_strategy") in ("BUY", "CONTRACT"):
            line_output_index[(ym, comp_id)] += need_qty  # 记需求供采购
            continue

        cat_id = cat_of.get(comp_id)
        line = _find_line_for_category(lines, cat_id, fid)
        if line is None:
            # 没有匹配产线的零件(如某些中间件), 记需求但不建生产单
            line_output_index[(ym, comp_id)] += need_qty
            continue

        prod_month = date(ym[0], ym[1], 1)
        yr = _yield_rate(rng, line["opened_date"], prod_month)
        planned_qty = int(round(need_qty / yr))  # 投产量 = 需求/良率
        actual_qty = int(round(planned_qty * yr))
        scrap_qty = planned_qty - actual_qty
        if planned_qty <= 0:
            continue

        # 成本: 用当月中料价 roll-up
        mid_date = prod_month + timedelta(days=14)
        unit_full = full_cost_of(comp_id, mid_date)
        std_mat = unit_full * config.COST_SPLIT["material"] * planned_qty
        std_lab = unit_full * config.COST_SPLIT["labor"] * planned_qty
        std_ovh = unit_full * config.COST_SPLIT["overhead"] * planned_qty
        # 实际成本 = 标准 × (1 + bias + noise)
        af = 1.0 + config.ACTUAL_COST_BIAS + rng.normal(0, config.ACTUAL_COST_STD)
        act_mat = std_mat * af
        act_lab = std_lab * (1.0 + rng.normal(0, config.ACTUAL_COST_STD))
        act_ovh = std_ovh * (1.0 + rng.normal(0, config.ACTUAL_COST_STD))

        planned_start = prod_month + timedelta(days=int(rng.integers(1, 20)))
        planned_end = planned_start + timedelta(days=3)
        actual_start = planned_start + timedelta(hours=2)
        actual_end = planned_start + timedelta(days=2, hours=20)
        status = "COMPLETED" if planned_end < config.AS_OF_DATE else "IN_PROGRESS"

        po_seq += 1
        prod_order_no = f"PRD-{prod_month.strftime('%Y%m')}-{po_seq:06d}"
        po_rows.append((
            prod_order_no, comp_id, line["line_id"], fid,
            planned_qty, actual_qty if status == "COMPLETED" else None, scrap_qty,
            planned_start, planned_end,
            actual_start if status == "COMPLETED" else None,
            actual_end if status == "COMPLETED" else None,
            status,
            round(std_mat, 2), round(act_mat, 2),
            round(std_lab, 2), round(act_lab, 2),
            round(std_ovh, 2), round(act_ovh, 2),
        ))

        # 合格产出计入索引(供采购)
        line_output_index[(ym, comp_id)] += actual_qty

        # 质量检验(仅COMPLETED)
        if status == "COMPLETED":
            passed = int(actual_qty * min(0.999, yr + rng.normal(0, 0.01)))
            passed = max(0, min(actual_qty, passed))
            failed = actual_qty - passed
            rework = int(failed * 0.6)
            scrap_in_qi = failed - rework
            defect_codes = ['WELD_POROSITY', 'PAINT_RUN', 'DIMENSION_OOT', 'ELECTRICAL',
                            'SURFACE_DEFECT', 'LEAK_TEST', 'MISSING_TORQUE', 'NONE']
            qi_rows.append((
                po_seq,  # 引用生产订单序号, main回填prod_order_id
                actual_end, actual_qty + scrap_qty, passed, failed, rework, scrap_in_qi,
                defect_codes[int(rng.integers(0, len(defect_codes)))],
                f"QC-{int(rng.integers(1, 51)):04d}"
            ))
            # 报废事件
            if scrap_qty > 0:
                scrap_cost = scrap_qty * unit_full
                reasons = ['来料不良', '工艺失控', '设备故障', '操作失误']
                scrap_rows.append((
                    po_seq, actual_end, comp_id, scrap_qty,
                    reasons[int(rng.integers(0, len(reasons)))], round(scrap_cost, 2)
                ))

    return po_rows, qi_rows, scrap_rows, line_output_index
