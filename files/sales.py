"""
sales.py — 销售订单生成
把 demand 的月度需求拆成一辆辆整车订单(VIN):
  - 工厂: 按车型可产工厂 + 工厂→市场匹配加权
  - 国家: 按 COUNTRY_WEIGHTS + 市场车型偏好
  - 客户: 按类型分布, 从对应国家的客户池抽
  - 售价: 用真实 list_price(dim_component)
  - 成本: 调 pricing 成本计算器, 与料价对齐
  - 时间: 下单 -> 排产 -> 交付 有因果先后
"""

import random
from datetime import timedelta
import numpy as np
import config


def _weighted_choice(rng, items, weights):
    w = np.array(weights, dtype=float)
    w = w / w.sum()
    idx = rng.choice(len(items), p=w)
    return items[idx]


def _pick_country_for_factory(rng, fcode, all_countries):
    """工厂优先供其目标市场, 但保留少量跨区(加权)。"""
    markets = config.FACTORY_MARKETS.get(fcode, list(config.COUNTRY_WEIGHTS.keys()))
    # 80%概率落在工厂目标市场, 20%落在全局市场分布
    if rng.random() < 0.80:
        pool = [c for c in markets if c in config.COUNTRY_WEIGHTS]
        weights = [config.COUNTRY_WEIGHTS[c] for c in pool]
        return _weighted_choice(rng, pool, weights)
    else:
        pool = list(config.COUNTRY_WEIGHTS.keys())
        weights = [config.COUNTRY_WEIGHTS[c] for c in pool]
        return _weighted_choice(rng, pool, weights)


def _vin(rng, vcode, seq):
    """生成17位伪VIN(唯一性靠seq保证)。"""
    wmi = "5YJ"
    model_char = {"M3-SR": "3", "M3-LR": "3", "MY-SR": "Y", "MY-LR": "Y",
                  "MY-PERF": "Y", "CT-AWD": "C", "MS-PLAID": "S", "MX-PLAID": "X"}.get(vcode, "3")
    body = "".join(rng.choice(list("ABCDEFGH1234567")) for _ in range(7))
    return f"{wmi}{model_char}{body}{seq:06d}"[:17].ljust(17, "0")


def generate_sales(rng, dims, demand_rows, full_cost_of):
    """
    返回:
      so_rows, so_item_rows: 供批量写入
      vehicle_units: list of dict, 每辆车的元信息(供 production 用于数量守恒)
        {vehicle_code, factory_code, factory_id, order_date, produce_date, qty=1}
    """
    country = dims["country"]                 # code->id
    currency_usd = dims["currency"]["USD"]
    channels = dims["channel"]
    comp = dims["component"]

    # 按 (country_type) 组织客户池
    cust_by_country_type = {}
    for c in dims["customer"]:
        cust_by_country_type.setdefault((c["country_id"], c["customer_type"]), []).append(c["customer_id"])
    all_cust_by_type = {}
    for c in dims["customer"]:
        all_cust_by_type.setdefault(c["customer_type"], []).append(c["customer_id"])

    so_rows = []
    so_item_rows = []
    vehicle_units = []

    so_seq = 0
    soi_seq = 0
    vin_seq = 0

    ctype_codes = list(config.CUSTOMER_TYPE_DIST.keys())
    ctype_weights = list(config.CUSTOMER_TYPE_DIST.values())

    for dr in demand_rows:
        vcode = dr["vehicle_code"]
        vspec = config.VEHICLES[vcode]
        comp_info = comp.get(vcode)
        if not comp_info:
            continue
        cid = comp_info["component_id"]
        list_price = float(comp_info["list_price_usd"] or 0)
        month_date = dr["month_date"]
        qty = dr["demand_qty"]

        factories = vspec["factories"]

        for _ in range(qty):
            # 下单日: 该月内均匀散布
            day_offset = int(rng.integers(0, 28))
            order_date = month_date + timedelta(days=day_offset)

            # 工厂
            fcode = factories[int(rng.integers(0, len(factories)))]
            factory = dims["factory"][fcode]
            fid = factory["factory_id"]

            # 目的国
            ccode = _pick_country_for_factory(rng, fcode, country)
            cid_country = country.get(ccode)
            if cid_country is None:
                continue

            # 客户类型 + 客户
            ctype = str(_weighted_choice(rng, ctype_codes, ctype_weights))
            pool = cust_by_country_type.get((cid_country, ctype)) or all_cust_by_type.get(ctype) or []
            if not pool:
                # 兜底: 任意客户
                pool = [c["customer_id"] for c in dims["customer"]]
            customer_id = int(rng.choice(pool))

            # 渠道
            chan_code = {"CONSUMER": "DIRECT", "FLEET": "FLEET",
                         "LEASE": "FLEET", "GOVT": "GOVT_SALE"}.get(ctype, "DIRECT")
            channel_id = channels.get(chan_code, list(channels.values())[0])

            # 时间因果链: 下单 -> 排产(+7~21天) -> 交付
            lead = int(rng.integers(14, 35))
            requested_delivery = order_date + timedelta(days=21)
            produce_date = order_date + timedelta(days=int(rng.integers(5, 15)))
            actual_delivery = order_date + timedelta(days=lead)

            # 成本: 用当日料价 roll-up
            veh_full_cost = full_cost_of(cid, produce_date)
            mat_cost = veh_full_cost * config.COST_SPLIT["material"]
            mfg_cost = veh_full_cost * (config.COST_SPLIT["labor"] + config.COST_SPLIT["overhead"])

            # 售价: 真实 list_price, 加极小随机(选装/区域微调 ±3%)
            price_factor = 1.0 + rng.normal(0, 0.015)
            gross = round(list_price * max(0.9, price_factor), 2)
            net = gross  # 直销无折扣

            # 状态(基于AS_OF)
            if actual_delivery < config.AS_OF_DATE - timedelta(days=1):
                status = "DELIVERED"
            elif actual_delivery < config.AS_OF_DATE + timedelta(days=14):
                status = "IN_TRANSIT"
            else:
                status = "CONFIRMED"

            so_seq += 1
            vin_seq += 1
            so_number = f"SO-{order_date.strftime('%Y%m%d')}-{so_seq:06d}"
            vin = _vin(rng, vcode, vin_seq)

            # freight & tariff: 简化(跨境才有), 与真实运费量级一致
            is_cross = (factory["country_id"] != cid_country)
            freight = round(float(rng.uniform(800, 2500)), 2) if is_cross else round(float(rng.uniform(100, 400)), 2)
            tariff = 0.0
            if is_cross and ccode in ("US", "DE", "FR") and fcode == "FAC-SHA":
                tariff = round(net * 0.10, 2)  # 简化: 中国出口欧美整车关税

            so_rows.append((
                so_number, customer_id, channel_id, order_date,
                requested_delivery, actual_delivery if status != "CONFIRMED" else None,
                fid, cid_country, currency_usd,
                gross, 0.0, net,
                round(mat_cost, 2), freight, tariff,
                vin, status, "DDP" if is_cross else "EXW"
            ))

            # 订单行(item_seq=10 整车)
            soi_seq += 1
            so_item_rows.append((
                so_seq, 10, cid, 1, list_price, 0.0, round(net, 2),
                round(gross, 2), round(net, 2), round(mat_cost, 2), round(mfg_cost, 2)
            ))

            # FSD选装
            fsd_rate = config.FSD_ATTACH_RATE.get(ccode, config.FSD_ATTACH_RATE["_default"])
            if rng.random() < fsd_rate:
                fsd = comp.get("FSD-HW4")
                if fsd:
                    fsd_cost = full_cost_of(fsd["component_id"], produce_date)
                    soi_seq += 1
                    so_item_rows.append((
                        so_seq, 20, fsd["component_id"], 1, config.FSD_OPTION_PRICE, 0.0,
                        config.FSD_OPTION_PRICE, config.FSD_OPTION_PRICE, config.FSD_OPTION_PRICE,
                        round(fsd_cost * config.COST_SPLIT["material"], 2),
                        round(fsd_cost * (config.COST_SPLIT["labor"] + config.COST_SPLIT["overhead"]), 2)
                    ))

            vehicle_units.append({
                "vehicle_code": vcode, "factory_code": fcode, "factory_id": fid,
                "order_date": order_date, "produce_date": produce_date, "qty": 1,
                "component_id": cid,
            })

    return so_rows, so_item_rows, vehicle_units
