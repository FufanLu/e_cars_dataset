"""
derived.py — 衍生事实(轻量版, 不做断供连锁)
生成: 汇率日表、利率日表、库存快照。
库存快照基于安全库存天数, 与生产/采购量级挂钩(简化但守恒方向正确)。
"""

import math
from collections import defaultdict
from datetime import date, timedelta
import numpy as np
import config


def generate_fx_rates(rng, dims):
    """汇率日表: 各币种对USD, 带缓慢趋势+波动(简化GBM)。"""
    base_rates = {
        "EUR": 1.08, "CNY": 0.142, "JPY": 0.0071, "KRW": 0.00076, "GBP": 1.26,
        "MXN": 0.058, "INR": 0.012, "THB": 0.029, "BRL": 0.20, "HUF": 0.0028,
        "PLN": 0.245, "MYR": 0.22, "VND": 0.0000415, "SGD": 0.745, "TWD": 0.032,
        "CHF": 1.10, "AUD": 0.66, "CAD": 0.74, "NOK": 0.095, "SEK": 0.096,
    }
    usd_id = dims["currency"]["USD"]
    rows = []
    dates = []
    d = config.START_DATE
    while d <= config.END_DATE:
        dates.append(d)
        d += timedelta(days=1)
    for ccode, base in base_rates.items():
        cid = dims["currency"].get(ccode)
        if cid is None:
            continue
        rate = base
        z = rng.normal(0, 1, len(dates))
        for i, dte in enumerate(dates):
            rate = rate * math.exp(-0.00002 + 0.006 * z[i])  # 极缓漂移+日波动
            rate = max(base * 0.7, min(base * 1.3, rate))
            rows.append((dte, cid, usd_id, round(rate, 8), "SIM"))
    return rows


def generate_interest_rates(rng, dims):
    """利率日表: 主要国家基准利率。"""
    specs = [
        ("CN", "LPR_1Y", 3.45, 0.15), ("US", "SOFR", 5.10, 0.25),
        ("DE", "EURIBOR_3M", 3.80, 0.20), ("JP", "CENTRAL_BANK", 0.10, 0.05),
        ("KR", "CENTRAL_BANK", 3.50, 0.18), ("GB", "CENTRAL_BANK", 5.00, 0.22),
    ]
    rows = []
    dates = []
    d = config.START_DATE
    while d <= config.END_DATE:
        dates.append(d)
        d += timedelta(days=7)  # 周频足够
    for (ccode, rtype, base, vol) in specs:
        cid = dims["country"].get(ccode)
        if cid is None:
            continue
        for dte in dates:
            doy = dte.timetuple().tm_yday
            rate = base + math.sin(doy * 0.02) * vol + rng.normal(0, 0.05)
            rows.append((dte, cid, rtype, round(max(0, rate), 4)))
    return rows


def generate_inventory_snapshots(rng, dims, line_output_index):
    """
    月末库存快照(简化): 按仓库类型 × 安全库存天数, 结合当月产量估算库存水位。
    RAW仓放原材料代理件, LINE_SIDE放成品/零件。
    """
    warehouses = dims["warehouse"]
    comp_by_id = dims["component_by_id"]

    # 月产量汇总: (ym, comp_id) -> qty
    monthly = defaultdict(float)
    for (ym, cid), q in line_output_index.items():
        monthly[(ym, cid)] += q

    rows = []
    # 每月末为每个(仓库,零件)生成一条(限制组合数, 抽样)
    months = sorted(set(ym for (ym, _cid) in monthly.keys()))
    comps = sorted(set(cid for (_ym, cid) in monthly.keys()))

    for ym in months:
        snap_date = date(ym[0], ym[1], 28)
        for wh in warehouses:
            wtype = wh["warehouse_type"]
            if wtype not in ("RAW", "WIP", "LINE_SIDE"):
                continue
            days = config.SAFETY_STOCK_DAYS.get(wtype, 5)
            # 每仓抽若干零件(避免笛卡尔积爆炸)
            sample = comps if len(comps) <= 8 else list(rng.choice(comps, 8, replace=False))
            for cid in sample:
                comp_info = comp_by_id.get(int(cid))
                if not comp_info:
                    continue
                is_fg = comp_info["is_finished_good"]
                if wtype == "LINE_SIDE" and not is_fg:
                    continue
                if wtype in ("RAW", "WIP") and is_fg:
                    continue
                mqty = monthly.get((ym, cid), 0)
                daily = mqty / 30.0
                on_hand = daily * days * rng.uniform(0.7, 1.3)
                on_hand = round(max(0, on_hand), 2)
                reserved = round(on_hand * rng.uniform(0.1, 0.3), 2)
                avg_cost = float(comp_info.get("standard_cost_usd") or 0)
                rows.append((
                    snap_date, wh["warehouse_id"], int(cid), on_hand, reserved,
                    round(avg_cost, 4), round(on_hand * avg_cost, 2)
                ))
    return rows
