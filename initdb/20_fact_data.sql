-- =============================================================================
-- EV OEM Lakehouse - Fact Tables Bulk Data (generate_series)
-- PostgreSQL 16
-- EV特征: 直销无库存, 垂直整合制造, 全球Gigafactory
-- search_path 覆盖所有schema
-- =============================================================================

SET client_encoding = 'UTF8';
SET search_path TO finance, sales, production, procurement, inventory, logistics, esg, aftersales, product, geo, public;

-- =============================================================================
-- FACT: 汇率日表 (2023-01-01 ~ 2025-06-30)
-- =============================================================================

INSERT INTO fact_exchange_rate_daily (rate_date, from_currency_id, to_currency_id, rate, rate_source)
SELECT
    d::DATE,
    rates.from_currency_id,
    rates.to_currency_id,
    ROUND((rates.base_rate * (1 + (EXTRACT(DOY FROM d) * 0.0003
        + SIN(EXTRACT(DOY FROM d) * 0.05) * rates.coeff)))::NUMERIC, 8),
    'ECB'
FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    SELECT
        fc.currency_id AS from_currency_id,
        tc.currency_id AS to_currency_id,
        v.base_rate,
        v.coeff
    FROM (VALUES
        ('EUR', 'USD', 1.0850, 0.012), ('CNY', 'USD', 0.1420, 0.008),
        ('JPY', 'USD', 0.0071, 0.015), ('KRW', 'USD', 0.00076,0.010),
        ('GBP', 'USD', 1.2650, 0.011), ('MXN', 'USD', 0.0580, 0.014),
        ('INR', 'USD', 0.0120, 0.007), ('THB', 'USD', 0.0290, 0.009),
        ('BRL', 'USD', 0.2000, 0.016), ('HUF', 'USD', 0.0028, 0.013),
        ('PLN', 'USD', 0.2450, 0.011), ('MYR', 'USD', 0.2200, 0.009),
        ('VND', 'USD', 0.0000415,0.006), ('SGD', 'USD', 0.7450, 0.008)
    ) AS v(fc_code, tc_code, base_rate, coeff)
    JOIN dim_currency fc ON fc.currency_code = v.fc_code
    JOIN dim_currency tc ON tc.currency_code = v.tc_code
) AS rates;

-- =============================================================================
-- FACT: 利率日表 (2023-01-01 ~ 2025-06-30)
-- =============================================================================

INSERT INTO fact_interest_rate_daily (rate_date, country_id, rate_type, rate_pct)
SELECT
    d::DATE, c.country_id, rt.rate_type,
    ROUND((rt.base_rate + SIN(EXTRACT(DOY FROM d) * 0.02 + rt.phase_off) * rt.volatility)::NUMERIC, 4)
FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    VALUES
    ('CN', 'LPR_1Y',    3.45, 0.1, 0.15), ('US', 'SOFR', 5.25, 0.5, 0.20),
    ('DE', 'EURIBOR_3M',3.90, 0.3, 0.25), ('JP', 'CENTRAL_BANK', 0.10, 0.7, 0.05),
    ('KR', 'CENTRAL_BANK',3.50,0.4, 0.18), ('GB', 'CENTRAL_BANK', 5.20, 0.6, 0.22),
    ('IN', 'CENTRAL_BANK',6.50,0.8, 0.30), ('MX', 'CENTRAL_BANK',11.25,1.0,0.50)
) AS rt(country_code, rate_type, base_rate, phase_off, volatility)
JOIN dim_country c ON c.country_code = rt.country_code;

-- =============================================================================
-- FACT: 原材料价格日表 (2023-01-01 ~ 2025-06-30, 14种材料)
-- =============================================================================

INSERT INTO fact_raw_material_price_daily (material_id, price_date, price_usd_per_mt, price_source)
SELECT
    m.material_id, d::DATE,
    ROUND(GREATEST(1, mp.base_price * (1 + mp.trend * (EXTRACT(EPOCH FROM (d - '2023-01-01'::TIMESTAMP)) / 86400 / 365)
        + mp.seasonal * SIN(EXTRACT(DOY FROM d) * 2 * PI() / 365)
        + mp.noise * SIN(EXTRACT(DOY FROM d) * 7.3 + mp.phase)))::NUMERIC, 2),
    mp.source
FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    VALUES
    -- 金属
    ('AL-INGOT',  2400,  0.03, 0.05, 0.09, 1.4, 'LME'),
    ('SS-30X',    3200,  0.01, 0.04, 0.07, 2.0, 'CRU'),
    ('HS-STEEL',   850, -0.02, 0.05, 0.08, 1.8, 'CRU'),
    ('COPPER',    8500,  0.05, 0.04, 0.08, 3.5, 'LME'),
    -- 电池化工
    ('LIOH',     35000, -0.45, 0.08, 0.15, 1.2, 'SMM'),
    ('NISULF',   18000, -0.15, 0.06, 0.12, 2.1, 'SMM'),
    ('COSULF',   32000, -0.20, 0.07, 0.14, 0.8, 'SMM'),
    ('GRAPHITE',  6500, -0.10, 0.05, 0.10, 0.9, 'SMM'),
    -- 半导体/稀土
    ('SIC-WAFER', 800,  -0.08, 0.03, 0.06, 1.5, 'SMM'),
    ('NDFEB-MAG', 55000,-0.05, 0.05, 0.11, 0.7, 'SMM'),
    -- 玻璃/橡胶/塑料
    ('GLASS-AU',   220,  0.02, 0.03, 0.05, 0.6, 'CRU'),
    ('EPDM-RUB',  2800,  0.01, 0.04, 0.08, 1.1, 'CRU'),
    ('PU-FOAM',   2200,  0.02, 0.03, 0.06, 0.8, 'CRU'),
    ('PP-PLAST',  1500,  0.03, 0.04, 0.07, 1.3, 'CRU')
) AS mp(mat_code, base_price, trend, seasonal, noise, phase, source)
JOIN dim_raw_material m ON m.material_code = mp.mat_code;

-- =============================================================================
-- FACT: 碳价格 (2023-01 ~ 2025-06, 每周)
-- =============================================================================

INSERT INTO fact_carbon_price (price_date, country_id, scheme, price_usd_per_tco2e)
SELECT
    d::DATE, c.country_id, cp.scheme,
    ROUND((cp.base_price * (1 + cp.trend * EXTRACT(DOY FROM d) / 365 + cp.noise * SIN(EXTRACT(DOY FROM d) * 0.1)))::NUMERIC, 2)
FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, INTERVAL '7 day') AS d
CROSS JOIN (
    VALUES
    ('DE', 'EU ETS', 75.0, 0.06, 0.05), ('FR', 'EU ETS', 75.0, 0.06, 0.05),
    ('HU', 'EU ETS', 75.0, 0.06, 0.05), ('GB', 'UK ETS', 55.0, 0.05, 0.04),
    ('CN', 'CCER',   8.0, 0.12, 0.07),  ('US', 'California CAP', 35.0, 0.04, 0.04),
    ('KR', 'K-ETS',  12.0, 0.05, 0.05)
) AS cp(country_code, scheme, base_price, trend, noise)
JOIN dim_country c ON c.country_code = cp.country_code;

-- =============================================================================
-- FACT: 生产订单 (约6000条, 覆盖电池/车身/电驱/FSD/总装)
-- =============================================================================

INSERT INTO fact_production_order (
    prod_order_no, component_id, line_id, factory_id,
    planned_qty, actual_qty, scrap_qty,
    planned_start, planned_end, actual_start, actual_end,
    status,
    std_material_cost_usd, actual_material_cost_usd,
    std_labor_cost_usd, actual_labor_cost_usd,
    std_overhead_cost_usd, actual_overhead_cost_usd
)
WITH line_comp AS (
    -- 产线→零部件映射 (按品类匹配)
    SELECT
        l.line_id, l.line_code, l.factory_id, l.designed_takt_sec, l.shift_count,
        c.component_id, c.standard_cost_usd, c.lifecycle_stage,
        ROW_NUMBER() OVER (ORDER BY l.line_code, c.component_code) AS rn
    FROM dim_production_line l
    JOIN dim_component c ON (
        -- 总装线 → 整车
        (l.line_code LIKE 'GA-%' AND c.is_finished_good = TRUE AND c.lifecycle_stage = 'MASS')
        -- 电池线 → 电池相关
        OR (l.line_code LIKE 'BAT-%' AND c.category_id IN (SELECT category_id FROM dim_component_category WHERE category_code IN ('CELL','BAT_PACK','BMS')))
        -- 车身线 → 车身件
        OR (l.line_code LIKE 'BDY-%' AND c.category_id IN (SELECT category_id FROM dim_component_category WHERE category_code IN ('CASTING','STAMPING','BODY')))
        -- 电驱线 → 电驱件
        OR (l.line_code LIKE 'DU-%' AND c.category_id IN (SELECT category_id FROM dim_component_category WHERE category_code IN ('MOTOR','INVERTER','GEARBOX')))
        -- FSD线 → FSD
        OR (l.line_code LIKE 'FSD-%' AND c.category_id IN (SELECT category_id FROM dim_component_category WHERE category_code IN ('FSD_COMP')))
    )
    WHERE c.is_active = TRUE
),
dates AS (
    SELECT d::DATE, d::TIMESTAMPTZ AS ts, ROW_NUMBER() OVER (ORDER BY d)::INT AS dn
    FROM generate_series('2023-01-02'::DATE, '2025-06-30'::DATE, '3 days'::INTERVAL) AS d
)
SELECT
    'PRD-' || TO_CHAR(dates.d, 'YYYYMMDD') || '-' || LPAD(lc.rn::TEXT, 3, '0'),
    lc.component_id, lc.line_id, lc.factory_id,
    -- 计划产量 = 节拍 * 班次 * 7.5小时 * 工作天数因子
    ROUND((3600.0 / NULLIF(lc.designed_takt_sec, 0) * lc.shift_count * 7.5 * 3)::NUMERIC, 0) AS planned_qty,
    ROUND((3600.0 / NULLIF(lc.designed_takt_sec, 0) * lc.shift_count * 7.5 * 3 * (0.93 + (dates.dn % 10) * 0.005))::NUMERIC, 0) AS actual_qty,
    ROUND((3600.0 / NULLIF(lc.designed_takt_sec, 0) * lc.shift_count * 7.5 * 3 * 0.008 * (1 + (dates.dn % 3) * 0.2))::NUMERIC, 0) AS scrap_qty,
    dates.ts,
    dates.ts + INTERVAL '3 days',
    dates.ts + INTERVAL '2 hours',
    dates.ts + INTERVAL '2 days 20 hours',
    CASE WHEN dates.d < CURRENT_DATE - 3 THEN 'COMPLETED' ELSE 'IN_PROGRESS' END,
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.55)::NUMERIC, 2),
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.55 * (1 + (dates.dn % 7 - 3) * 0.008))::NUMERIC, 2),
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.18)::NUMERIC, 2),
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.18 * (1 + (dates.dn % 5 - 2) * 0.01))::NUMERIC, 2),
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.27)::NUMERIC, 2),
    ROUND((lc.standard_cost_usd * (3600.0/NULLIF(lc.designed_takt_sec,0)*lc.shift_count*7.5*3) * 0.27 * (1 + (dates.dn % 6 - 3) * 0.012))::NUMERIC, 2)
FROM line_comp lc
CROSS JOIN dates
WHERE dates.dn % (CASE WHEN lc.line_code LIKE 'GA-%' THEN 7 WHEN lc.line_code LIKE 'FSD-%' THEN 14 ELSE 3 END) = 0;

-- =============================================================================
-- FACT: 质量检验 (每个已完成生产订单一条)
-- =============================================================================

INSERT INTO fact_quality_inspection (prod_order_id, inspection_date, inspected_qty, passed_qty, failed_qty, rework_qty, scrap_qty, defect_code, inspector_id)
SELECT
    po.prod_order_id,
    (po.actual_end::DATE),
    po.actual_qty + po.scrap_qty,
    ROUND(po.actual_qty * (0.960 + (po.prod_order_id % 15) * 0.002))::NUMERIC,
    ROUND(po.actual_qty * (0.040 - (po.prod_order_id % 15) * 0.002))::NUMERIC,
    ROUND(po.actual_qty * (0.020 - (po.prod_order_id % 12) * 0.001))::NUMERIC,
    po.scrap_qty,
    (ARRAY['WELD_POROSITY','PAINT_RUN','DIMENSION_OOT','ELECTRICAL','SURFACE_DEFECT','LEAK_TEST','MISSING_TORQUE','NONE'])[(po.prod_order_id % 8) + 1],
    'QC-' || LPAD((po.prod_order_id % 50 + 1)::TEXT, 4, '0')
FROM fact_production_order po
WHERE po.status = 'COMPLETED';

-- =============================================================================
-- FACT: 车辆销售订单 (~3000条, 每条=1辆整车, 带VIN)
-- EV直销: 官网下单→排产→交付
-- =============================================================================

INSERT INTO fact_sales_order (
    so_number, customer_id, channel_id, order_date,
    requested_delivery_date, actual_delivery_date,
    ship_from_factory_id, ship_to_country_id, currency_id,
    total_gross_revenue, total_discount, total_net_revenue,
    total_std_material_cost, total_freight_cost, total_tariff_cost,
    vin, status, incoterm
)
WITH order_dates AS (
    SELECT d::DATE AS od, ROW_NUMBER() OVER (ORDER BY d)::INT AS dn
    FROM generate_series('2023-01-02'::DATE, '2025-06-30'::DATE, '1 day'::INTERVAL) AS d
)
SELECT
    'SO-' || TO_CHAR(od.od, 'YYYYMMDD') || '-' || LPAD(od.dn::TEXT, 5, '0'),
    (SELECT customer_id FROM dim_customer WHERE customer_type = 'CONSUMER' ORDER BY random() * od.dn LIMIT 1),
    (SELECT channel_id FROM dim_sales_channel WHERE channel_code = 'DIRECT'),
    od.od, od.od + 21, od.od + 21 + (od.dn % 7),
    CASE WHEN od.dn % 4 = 0 THEN (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-SHA')
         WHEN od.dn % 4 = 1 THEN (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-FMT')
         WHEN od.dn % 4 = 2 THEN (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-TXS')
         ELSE (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-BER') END,
    (SELECT country_id FROM dim_country WHERE country_code =
         (ARRAY['US','US','US','US','CN','CN','CN','DE','DE','GB','FR','NL','NO','AU','CA','KR','JP'])[(od.dn % 17) + 1]),
    (SELECT currency_id FROM dim_currency WHERE currency_code='USD'),
    45000 + (od.dn % 10) * 500,  -- placeholder, corrected by UPDATE below
    0, 0,  -- placeholder, corrected below
    32000 + (od.dn % 10) * 300,  -- placeholder, corrected below
    ROUND((CASE WHEN od.dn % 4 < 3 THEN 800 + (od.dn % 10) * 50 ELSE 2500 + (od.dn % 5) * 200 END)::NUMERIC, 2),
    ROUND((CASE WHEN od.dn % 17 IN (0,1,2,3) THEN 0 WHEN od.dn % 17 IN (4,5,6) THEN 0 ELSE 2150 END)::NUMERIC, 2),
    '5YJ' || (ARRAY['3','Y','S','X','C','D','E'])[(od.dn % 7)+1] || 'B' ||
    (ARRAY['E','F','A','B','C','D','G'])[(od.dn % 7)+1] || '0' ||
    LPAD((od.dn % 9 + 1)::TEXT, 1, '0') ||
    (ARRAY['F','A','B','S','C','D','E'])[(od.dn % 7)+1] ||
    LPAD(od.dn::TEXT, 6, '0'),
    CASE WHEN od.od < CURRENT_DATE - 30 THEN 'DELIVERED'
         WHEN od.od < CURRENT_DATE - 14 THEN 'IN_TRANSIT'
         WHEN od.od < CURRENT_DATE - 3 THEN 'IN_PRODUCTION'
         WHEN od.od < CURRENT_DATE THEN 'CONFIRMED'
         ELSE 'RESERVED' END,
    (ARRAY['FOB','CIF','DDP'])[(od.dn % 3) + 1]
FROM order_dates od
WHERE od.dn % 3 = 0;

-- Fix net_revenue & costs from actual vehicle in line item
UPDATE fact_sales_order so SET
    total_net_revenue = ROUND((total_gross_revenue - total_discount)::NUMERIC, 2),
    total_gross_revenue = soi.gross_line_amount,
    total_std_material_cost = soi.std_material_cost + soi.manufacturing_cost
FROM fact_sales_order_item soi
WHERE soi.so_id = so.so_id AND soi.item_seq = 10;

UPDATE fact_sales_order SET total_net_revenue = ROUND((total_gross_revenue - total_discount)::NUMERIC, 2);

-- =============================================================================
-- FACT: 销售订单行项目 (每订单1行=1辆整车, 40%订单再加选装FSD)
-- =============================================================================

INSERT INTO fact_sales_order_item (so_id, item_seq, component_id, qty, list_price, discount_pct, net_unit_price, gross_line_amount, net_line_amount, std_material_cost, manufacturing_cost)
SELECT
    so.so_id, 10,
    v.component_id, 1,
    v.list_price_usd, 0,
    ROUND((v.list_price_usd * (0.92 + (so.so_id % 10) * 0.012))::NUMERIC, 2),
    ROUND((v.list_price_usd * (0.92 + (so.so_id % 10) * 0.012))::NUMERIC, 2),
    ROUND((v.list_price_usd * (0.92 + (so.so_id % 10) * 0.012))::NUMERIC, 2),
    ROUND((v.standard_cost_usd * 0.82)::NUMERIC, 2),
    ROUND((v.standard_cost_usd * 0.12)::NUMERIC, 2)
FROM fact_sales_order so
CROSS JOIN LATERAL (
    SELECT component_id, list_price_usd, standard_cost_usd
    FROM dim_component
    WHERE is_finished_good = TRUE AND lifecycle_stage = 'MASS'
    ORDER BY component_id
    OFFSET (so.so_id % 7) LIMIT 1
) v
WHERE so.so_id % 3 = 0;

-- 40%的订单加FSD选装
INSERT INTO fact_sales_order_item (so_id, item_seq, component_id, qty, list_price, discount_pct, net_unit_price, gross_line_amount, net_line_amount, std_material_cost, manufacturing_cost)
SELECT
    so.so_id, 20,
    fsd.component_id,
    1, 8000, 0, 8000,
    8000, 8000,
    ROUND((fsd.standard_cost_usd * 0.82)::NUMERIC, 2),
    ROUND((fsd.standard_cost_usd * 0.12)::NUMERIC, 2)
FROM fact_sales_order so
CROSS JOIN LATERAL (
    SELECT component_id, standard_cost_usd FROM dim_component WHERE component_code = 'FSD-HW4' LIMIT 1
) fsd
WHERE so.so_id % 5 IN (0, 2);

-- =============================================================================
-- FACT: 采购订单 (~600条, 12家供应商×周期性采购)
-- =============================================================================

INSERT INTO fact_purchase_order (po_number, supplier_id, factory_id, po_date, delivery_date, currency_id, total_amount, status, incoterm)
SELECT
    'PRC-' || TO_CHAR(w.po_date, 'YYYYMMDD') || '-' || s.supplier_code,
    s.supplier_id,
    f.factory_id,
    w.po_date,
    w.po_date + 30 + (s.supplier_id % 15),
    (SELECT currency_id FROM dim_currency WHERE currency_code='USD'),
    ROUND((CASE WHEN s.is_strategic THEN 8000000 + random()*5000000
                WHEN s.tier = 1 THEN 2000000 + random()*3000000
                ELSE 500000 + random()*1000000 END)::NUMERIC, 2),
    CASE WHEN w.po_date < CURRENT_DATE - 45 THEN 'CLOSED' WHEN w.po_date < CURRENT_DATE - 15 THEN 'RECEIVED' ELSE 'OPEN' END,
    (ARRAY['FOB','CIF','DDP','EXW','DAP'])[(s.supplier_id % 5) + 1]
FROM dim_supplier s
CROSS JOIN (SELECT d::DATE AS po_date FROM generate_series('2023-01-15'::DATE, '2025-06-30'::DATE, '30 days'::INTERVAL) AS d) w
JOIN dim_factory f ON f.factory_id = (SELECT factory_id FROM dim_factory ORDER BY random() LIMIT 1)
WHERE (s.supplier_id + EXTRACT(DOY FROM w.po_date)::INT) % 4 < 3;

-- 采购行项目
INSERT INTO fact_purchase_order_item (po_id, item_seq, component_id, ordered_qty, received_qty, unit_price, discount_pct, net_unit_price, line_amount)
SELECT
    po.po_id, 10,
    (SELECT component_id FROM dim_component WHERE is_finished_good = FALSE ORDER BY random() LIMIT 1),
    ROUND((random()*500 + 50)::NUMERIC, 0),
    ROUND((random()*500 + 45)::NUMERIC, 0),
    ROUND((random()*5000 + 200)::NUMERIC, 2),
    ROUND((random()*3)::NUMERIC, 1),
    ROUND((random()*4800 + 200)::NUMERIC, 2),
    ROUND((po.total_amount)::NUMERIC, 2)
FROM fact_purchase_order po;

-- =============================================================================
-- FACT: 供应商交货记录
-- =============================================================================

INSERT INTO fact_supplier_delivery (po_id, supplier_id, promised_date, actual_date, qty_delivered, is_on_time)
SELECT
    po.po_id, po.supplier_id, po.delivery_date,
    po.delivery_date + (CASE WHEN (po.po_id % 10)::INT < 7 THEN 0 WHEN (po.po_id % 10)::INT < 9 THEN (po.po_id % 7)::INT+1 ELSE (po.po_id % 14)::INT+8 END),
    (SELECT ordered_qty FROM fact_purchase_order_item WHERE po_id = po.po_id LIMIT 1) * 0.98,
    (po.po_id % 10 < 7)
FROM fact_purchase_order po
WHERE po.status IN ('CLOSED', 'RECEIVED');

-- =============================================================================
-- FACT: 供应商来料质量 (PPM驱动)
-- =============================================================================

INSERT INTO fact_supplier_quality (supplier_id, component_id, inspection_date, lot_qty, defect_qty, rejection_reason)
SELECT
    s.supplier_id,
    (SELECT component_id FROM dim_component WHERE is_finished_good = FALSE ORDER BY random() LIMIT 1),
    CURRENT_DATE - (random()*730)::INT,
    ROUND((random()*10000 + 500)::NUMERIC, 0),
    ROUND((random()*50)::NUMERIC, 0),
    CASE WHEN random() < 0.75 THEN NULL
         ELSE (ARRAY['DIMENSIONAL_OOT','ELECTRICAL_FAIL','SURFACE_DEFECT','CONTAMINATION','MISSING_LABEL'])[((random()*5)::INT)+1] END
FROM dim_supplier s
CROSS JOIN generate_series(1, 15) g;

-- =============================================================================
-- FACT: 供应商ESG评分 (年度)
-- =============================================================================

INSERT INTO fact_supplier_esg_score (supplier_id, assess_year, env_score, social_score, governance_score, overall_score, carbon_intensity_tco2e_per_mrevenue, assessor)
SELECT
    s.supplier_id, yr,
    ROUND((base_env + (s.supplier_id % 10) * 0.5 + (yr - 2022) * 1.0)::NUMERIC, 2),
    ROUND((base_soc + (s.supplier_id % 8)  * 0.4 + (yr - 2022) * 0.5)::NUMERIC, 2),
    ROUND((base_gov + (s.supplier_id % 6)  * 0.6 + (yr - 2022) * 0.8)::NUMERIC, 2),
    0,
    ROUND((45.0 - (s.supplier_id % 10) * 2.0 - (yr - 2022) * 1.5)::NUMERIC, 2),
    'EcoVadis'
FROM dim_supplier s
CROSS JOIN generate_series(2022, 2024) AS yr(yr)
CROSS JOIN (VALUES (62.0, 70.0, 68.0)) AS scores(base_env, base_soc, base_gov);

UPDATE fact_supplier_esg_score SET overall_score = ROUND(((env_score + social_score + governance_score)/3)::NUMERIC, 2);

-- =============================================================================
-- FACT: 库存快照 (EV模式: 极小成品库存, 主要为原材料和WIP)
-- =============================================================================

INSERT INTO fact_inventory_snapshot (snapshot_date, warehouse_id, component_id, qty_on_hand, qty_reserved, avg_cost_usd, inventory_value_usd)
WITH months AS (
    SELECT (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE AS snap_d
    FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, '1 month'::INTERVAL) AS d
),
wh_comp AS (
    SELECT w.warehouse_id, w.warehouse_type, c.component_id, c.standard_cost_usd, c.is_finished_good,
           ROW_NUMBER() OVER (ORDER BY w.warehouse_id, c.component_id) AS rn
    FROM dim_warehouse w
    CROSS JOIN dim_component c
    WHERE ((w.warehouse_type = 'LINE_SIDE' AND c.is_finished_good = TRUE)
        OR (w.warehouse_type = 'RAW' AND c.is_finished_good = FALSE)
        OR (w.warehouse_type = 'WIP' AND c.is_finished_good = FALSE))
      AND c.is_active = TRUE
    LIMIT 180
)
SELECT
    m.snap_d, wc.warehouse_id, wc.component_id,
    -- 成品库存: 极低 (0-3台, 在途待交付)
    CASE WHEN wc.is_finished_good AND wc.warehouse_type = 'LINE_SIDE'
         THEN (wc.rn % 3)::NUMERIC
    -- WIP: 中等
         WHEN wc.warehouse_type = 'WIP'
         THEN ROUND((200 + (wc.rn * 11 + EXTRACT(MONTH FROM m.snap_d) * 19) % 800)::NUMERIC, 2)
    -- RAW: 较高 (JIT但有安全库存)
         ELSE ROUND((500 + (wc.rn * 13 + EXTRACT(MONTH FROM m.snap_d) * 17) % 1200)::NUMERIC, 2)
    END,
    -- 预留量
    CASE WHEN wc.is_finished_good THEN 0
         ELSE ROUND((100 + (wc.rn * 7 + EXTRACT(MONTH FROM m.snap_d) * 11) % 200)::NUMERIC, 2) END,
    wc.standard_cost_usd,
    0
FROM months m
CROSS JOIN wh_comp wc;

UPDATE fact_inventory_snapshot SET inventory_value_usd = ROUND((qty_on_hand * avg_cost_usd)::NUMERIC, 2);

-- =============================================================================
-- FACT: 库存持有成本 (月度)
-- =============================================================================

INSERT INTO fact_inventory_carrying_cost (period_date, warehouse_id, component_id, avg_inventory_value_usd, interest_rate_pct, storage_cost_rate_pct, obsolescence_rate_pct, carrying_cost_usd)
SELECT
    snapshot_date, warehouse_id, component_id, inventory_value_usd,
    COALESCE((SELECT rate_pct FROM fact_interest_rate_daily WHERE country_id = (SELECT country_id FROM dim_warehouse WHERE warehouse_id = inv.warehouse_id) ORDER BY rate_date DESC LIMIT 1), 5.0),
    2.0, 1.5,
    ROUND((inventory_value_usd * (COALESCE((SELECT rate_pct FROM fact_interest_rate_daily WHERE country_id = (SELECT country_id FROM dim_warehouse WHERE warehouse_id = inv.warehouse_id) ORDER BY rate_date DESC LIMIT 1), 5.0) + 2.0 + 1.5) / 100 / 12)::NUMERIC, 2)
FROM fact_inventory_snapshot inv
WHERE inv.inventory_value_usd > 0;

-- =============================================================================
-- FACT: 工厂能耗碳排放 (Scope1天然气 + Scope2电力, 月度)
-- =============================================================================

-- Scope 2 电力
INSERT INTO fact_factory_energy_consumption (factory_id, period_month, scope_id, energy_type, consumption_kwh, emission_factor_kgco2e_per_kwh, total_emission_tco2e, renewable_pct)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, '1 month'::INTERVAL) AS d
),
fac_power AS (
    SELECT f.factory_id, f.renewable_energy_pct,
           CASE WHEN f.factory_code IN ('FAC-SHA','FAC-FMT') THEN 25000000
                WHEN f.factory_code = 'FAC-TXS' THEN 18000000
                WHEN f.factory_code = 'FAC-BER' THEN 12000000
                WHEN f.factory_code = 'FAC-NEV' THEN 15000000 END AS base_kwh,
           CASE WHEN f.factory_code IN ('FAC-BER','FAC-FMT') THEN 0.366
                WHEN f.factory_code = 'FAC-SHA' THEN 0.581
                WHEN f.factory_code = 'FAC-TXS' THEN 0.420
                ELSE 0.450 END AS ef
    FROM dim_factory f
)
SELECT
    fp.factory_id, m.m, (SELECT scope_id FROM dim_emission_scope WHERE scope_code='S2'),
    'GRID_ELEC',
    ROUND((fp.base_kwh * (0.85 + (EXTRACT(MONTH FROM m.m) % 4) * 0.05))::NUMERIC, 2),
    fp.ef,
    ROUND((fp.base_kwh * (0.85 + (EXTRACT(MONTH FROM m.m) % 4) * 0.05) * fp.ef / 1000)::NUMERIC, 4),
    fp.renewable_energy_pct
FROM fac_power fp CROSS JOIN months m;

-- Scope 1 天然气 (仅采暖季使用量高)
INSERT INTO fact_factory_energy_consumption (factory_id, period_month, scope_id, energy_type, consumption_mj, emission_factor_kgco2e_per_kwh, total_emission_tco2e, renewable_pct)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, '1 month'::INTERVAL) AS d
),
fac_gas AS (
    SELECT f.factory_id,
           CASE WHEN f.factory_code IN ('FAC-FMT','FAC-TXS') THEN 1200000
                WHEN f.factory_code = 'FAC-SHA' THEN 800000
                WHEN f.factory_code = 'FAC-BER' THEN 600000
                ELSE 300000 END AS base_gas_mj
    FROM dim_factory f
)
SELECT
    fg.factory_id, m.m, (SELECT scope_id FROM dim_emission_scope WHERE scope_code='S1'),
    'NATURAL_GAS',
    ROUND((fg.base_gas_mj * (CASE WHEN EXTRACT(MONTH FROM m.m) IN (11,12,1,2) THEN 1.3 WHEN EXTRACT(MONTH FROM m.m) IN (3,4,10) THEN 1.0 ELSE 0.6 END))::NUMERIC, 2),
    0.0000556,
    ROUND((fg.base_gas_mj * (CASE WHEN EXTRACT(MONTH FROM m.m) IN (11,12,1,2) THEN 1.3 WHEN EXTRACT(MONTH FROM m.m) IN (3,4,10) THEN 1.0 ELSE 0.6 END) * 0.0000556)::NUMERIC, 4),
    0.0
FROM fac_gas fg CROSS JOIN months m;

-- =============================================================================
-- FACT: 整车碳足迹 (仅整车, 4工厂×多车型)
-- =============================================================================

INSERT INTO fact_component_carbon_footprint (component_id, factory_id, calc_year, scope1_kgco2e_per_unit, scope2_kgco2e_per_unit, scope3_kgco2e_per_unit, cert_standard)
SELECT
    v.component_id, f.factory_id, yr,
    ROUND((random()*50 + v.weight_kg * 0.8)::NUMERIC, 2),
    ROUND((random()*300 + v.weight_kg * 2.0 * CASE WHEN f.factory_code='FAC-BER' THEN 0.4 WHEN f.factory_code='FAC-SHA' THEN 0.9 ELSE 0.65 END)::NUMERIC, 2),
    ROUND((random()*600 + v.weight_kg * 5.0)::NUMERIC, 2),
    'ISO 14067'
FROM dim_component v
CROSS JOIN dim_factory f
CROSS JOIN generate_series(2022, 2024) AS yr
WHERE v.is_finished_good = TRUE
  AND v.lifecycle_stage = 'MASS'
  AND f.factory_code IN ('FAC-FMT','FAC-TXS','FAC-SHA','FAC-BER');

-- =============================================================================
-- FACT: 碳税 (欧盟工厂月度)
-- =============================================================================

INSERT INTO fact_carbon_tax (factory_id, period_month, country_id, total_emission_tco2e, free_allowance_tco2e, taxable_emission_tco2e, carbon_price_usd_per_tco2e, carbon_tax_usd)
SELECT
    ec.factory_id, ec.period_month, f.country_id,
    ec.total_emission_tco2e,
    ROUND((ec.total_emission_tco2e * 0.25)::NUMERIC, 4),
    ROUND((ec.total_emission_tco2e * 0.75)::NUMERIC, 4),
    COALESCE((SELECT price_usd_per_tco2e FROM fact_carbon_price WHERE country_id = f.country_id ORDER BY ABS(price_date - ec.period_month) LIMIT 1), 70.0),
    ROUND((ec.total_emission_tco2e * 0.75 * COALESCE((SELECT price_usd_per_tco2e FROM fact_carbon_price WHERE country_id = f.country_id ORDER BY ABS(price_date - ec.period_month) LIMIT 1), 70.0))::NUMERIC, 2)
FROM (
    SELECT factory_id, period_month, SUM(total_emission_tco2e) AS total_emission_tco2e
    FROM fact_factory_energy_consumption GROUP BY factory_id, period_month
) ec
JOIN dim_factory f ON f.factory_id = ec.factory_id
JOIN dim_country fc ON fc.country_id = f.country_id
WHERE fc.country_code IN ('DE','HU');

-- =============================================================================
-- FACT: 碳信用
-- =============================================================================

INSERT INTO fact_carbon_credit (factory_id, credit_date, credit_type, qty_tco2e, purchase_price_usd, total_cost_usd, retired_qty)
SELECT f.factory_id, '2024-01-01'::DATE + (f.factory_id * 60 % 365),
    (ARRAY['VCS','GOLD_STANDARD','I_REC'])[(f.factory_id % 3) + 1],
    ROUND((6000 + f.factory_id * 900)::NUMERIC, 2),
    ROUND((14.0 + f.factory_id * 1.5)::NUMERIC, 2),
    ROUND((6000 + f.factory_id * 900) * (14.0 + f.factory_id * 1.5)::NUMERIC, 2),
    ROUND((3000 + f.factory_id * 400)::NUMERIC, 2)
FROM dim_factory f;

-- =============================================================================
-- FACT: 应收账款 (非CONSUMER客户, 月快照)
-- =============================================================================

INSERT INTO fact_receivable_aging (snapshot_date, customer_id, country_id, currency_id, bucket_0_30, bucket_31_60, bucket_61_90, bucket_91_180, bucket_over_180, financing_cost_usd)
WITH months AS (
    SELECT (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE AS snap_d
    FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, '1 month'::INTERVAL) AS d
)
SELECT
    m.snap_d, c.customer_id, c.country_id, c.currency_id,
    ROUND((500000 * 0.25 * (0.8 + (c.customer_id % 5) * 0.08))::NUMERIC, 2),
    ROUND((500000 * 0.12 * (0.6 + (c.customer_id % 4) * 0.1))::NUMERIC, 2),
    ROUND((500000 * 0.06 * (0.4 + (c.customer_id % 3) * 0.1))::NUMERIC, 2),
    ROUND((500000 * 0.03 * (0.3 + (c.customer_id % 5) * 0.05))::NUMERIC, 2),
    ROUND((500000 * CASE WHEN c.customer_id % 7 = 0 THEN 0.02 ELSE 0.005 END)::NUMERIC, 2),
    ROUND((500000 * 0.46 * COALESCE((SELECT rate_pct FROM fact_interest_rate_daily WHERE country_id = c.country_id ORDER BY rate_date DESC LIMIT 1), 5.0) / 100 / 12)::NUMERIC, 2)
FROM dim_customer c
CROSS JOIN months m
WHERE c.customer_type IN ('FLEET','LEASE','GOVT');

-- =============================================================================
-- FACT: 保修索赔 (~600条)
-- =============================================================================

INSERT INTO fact_warranty_claim (claim_no, customer_id, component_id, failure_id, so_item_id, claim_date, failure_date, mileage_km, claim_qty, claim_amount_usd, approved_amount_usd, status, root_cause_analysis)
SELECT
    'WC-' || TO_CHAR(soi.so_id * 10000 + soi.so_item_id, 'FM0000000000'),
    so.customer_id, soi.component_id,
    (SELECT failure_id FROM dim_failure_mode ORDER BY random() LIMIT 1),
    soi.so_item_id,
    so.actual_delivery_date + (EXTRACT(MONTH FROM so.actual_delivery_date)::INT * 30 + (soi.so_item_id % 300)::INT),
    so.actual_delivery_date + ((soi.so_item_id % 200)::INT),
    (soi.so_item_id % 50000 + 5000)::NUMERIC,
    1,
    ROUND((soi.net_unit_price * 0.05)::NUMERIC, 2),
    ROUND((soi.net_unit_price * 0.04)::NUMERIC, 2),
    (ARRAY['APPROVED','UNDER_REVIEW','PAID','REJECTED'])[(soi.so_item_id % 4) + 1],
    (ARRAY[
        'Root cause: BMS calibration drift. Corrective: OTA firmware update.',
        'Root cause: supplier SiC wafer defect. Corrective: enhanced IQC sampling.',
        'Root cause: paint process humidity excursion. Corrective: booth sensor upgrade.',
        'Root cause: customer DC fast-charging abuse pattern. Claim rejected.',
        'Root cause: heat pump reversing valve stuck. Corrective: revised valve design.'
    ])[(soi.so_item_id % 5) + 1]
FROM fact_sales_order_item soi
JOIN fact_sales_order so ON so.so_id = soi.so_id
WHERE so.status = 'DELIVERED'
  AND (soi.so_item_id % 18) < 2
LIMIT 600;

-- =============================================================================
-- FACT: 现场失效
-- =============================================================================

INSERT INTO fact_field_failure (component_id, failure_id, country_id, failure_month, units_in_field, failure_count, campaign_cost_usd)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m FROM generate_series('2023-01-01'::DATE, '2025-06-30'::DATE, '1 month'::INTERVAL) AS d
)
SELECT
    c.component_id,
    fm.failure_id,
    cnt.country_id, m.m,
    ROUND((8000 + (c.component_id * cnt.country_id * 29) % 40000)::NUMERIC, 2),
    (40 + (c.component_id * 7 + cnt.country_id * 11 + EXTRACT(MONTH FROM m.m)::INT * 3) % 150)::INT,
    ROUND(((40 + (c.component_id * 7 + cnt.country_id * 11 + EXTRACT(MONTH FROM m.m)::INT * 3) % 150) * 1200.0)::NUMERIC, 2)
FROM dim_component c
CROSS JOIN dim_failure_mode fm
CROSS JOIN dim_country cnt
CROSS JOIN months m
WHERE c.is_finished_good = TRUE
  AND cnt.country_code IN ('US','DE','CN','GB','NO')
  AND fm.failure_id % 3 = c.component_id % 3
LIMIT 2500;

-- =============================================================================
-- FACT: 装运 & 运费 (整车海运/陆运)
-- =============================================================================

INSERT INTO fact_shipping_order (shipping_no, so_id, lane_id, ship_date, eta_date, actual_arrival_date, status, container_no)
SELECT
    'SHP-' || TO_CHAR(so.order_date, 'YYYYMMDD') || '-' || LPAD(so.so_id::TEXT, 5, '0'),
    so.so_id,
    (SELECT lane_id FROM fact_trade_lane ORDER BY random() LIMIT 1),
    so.actual_delivery_date - 20,
    so.actual_delivery_date,
    so.actual_delivery_date + ((so.so_id % 3)::INT),
    CASE WHEN so.actual_delivery_date < CURRENT_DATE THEN 'DELIVERED' ELSE 'IN_TRANSIT' END,
    'TCNU' || LPAD((so.so_id * 7919 % 9999999)::TEXT, 7, '0')
FROM fact_sales_order so
WHERE so.status IN ('DELIVERED','IN_TRANSIT')
  AND so.so_id % 3 = 0;

INSERT INTO fact_freight_cost (so_id, lane_id, shipment_date, weight_kg, volume_cbm, freight_amount_usd, insurance_amount_usd, handling_fee_usd, total_logistics_cost_usd)
SELECT
    ship.so_id, ship.lane_id, ship.ship_date,
    2500, 15,
    ROUND((random()*4000 + 2000)::NUMERIC, 2),
    ROUND((random()*600 + 200)::NUMERIC, 2),
    ROUND((random()*200 + 50)::NUMERIC, 2),
    ROUND((random()*4000 + 2000 + random()*600 + 200 + random()*200 + 50)::NUMERIC, 2)
FROM fact_shipping_order ship;

-- =============================================================================
-- FACT: 运输碳排放
-- =============================================================================

INSERT INTO fact_shipping_emission (shipping_id, transport_mode, distance_km, weight_mt, emission_factor_kgco2e_per_tkm, total_emission_kgco2e)
SELECT
    s.shipping_id,
    COALESCE(tl.transport_mode, 'SEA'),
    COALESCE(tl.transit_days, 20) * CASE COALESCE(tl.transport_mode, 'SEA') WHEN 'SEA' THEN 800 WHEN 'AIR' THEN 900 WHEN 'ROAD' THEN 400 ELSE 500 END,
    COALESCE(fc.weight_kg / 1000.0, 2.5),
    CASE COALESCE(tl.transport_mode, 'SEA') WHEN 'SEA' THEN 0.011 WHEN 'AIR' THEN 0.602 WHEN 'ROAD' THEN 0.095 ELSE 0.050 END,
    ROUND((COALESCE(fc.weight_kg / 1000.0, 2.5)
        * COALESCE(tl.transit_days, 20) * CASE COALESCE(tl.transport_mode, 'SEA') WHEN 'SEA' THEN 800 WHEN 'AIR' THEN 900 WHEN 'ROAD' THEN 400 ELSE 500 END
        * CASE COALESCE(tl.transport_mode, 'SEA') WHEN 'SEA' THEN 0.011 WHEN 'AIR' THEN 0.602 WHEN 'ROAD' THEN 0.095 ELSE 0.050 END)::NUMERIC, 2)
FROM fact_shipping_order s
JOIN fact_trade_lane tl ON tl.lane_id = s.lane_id
LEFT JOIN fact_freight_cost fc ON fc.so_id = s.so_id;

-- =============================================================================
-- FACT: 断货事件 (EV JIT停线风险)
-- =============================================================================

INSERT INTO fact_stockout_event (event_date, warehouse_id, component_id, stockout_days, lost_demand_qty, lost_revenue_est_usd, root_cause)
SELECT
    '2023-01-01'::DATE + ((rn * 11 % 900)::INT),
    (SELECT warehouse_id FROM dim_warehouse WHERE warehouse_type = 'LINE_SIDE' ORDER BY random() LIMIT 1),
    (SELECT component_id FROM dim_component WHERE is_finished_good = FALSE ORDER BY random() LIMIT 1),
    (rn % 4) + 1,
    ROUND((rn % 30 + 5)::NUMERIC, 2),
    ROUND(((rn % 30 + 5) * 35000)::NUMERIC, 2),
    (ARRAY['SUPPLIER_DELAY','DEMAND_SPIKE','TRANSPORT_DISRUPTION','FORECAST_ERROR','QUALITY_HOLD'])[(rn % 5) + 1]
FROM (SELECT ROW_NUMBER() OVER () AS rn FROM generate_series(1, 80) g) sub;

-- =============================================================================
-- ANALYZE
-- =============================================================================

ANALYZE geo.dim_country;
ANALYZE geo.dim_currency;
ANALYZE product.dim_component;
ANALYZE product.dim_component_category;
ANALYZE product.dim_raw_material;
ANALYZE procurement.dim_supplier;
ANALYZE sales.dim_customer;
ANALYZE sales.fact_sales_order;
ANALYZE sales.fact_sales_order_item;
ANALYZE production.fact_production_order;
ANALYZE production.fact_quality_inspection;
ANALYZE production.fact_process_routing;
ANALYZE finance.fact_exchange_rate_daily;
ANALYZE product.fact_raw_material_price_daily;
ANALYZE inventory.fact_inventory_snapshot;
ANALYZE esg.fact_factory_energy_consumption;
ANALYZE esg.fact_carbon_tax;
ANALYZE finance.fact_receivable_aging;
ANALYZE procurement.fact_supplier_delivery;
ANALYZE procurement.fact_supplier_quality;
ANALYZE logistics.fact_tariff_rate;
ANALYZE logistics.fact_freight_cost;
ANALYZE esg.fact_shipping_emission;
ANALYZE aftersales.fact_warranty_claim;

-- =============================================================================
-- 完成提示
-- =============================================================================

DO $$
DECLARE
    schema_name TEXT;
    tbl TEXT;
    cnt BIGINT;
    total BIGINT := 0;
BEGIN
    FOR schema_name IN
        SELECT nspname FROM pg_namespace
        WHERE nspname IN ('geo','product','production','procurement','sales','inventory','finance','logistics','esg','aftersales')
    LOOP
        FOR tbl, cnt IN
            SELECT relname, reltuples::BIGINT FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r' AND n.nspname = schema_name ORDER BY reltuples DESC
        LOOP
            total := total + GREATEST(cnt, 0);
            RAISE NOTICE '[%] % => ~% rows', schema_name, tbl, cnt;
        END LOOP;
    END LOOP;
    RAISE NOTICE '=== EV OEM Lakehouse: ~% total rows ===', total;
    RAISE NOTICE '=== Data loaded. Ready for text2ontology / NL2SQL analysis. ===';
END;
$$;
