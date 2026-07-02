"""
config.py — EV Lakehouse 数据生成参数
所有"符合事实"的数值集中在这里, 方便你后续核实/精修。
数值参考真实特斯拉量级(缩放到中等规模: 月销几千辆/车型)。
"""

from datetime import date

# =============================================================================
# 时间范围
# =============================================================================
START_DATE = date(2022, 1, 1)
END_DATE = date(2025, 12, 31)
N_MONTHS = 48  # 2022-01 ~ 2025-12

# 生成脚本运行时的"当前日期"锚点(决定订单/生产的 status 是已完成还是进行中)
AS_OF_DATE = date(2025, 12, 31)

# 随机种子(保证可复现)
RANDOM_SEED = 42

# =============================================================================
# 车型: 月销基线(辆) + 生命周期 + 主产地
# 缩放到中等规模: 主力车型月销几千辆
# =============================================================================
# baseline_monthly: 2023年中的月销基线(会被趋势/季节/生命周期调制)
# launch / eol: 车型上市/退市月份(用于生命周期爬坡与衰退); None=全程在售
# factories: 该车型可在哪些工厂生产(按真实分工)
VEHICLES = {
    "M3-SR":   {"baseline_monthly": 2200, "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-SHA", "FAC-FMT"]},
    "M3-LR":   {"baseline_monthly": 1800, "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-SHA", "FAC-FMT"]},
    "MY-SR":   {"baseline_monthly": 2800, "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-SHA", "FAC-TXS", "FAC-BER"]},
    "MY-LR":   {"baseline_monthly": 3200, "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-SHA", "FAC-TXS", "FAC-BER"]},
    "MY-PERF": {"baseline_monthly": 900,  "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-SHA", "FAC-TXS", "FAC-BER"]},
    "CT-AWD":  {"baseline_monthly": 1200, "launch": date(2023, 11, 1), "eol": None,
                "factories": ["FAC-TXS"]},   # Cybertruck 2023Q4才投产
    "MS-PLAID":{"baseline_monthly": 350,  "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-FMT"]},
    "MX-PLAID":{"baseline_monthly": 280,  "launch": date(2022, 1, 1), "eol": None,
                "factories": ["FAC-FMT"]},
}

# 年增长趋势(逐年销量放大系数, 反映特斯拉产能爬坡)
ANNUAL_GROWTH = {2022: 0.85, 2023: 1.00, 2024: 1.18, 2025: 1.30}

# 季度季节性(Q4冲量, Q1淡季 — 真实特斯拉季末交付高峰)
# 索引: 月份1-12
MONTHLY_SEASONALITY = {
    1: 0.82, 2: 0.85, 3: 1.08,   # Q1: 季末3月冲
    4: 0.90, 5: 0.95, 6: 1.12,   # Q2
    7: 0.92, 8: 0.96, 9: 1.10,   # Q3
    10: 0.98, 11: 1.02, 12: 1.20 # Q4: 年末大冲量
}

# 车型生命周期爬坡: 上市后头N个月产能逐步爬升
RAMP_MONTHS = 6           # 新车型上市后6个月爬坡到满产
RAMP_START_PCT = 0.25     # 上市首月只有25%产能

# 需求随机波动(月度乘性噪声的标准差)
DEMAND_NOISE_STD = 0.08

# =============================================================================
# 客户分配: 国家权重(反映真实市场分布) + 客户类型分布
# =============================================================================
# 各国销量权重(和 = 1.0)
COUNTRY_WEIGHTS = {
    "US": 0.30, "CN": 0.28, "DE": 0.09, "GB": 0.06, "FR": 0.05,
    "NO": 0.04, "NL": 0.04, "CA": 0.03, "AU": 0.03, "KR": 0.03,
    "JP": 0.03, "SE": 0.02,
}

# 工厂→主要出口市场(发货地与目的国的真实对应, 用于加权而非硬性限制)
FACTORY_MARKETS = {
    "FAC-SHA": ["CN", "JP", "KR", "AU", "SE", "NO"],   # 上海供亚太+部分欧洲
    "FAC-FMT": ["US", "CA"],                            # Fremont供北美
    "FAC-TXS": ["US", "CA"],                            # Texas供北美
    "FAC-BER": ["DE", "GB", "FR", "NL", "NO", "SE"],    # 柏林供欧洲
}

# 客户类型分布(真实特斯拉以个人直销为主)
CUSTOMER_TYPE_DIST = {"CONSUMER": 0.75, "FLEET": 0.13, "LEASE": 0.07, "GOVT": 0.05}

# 车型偏好: 不同市场对车型的偏好(用于加权抽样, 让"德国爱MY"这类相关性成立)
# 值为相对权重, 越高越偏好
MARKET_VEHICLE_PREFERENCE = {
    "CN": {"MY-LR": 1.4, "MY-SR": 1.3, "M3-SR": 1.5, "M3-LR": 1.2},
    "DE": {"MY-LR": 1.5, "MY-PERF": 1.3, "M3-LR": 1.2},
    "US": {"CT-AWD": 1.8, "MY-LR": 1.3, "MS-PLAID": 1.2, "MX-PLAID": 1.2},
    "NO": {"MY-LR": 1.4, "M3-LR": 1.3},
}

# FSD选装率(占订单比例, 按市场不同)
FSD_ATTACH_RATE = {"US": 0.35, "CN": 0.12, "DE": 0.20, "_default": 0.18}
FSD_OPTION_PRICE = 8000

# =============================================================================
# 生产: 良率学习曲线
# =============================================================================
# 良率爬坡: 产线投产初期良率低, 按学习曲线爬升到稳态
# yield(t) = steady - (steady - start) * exp(-t / tau)
YIELD_START = 0.62        # 新产线投产首月良率
YIELD_STEADY_NEW = 0.94   # 新产线稳态良率
YIELD_STEADY_MATURE = 0.97 # 老产线(2019年前投产)稳态良率
YIELD_TAU_MONTHS = 8.0    # 爬坡时间常数(月)
YIELD_NOISE_STD = 0.015   # 良率月度随机波动

# 成本结构占比(材料/人工/制造费用), 用于把整车成本拆到三科目
COST_SPLIT = {"material": 0.55, "labor": 0.18, "overhead": 0.27}

# 实际成本 vs 标准成本的偏差(正态, 均值略高于标准, 体现真实执行损耗)
ACTUAL_COST_BIAS = 0.02   # 实际比标准平均高2%
ACTUAL_COST_STD = 0.04    # 偏差标准差

# =============================================================================
# 原材料价格: GBM(几何布朗运动)参数
# annual_drift: 年化漂移(趋势); annual_vol: 年化波动率
# jump_prob: 每日跳跃概率(厚尾/黑天鹅); jump_scale: 跳跃幅度标准差
# 基准价参考真实2022年初水平(USD/MT, 除注明外)
# =============================================================================
MATERIAL_PRICE = {
    # 金属
    "AL-INGOT":  {"base": 3200, "annual_drift": -0.08, "annual_vol": 0.22, "jump_prob": 0.003, "jump_scale": 0.06},
    "SS-30X":    {"base": 3400, "annual_drift": -0.02, "annual_vol": 0.16, "jump_prob": 0.002, "jump_scale": 0.05},
    "HS-STEEL":  {"base": 950,  "annual_drift": -0.05, "annual_vol": 0.18, "jump_prob": 0.002, "jump_scale": 0.05},
    "COPPER":    {"base": 9800, "annual_drift": 0.03,  "annual_vol": 0.20, "jump_prob": 0.003, "jump_scale": 0.06},
    # 电池化工 — 锂/镍价2022高位后暴跌是真实走势
    "LIOH":      {"base": 78000, "annual_drift": -0.42, "annual_vol": 0.45, "jump_prob": 0.006, "jump_scale": 0.12},
    "NISULF":    {"base": 24000, "annual_drift": -0.20, "annual_vol": 0.30, "jump_prob": 0.005, "jump_scale": 0.10},
    "COSULF":    {"base": 42000, "annual_drift": -0.25, "annual_vol": 0.28, "jump_prob": 0.004, "jump_scale": 0.09},
    "GRAPHITE":  {"base": 7200,  "annual_drift": -0.10, "annual_vol": 0.15, "jump_prob": 0.002, "jump_scale": 0.05},
    # 半导体/稀土 (SIC-WAFER 单位: USD/片)
    "SIC-WAFER": {"base": 950,   "annual_drift": -0.10, "annual_vol": 0.12, "jump_prob": 0.002, "jump_scale": 0.04},
    "NDFEB-MAG": {"base": 62000, "annual_drift": -0.06, "annual_vol": 0.25, "jump_prob": 0.004, "jump_scale": 0.10},
    # 玻璃/橡胶/塑料 (GLASS-AU 单位: USD/SQM)
    "GLASS-AU":  {"base": 225,   "annual_drift": 0.02,  "annual_vol": 0.10, "jump_prob": 0.001, "jump_scale": 0.03},
    "EPDM-RUB":  {"base": 2900,  "annual_drift": 0.01,  "annual_vol": 0.14, "jump_prob": 0.002, "jump_scale": 0.04},
    "PU-FOAM":   {"base": 2300,  "annual_drift": 0.02,  "annual_vol": 0.13, "jump_prob": 0.002, "jump_scale": 0.04},
    "PP-PLAST":  {"base": 1550,  "annual_drift": 0.03,  "annual_vol": 0.15, "jump_prob": 0.002, "jump_scale": 0.04},
}

# =============================================================================
# 供应商准时率/质量基线(按 risk_rating 派生, 也可按 supplier_code 覆盖)
# =============================================================================
SUPPLIER_OTD_BASE = {"LOW": 0.95, "MEDIUM": 0.88, "HIGH": 0.78, "CRITICAL": 0.70}
SUPPLIER_PPM_BASE = {"LOW": 80, "MEDIUM": 250, "HIGH": 600, "CRITICAL": 1200}
# 交货延迟天数分布(泊松均值, 按risk)
SUPPLIER_LATE_LAMBDA = {"LOW": 1.0, "MEDIUM": 2.5, "HIGH": 5.0, "CRITICAL": 8.0}

# =============================================================================
# 库存: 安全库存天数(JIT但有缓冲)
# =============================================================================
SAFETY_STOCK_DAYS = {"RAW": 12, "WIP": 3, "LINE_SIDE": 2}

# =============================================================================
# 数据库连接(可被环境变量覆盖)
# =============================================================================
DB_CONFIG = {
    "host": "localhost",
    "port": 15432,
    "dbname": "ev_parts",
    "user": "ev_user",
    "password": "ev_password",
}

# 批量写入的批大小
BATCH_SIZE = 5000
