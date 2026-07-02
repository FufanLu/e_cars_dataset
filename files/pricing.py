"""
pricing.py — 价格生成 + 成本 roll-up(整条因果链的另一个底层输入)
1. 原材料日价: 几何布朗运动 GBM(真随机游走) + 低概率跳跃(厚尾)
2. 成本 roll-up: 从原材料价格递归算到整车成本, 严格对齐
"""

from datetime import timedelta
import numpy as np
import config


# ---------------------------------------------------------------------------
# 1. 原材料价格: GBM
# ---------------------------------------------------------------------------
def generate_material_prices(rng, dims):
    """
    为每种原材料生成每日价格(GBM + 跳跃)。
    返回:
      rows: list[tuple] 供写 fact_raw_material_price_daily
            (material_id, price_date, price_usd_per_mt, price_source)
      price_lookup: dict {(material_code, date): price}  供成本roll-up查当日价
    """
    all_dates = []
    d = config.START_DATE
    while d <= config.END_DATE:
        all_dates.append(d)
        d += timedelta(days=1)
    n = len(all_dates)
    dt = 1.0 / 365.0

    rows = []
    price_lookup = {}

    for mcode, p in config.MATERIAL_PRICE.items():
        mat = dims["material"].get(mcode)
        if not mat:
            continue
        mid = mat["material_id"]
        mu = p["annual_drift"]
        sigma = p["annual_vol"]
        jp = p["jump_prob"]
        js = p["jump_scale"]

        price = float(p["base"])
        # 预生成随机序列
        z = rng.normal(0, 1, n)                     # 布朗增量
        jump_hit = rng.random(n) < jp               # 是否跳跃
        jump_size = rng.normal(0, js, n)            # 跳跃幅度

        for i, dte in enumerate(all_dates):
            # GBM: dS/S = mu*dt + sigma*sqrt(dt)*Z
            drift = (mu - 0.5 * sigma ** 2) * dt
            diffusion = sigma * np.sqrt(dt) * z[i]
            log_ret = drift + diffusion
            if jump_hit[i]:
                log_ret += jump_size[i]             # 叠加跳跃
            price = price * np.exp(log_ret)
            price = max(1.0, price)                 # 价格下限
            rows.append((mid, dte, round(price, 2), "SIM-GBM"))
            price_lookup[(mcode, dte)] = price

    return rows, price_lookup


def _price_on(price_lookup, mcode, dte):
    """取某材料某日价格, 缺失则往前找最近的(容错)。"""
    if (mcode, dte) in price_lookup:
        return price_lookup[(mcode, dte)]
    d = dte
    for _ in range(10):
        d -= timedelta(days=1)
        if (mcode, d) in price_lookup:
            return price_lookup[(mcode, d)]
    # 兜底: 用config基准价
    return float(config.MATERIAL_PRICE.get(mcode, {}).get("base", 1.0))


# ---------------------------------------------------------------------------
# 2. 成本 roll-up: 递归算零件/整车成本, 严格对齐
# ---------------------------------------------------------------------------
def build_cost_calculator(dims, price_lookup):
    """
    返回一个函数 cost_of(component_id, on_date) -> 标准材料成本(基于当日料价)
    递归: 零件成本 = Σ(直接原材料用量 × 当日料价) + Σ(BOM子件成本 × 用量 × (1+废品))
    加工成本(人工+制造费)用 dim_component.standard_cost 里的占比推算, 保证整车能对上。
    """
    material_by_id = dims["material_by_id"]
    usage = dims["material_usage"]          # component_id -> [(material_id, kg)]
    bom = dims["bom"]                        # parent_id -> [(child_id, qty, scrap)]
    comp_by_id = dims["component_by_id"]

    # material_id -> material_code
    mid_to_code = {m["material_id"]: m["material_code"] for m in material_by_id.values()}

    _cache = {}

    def material_cost_of(cid, on_date):
        """只算材料成本部分(不含加工), 递归展开BOM和直接用料"""
        key = (cid, on_date)
        if key in _cache:
            return _cache[key]
        total = 0.0
        # 直接原材料 (用量单位kg, 价格单位USD/MT即每吨, 故除以1000;
        #  SIC-WAFER/GLASS-AU等按片/SQM计价的材料在config中base已按其单位设定,
        #  此处统一按 per_mt 处理, 对非MT计价材料是近似, 后续可按uom分别处理)
        for (mid, kg) in usage.get(cid, []):
            mcode = mid_to_code.get(mid)
            if mcode:
                price_per_mt = _price_on(price_lookup, mcode, on_date)
                total += (kg / 1000.0) * price_per_mt
        # BOM子件(递归)
        for (child_id, qty, scrap) in bom.get(cid, []):
            child_cost = material_cost_of(child_id, on_date)
            total += child_cost * qty * (1.0 + scrap)
        _cache[key] = total
        return total

    def full_cost_of(cid, on_date):
        """
        整件成本 = 材料成本 / material占比
        (用COST_SPLIT反推加工成本, 保证三科目加总=整件成本, 且随料价浮动)
        """
        mat_cost = material_cost_of(cid, on_date)
        mat_share = config.COST_SPLIT["material"]
        if mat_cost <= 0:
            # 无料用量记录的零件(如纯外购小件), 退回用standard_cost
            std = comp_by_id.get(cid, {}).get("standard_cost_usd")
            return float(std) if std else 0.0
        return mat_cost / mat_share

    return material_cost_of, full_cost_of
