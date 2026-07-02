"""
demand.py — 需求生成(整条因果链的顶层输入)
每月每车型销量 = 基线 × 年增长 × 季节性 × 生命周期爬坡 × 随机噪声
"""

import math
from datetime import date
import numpy as np
import config


def _months_between(d0, d1):
    return (d1.year - d0.year) * 12 + (d1.month - d0.month)


def _lifecycle_factor(vcode, month_date):
    """车型生命周期系数: 上市前=0, 上市后按RAMP爬坡, 满产后=1, 退市后=0"""
    spec = config.VEHICLES[vcode]
    launch = spec["launch"]
    eol = spec["eol"]
    if month_date < launch:
        return 0.0
    if eol is not None and month_date >= eol:
        return 0.0
    months_since_launch = _months_between(launch, month_date)
    if months_since_launch >= config.RAMP_MONTHS:
        return 1.0
    # 线性爬坡: RAMP_START_PCT -> 1.0
    frac = months_since_launch / config.RAMP_MONTHS
    return config.RAMP_START_PCT + (1.0 - config.RAMP_START_PCT) * frac


def generate_demand(rng):
    """
    返回: list of dict
      {vehicle_code, year, month, month_date, demand_qty}
    demand_qty 为该月该车型的整车需求量(销量目标)
    """
    out = []
    y, m = config.START_DATE.year, config.START_DATE.month
    for _ in range(config.N_MONTHS):
        month_date = date(y, m, 1)
        growth = config.ANNUAL_GROWTH.get(y, 1.0)
        season = config.MONTHLY_SEASONALITY[m]
        for vcode, spec in config.VEHICLES.items():
            life = _lifecycle_factor(vcode, month_date)
            if life <= 0:
                continue
            base = spec["baseline_monthly"]
            noise = rng.normal(1.0, config.DEMAND_NOISE_STD)
            noise = max(0.5, noise)  # 防止负数/极端小
            qty = base * growth * season * life * noise
            qty = int(round(qty))
            if qty <= 0:
                continue
            out.append({
                "vehicle_code": vcode,
                "year": y,
                "month": m,
                "month_date": month_date,
                "demand_qty": qty,
            })
        # 下一月
        m += 1
        if m > 12:
            m = 1
            y += 1
    return out
