-- =============================================================================
-- EV Parts Lakehouse - Fact Tables Seed Data (generate_series bulk)
-- PostgreSQL 16
-- search_path covers all schemas so unqualified table names resolve
-- =============================================================================

SET client_encoding = 'UTF8';
SET search_path TO finance, sales, production, procurement, inventory, logistics, esg, aftersales, product, geo, public;

-- =============================================================================
-- FACT: 汇率日表 (2023-01-01 ~ 2025-03-31)
-- =============================================================================

INSERT INTO fact_exchange_rate_daily (rate_date, from_currency_id, to_currency_id, rate, rate_source)
SELECT
    d::DATE AS rate_date,
    rates.from_currency_id,
    tc.currency_id AS to_currency_id,
    ROUND(
        base_rate * (1 + (EXTRACT(DOY FROM d) * 0.0003 + SIN(EXTRACT(DOY FROM d) * 0.05) * coeff) )::NUMERIC,
        8
    ) AS rate,
    'ECB'
FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    SELECT
        fc.currency_id,
        tc.currency_id AS to_id,
        base_rate,
        coeff,
        tc.currency_code AS to_code
    FROM (VALUES
        ('EUR', 'USD', 1.0850, 0.012),
        ('CNY', 'USD', 0.1420, 0.008),
        ('JPY', 'USD', 0.0071, 0.015),
        ('KRW', 'USD', 0.00076,0.010),
        ('GBP', 'USD', 1.2650, 0.011),
        ('MXN', 'USD', 0.0580, 0.014),
        ('INR', 'USD', 0.0120, 0.007),
        ('THB', 'USD', 0.0290, 0.009),
        ('BRL', 'USD', 0.2000, 0.016),
        ('HUF', 'USD', 0.0028, 0.013),
        ('PLN', 'USD', 0.2450, 0.011),
        ('MYR', 'USD', 0.2200, 0.009),
        ('VND', 'USD', 0.0000415,0.006),
        ('SGD', 'USD', 0.7450, 0.008)
    ) AS v(fc_code, tc_code, base_rate, coeff)
    JOIN dim_currency fc ON fc.currency_code = v.fc_code
    JOIN dim_currency tc ON tc.currency_code = v.tc_code
) AS rates(from_currency_id, to_id, base_rate, coeff, to_code)
JOIN dim_currency tc ON tc.currency_id = rates.to_id;

-- =============================================================================
-- FACT: 利率日表 (2023-01-01 ~ 2025-03-31)
-- =============================================================================

INSERT INTO fact_interest_rate_daily (rate_date, country_id, rate_type, rate_pct)
SELECT
    d::DATE,
    c.country_id,
    rt.rate_type,
    ROUND((rt.base_rate + SIN(EXTRACT(DOY FROM d) * 0.02 + rt.phase_off) * rt.volatility)::NUMERIC, 4)
FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    VALUES
    ('CN', 'LPR_1Y',    4.20, 0.1, 0.15),
    ('CN', 'SHIBOR_3M', 2.50, 0.2, 0.20),
    ('DE', 'EURIBOR_3M',3.90, 0.3, 0.25),
    ('US', 'SOFR',      5.30, 0.5, 0.20),
    ('JP', 'LIBOR_3M',  0.10, 0.7, 0.05),
    ('KR', 'CENTRAL_BANK',3.50,0.4, 0.18),
    ('GB', 'LIBOR_3M',  5.20, 0.6, 0.22),
    ('IN', 'CENTRAL_BANK',6.50,0.8, 0.30),
    ('MX', 'CENTRAL_BANK',11.25,1.0,0.50),
    ('HU', 'CENTRAL_BANK',9.00, 0.9, 0.45)
) AS rt(country_code, rate_type, base_rate, phase_off, volatility)
JOIN dim_country c ON c.country_code = rt.country_code;

-- =============================================================================
-- FACT: 原材料价格日表 (2023-01-01 ~ 2025-03-31, 9种材料)
-- =============================================================================

INSERT INTO fact_raw_material_price_daily (material_id, price_date, price_usd_per_mt, price_source)
SELECT
    m.material_id,
    d::DATE,
    ROUND(GREATEST(1, mp.base_price * (
        1 + mp.trend * (EXTRACT(EPOCH FROM (d - '2023-01-01'::TIMESTAMP)) / 86400 / 365)
          + mp.seasonal * SIN(EXTRACT(DOY FROM d) * 2 * PI() / 365)
          + mp.noise * SIN(EXTRACT(DOY FROM d) * 7.3 + mp.phase)
    ))::NUMERIC, 2),
    mp.source
FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, INTERVAL '1 day') AS d
CROSS JOIN (
    VALUES
    ('LCE',    18000, -0.55, 0.08, 0.12, 1.2, 'SMM'),
    ('NICKEL', 16000, -0.15, 0.06, 0.10, 2.1, 'LME'),
    ('COBALT', 35000, -0.20, 0.07, 0.15, 0.8, 'LME'),
    ('COPPER', 8500,   0.05, 0.04, 0.08, 3.5, 'LME'),
    ('ALUM',   2350,   0.02, 0.05, 0.09, 1.4, 'LME'),
    ('SILICON',2800,  -0.10, 0.06, 0.11, 0.5, 'SMM'),
    ('MANG',   1900,   0.03, 0.04, 0.07, 2.2, 'SMM'),
    ('IRON',   110,   -0.05, 0.08, 0.12, 1.8, 'DCE'),
    ('RARE_E', 55000, -0.08, 0.05, 0.10, 0.9, 'SMM')
) AS mp(mat_code, base_price, trend, seasonal, noise, phase, source)
JOIN dim_raw_material m ON m.material_code = mp.mat_code;

-- =============================================================================
-- FACT: 碳价格 (2023-01-01 ~ 2025-03-31, 每周)
-- =============================================================================

INSERT INTO fact_carbon_price (price_date, country_id, scheme, price_usd_per_tco2e)
SELECT
    d::DATE,
    c.country_id,
    cp.scheme,
    ROUND((cp.base_price * (1 + cp.trend * EXTRACT(DOY FROM d) / 365 + cp.noise * SIN(EXTRACT(DOY FROM d) * 0.1)))::NUMERIC, 2)
FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, INTERVAL '7 day') AS d
CROSS JOIN (
    VALUES
    ('DE', 'EU ETS',           68.0,  0.08, 0.06),
    ('FR', 'EU ETS',           68.0,  0.08, 0.06),
    ('HU', 'EU ETS',           68.0,  0.08, 0.06),
    ('GB', 'UK ETS',           55.0,  0.06, 0.05),
    ('CN', 'CCER',              8.0,  0.15, 0.08),
    ('US', 'California CAP',   30.0,  0.04, 0.04),
    ('KR', 'K-ETS',            12.0,  0.05, 0.05)
) AS cp(country_code, scheme, base_price, trend, noise)
JOIN dim_country c ON c.country_code = cp.country_code;

-- =============================================================================
-- FACT: 生产订单 (2023-01-01 ~ 2025-03-31, 每周14条生产线, ~4800行)
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
WITH combos AS (
    SELECT
        c.component_id, l.line_id, f.factory_id,
        v.base_qty, v.scrap_r,
        v.std_mat, v.std_lab, v.std_ovh,
        ROW_NUMBER() OVER (ORDER BY v.comp_code) AS rn
    FROM (VALUES
        ('BP-100-NMC','LINE-SH-BP1','FAC-CN-SH', 200, 0.003, 8200.0, 820.0, 1230.0),
        ('BP-075-LFP','LINE-SH-BP2','FAC-CN-SH', 300, 0.003, 5800.0, 580.0,  870.0),
        ('BM-NMC-12S','LINE-SH-BM1','FAC-CN-SH',3500, 0.004,  520.0,  52.0,   78.0),
        ('BM-LFP-16S','LINE-SH-BM1','FAC-CN-SH',4000, 0.004,  380.0,  38.0,   57.0),
        ('MTR-200KW-PMSM','LINE-WH-MT1','FAC-CN-WH', 400, 0.002,1850.0,185.0, 278.0),
        ('MTR-150KW-PMSM','LINE-WH-MT1','FAC-CN-WH', 500, 0.002,1420.0,142.0, 213.0),
        ('INV-200KW-SIC', 'LINE-WH-IV1','FAC-CN-WH', 350, 0.003, 980.0, 98.0, 147.0),
        ('INV-150KW-IGBT','LINE-WH-IV1','FAC-CN-WH', 450, 0.003, 720.0, 72.0, 108.0),
        ('BM-NMC-12S','LINE-DE-LZ1','FAC-DE-LZ',2000, 0.003,  520.0,104.0, 156.0),
        ('BM-LFP-16S','LINE-DE-LZ2','FAC-DE-LZ',2500, 0.003,  380.0, 76.0, 114.0),
        ('BP-100-NMC','LINE-TX-BP1','FAC-US-TX', 250, 0.003, 8200.0,1230.0,1845.0),
        ('BP-075-LFP','LINE-TX-BP1','FAC-US-TX', 350, 0.003, 5800.0, 870.0,1305.0),
        ('BP-075-LFP','LINE-HU-BP1','FAC-HU-DE', 250, 0.003, 5800.0, 812.0,1218.0),
        ('BP-050-LFP','LINE-HU-BP1','FAC-HU-DE', 200, 0.003, 4100.0, 574.0, 861.0)
    ) AS v(comp_code, line_code, fac_code, base_qty, scrap_r, std_mat, std_lab, std_ovh)
    JOIN dim_component c   ON c.component_code = v.comp_code
    JOIN dim_production_line l ON l.line_code  = v.line_code
    JOIN dim_factory f     ON f.factory_code   = v.fac_code
),
dates AS (
    SELECT d::DATE, ROW_NUMBER() OVER (ORDER BY d) AS dn
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '7 days'::INTERVAL) AS d
)
SELECT
    'PRD-' || TO_CHAR(dates.d, 'YYYYMMDD') || '-' || LPAD(combos.rn::TEXT, 3, '0'),
    combos.component_id,
    combos.line_id,
    combos.factory_id,
    combos.base_qty::NUMERIC,
    ROUND((combos.base_qty * (0.95 + (dates.dn % 10) * 0.005))::NUMERIC)::NUMERIC,
    ROUND((combos.base_qty * combos.scrap_r * (1 + (dates.dn % 3) * 0.1))::NUMERIC)::NUMERIC,
    (dates.d::TIMESTAMPTZ),
    (dates.d + INTERVAL '5 days')::TIMESTAMPTZ,
    (dates.d + INTERVAL '2 hours')::TIMESTAMPTZ,
    (dates.d + INTERVAL '4 days 20 hours')::TIMESTAMPTZ,
    CASE WHEN dates.d < CURRENT_DATE - 3 THEN 'COMPLETED' ELSE 'IN_PROGRESS' END,
    ROUND((combos.base_qty * combos.std_mat)::NUMERIC, 2),
    ROUND((combos.base_qty * combos.std_mat * (1 + (dates.dn % 7 - 3) * 0.008))::NUMERIC, 2),
    ROUND((combos.base_qty * combos.std_lab)::NUMERIC, 2),
    ROUND((combos.base_qty * combos.std_lab * (1 + (dates.dn % 5 - 2) * 0.01))::NUMERIC, 2),
    ROUND((combos.base_qty * combos.std_ovh)::NUMERIC, 2),
    ROUND((combos.base_qty * combos.std_ovh * (1 + (dates.dn % 6 - 3) * 0.012))::NUMERIC, 2)
FROM combos
CROSS JOIN dates;

-- =============================================================================
-- FACT: 质量检验 (每个生产订单一条检验记录)
-- =============================================================================

INSERT INTO fact_quality_inspection (prod_order_id, inspection_date, inspected_qty, passed_qty, failed_qty, rework_qty, scrap_qty, defect_code, inspector_id)
SELECT
    po.prod_order_id,
    (po.actual_end::DATE),
    po.actual_qty,
    ROUND(po.actual_qty * (0.970 + (po.prod_order_id % 20) * 0.0015))::NUMERIC,
    ROUND(po.actual_qty * (0.030 - (po.prod_order_id % 20) * 0.0015))::NUMERIC,
    ROUND(po.actual_qty * (0.015 - (po.prod_order_id % 15) * 0.0008))::NUMERIC,
    po.scrap_qty,
    (ARRAY['COSMETIC','DIM_OOT','ELECTRICAL','WELD_DEFECT','SOLDERING','LEAK_TEST','MISSING_PART','LABEL_ERR'])[(po.prod_order_id % 8) + 1],
    'QC-' || LPAD((po.prod_order_id % 50 + 1)::TEXT, 4, '0')
FROM fact_production_order po
WHERE po.status = 'COMPLETED';

-- =============================================================================
-- FACT: 采购订单 (2023-01-01 ~ 2025-03-31, 每14天一单, ~2400行)
-- =============================================================================

INSERT INTO fact_purchase_order (po_number, supplier_id, factory_id, po_date, delivery_date, currency_id, total_amount, status, incoterm)
WITH sup_fac AS (
    SELECT
        s.supplier_id, f.factory_id, s.currency_id,
        v.avg_amount,
        ROW_NUMBER() OVER (ORDER BY v.sup_code) AS rn
    FROM (VALUES
        ('SUP-CATL-CN',  'FAC-CN-SH', 850000.0),
        ('SUP-BYD-CN',   'FAC-CN-SH', 620000.0),
        ('SUP-PANASONIC-JP','FAC-DE-LZ',480000.0),
        ('SUP-SAMSUNG-KR','FAC-US-TX', 520000.0),
        ('SUP-LGE-KR',   'FAC-HU-DE', 490000.0),
        ('SUP-INF-DE',   'FAC-DE-LZ', 280000.0),
        ('SUP-BOSCH-DE', 'FAC-DE-LZ', 320000.0),
        ('SUP-NIDEC-JP', 'FAC-CN-WH', 350000.0),
        ('SUP-ALUM-CN',  'FAC-CN-SH', 120000.0),
        ('SUP-RARE-CN',  'FAC-CN-WH', 180000.0),
        ('SUP-UMICORE-DE','FAC-DE-LZ', 220000.0),
        ('SUP-GLENCORE', 'FAC-CN-SH', 150000.0)
    ) AS v(sup_code, fac_code, avg_amount)
    JOIN dim_supplier s ON s.supplier_code = v.sup_code
    JOIN dim_factory  f ON f.factory_code  = v.fac_code
),
weeks AS (
    SELECT d::DATE AS po_date, ROW_NUMBER() OVER (ORDER BY d) AS wn
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '14 days'::INTERVAL) AS d
)
SELECT
    'PRC-' || TO_CHAR(w.po_date, 'YYYYMMDD') || '-' || LPAD(sf.rn::TEXT, 3, '0'),
    sf.supplier_id,
    sf.factory_id,
    w.po_date,
    w.po_date + 30 + (sf.rn % 15)::INT,
    sf.currency_id,
    ROUND((sf.avg_amount * (0.8 + (w.wn % 8) * 0.05))::NUMERIC, 2),
    CASE WHEN w.po_date < CURRENT_DATE - 45 THEN 'CLOSED' ELSE 'OPEN' END,
    (ARRAY['FOB','CIF','DDP','EXW','DAP'])[(sf.rn % 5) + 1]
FROM sup_fac sf
CROSS JOIN weeks w;

-- =============================================================================
-- FACT: 采购订单行项目
-- =============================================================================

INSERT INTO fact_purchase_order_item (po_id, item_seq, component_id, ordered_qty, received_qty, unit_price, discount_pct, net_unit_price, line_amount)
WITH components_for_purchase AS (
    SELECT component_id, standard_cost_usd,
           ROW_NUMBER() OVER (ORDER BY component_id) AS cn
    FROM dim_component
    WHERE is_finished_good = FALSE
)
SELECT
    po.po_id,
    10 AS item_seq,
    c.component_id,
    ROUND((po.total_amount / NULLIF(c.standard_cost_usd * (1 + (po.po_id % 5) * 0.02), 0))::NUMERIC)::NUMERIC,
    ROUND((po.total_amount / NULLIF(c.standard_cost_usd * (1 + (po.po_id % 5) * 0.02), 0) * 0.97)::NUMERIC)::NUMERIC,
    ROUND((c.standard_cost_usd * (1 + (po.po_id % 5) * 0.02))::NUMERIC, 4),
    ROUND(((po.po_id % 8) * 0.005)::NUMERIC, 4),
    ROUND((c.standard_cost_usd * (1 + (po.po_id % 5) * 0.02) * (1 - (po.po_id % 8) * 0.005))::NUMERIC, 4),
    po.total_amount
FROM fact_purchase_order po
JOIN components_for_purchase c ON c.cn = (po.po_id % 12) + 1;

-- =============================================================================
-- FACT: 供应商交货记录
-- =============================================================================

INSERT INTO fact_supplier_delivery (po_id, supplier_id, promised_date, actual_date, qty_delivered, is_on_time)
SELECT
    po.po_id,
    po.supplier_id,
    po.delivery_date,
    po.delivery_date + (
        CASE
            WHEN po.po_id % 10 < 7 THEN 0
            WHEN po.po_id % 10 < 9 THEN (po.po_id % 7)::INT + 1
            ELSE (po.po_id % 14)::INT + 8
        END
    ),
    ROUND((poi.ordered_qty * 0.98)::NUMERIC, 2),
    (po.po_id % 10 < 7)
FROM fact_purchase_order po
JOIN fact_purchase_order_item poi ON poi.po_id = po.po_id AND poi.item_seq = 10
WHERE po.status IN ('CLOSED', 'RECEIVED');

-- =============================================================================
-- FACT: 供应商来料质量
-- =============================================================================

INSERT INTO fact_supplier_quality (supplier_id, component_id, inspection_date, lot_qty, defect_qty, rejection_reason)
SELECT
    sd.supplier_id,
    poi.component_id,
    sd.actual_date,
    ROUND((poi.received_qty)::NUMERIC, 2),
    ROUND((poi.received_qty * CASE
        WHEN sd.supplier_id % 5 = 0 THEN 0.0180
        WHEN sd.supplier_id % 5 = 1 THEN 0.0050
        WHEN sd.supplier_id % 5 = 2 THEN 0.0020
        WHEN sd.supplier_id % 5 = 3 THEN 0.0008
        ELSE 0.0003
    END * (1 + (sd.delivery_id % 5) * 0.1))::NUMERIC, 2),
    (ARRAY[NULL, 'DIMENSIONAL_OOT', 'ELECTRICAL_FAIL', 'COSMETIC', 'CONTAMINATION', 'MISSING_MARKING'])[sd.delivery_id % 6 + 1]
FROM fact_supplier_delivery sd
JOIN fact_purchase_order_item poi ON poi.po_id = sd.po_id AND poi.item_seq = 10
WHERE sd.actual_date IS NOT NULL
LIMIT 3000;

-- =============================================================================
-- FACT: 供应商 ESG 评分
-- =============================================================================

INSERT INTO fact_supplier_esg_score (supplier_id, assess_year, env_score, social_score, governance_score, overall_score, carbon_intensity_tco2e_per_mrevenue, assessor)
SELECT
    s.supplier_id,
    yr,
    ROUND((base_env + (s.supplier_id % 10) * 0.5 + (yr - 2022) * 1.0)::NUMERIC, 2),
    ROUND((base_soc + (s.supplier_id % 8)  * 0.4 + (yr - 2022) * 0.5)::NUMERIC, 2),
    ROUND((base_gov + (s.supplier_id % 6)  * 0.6 + (yr - 2022) * 0.8)::NUMERIC, 2),
    ROUND(((base_env + base_soc + base_gov) / 3 + (s.supplier_id % 9) * 0.3)::NUMERIC, 2),
    ROUND((45.0 - (s.supplier_id % 10) * 2.0 - (yr - 2022) * 1.5)::NUMERIC, 2),
    'EcoVadis'
FROM dim_supplier s
CROSS JOIN generate_series(2022, 2024) AS yr(yr)
CROSS JOIN (VALUES (62.0, 70.0, 68.0)) AS scores(base_env, base_soc, base_gov);

-- =============================================================================
-- FACT: 销售订单 (~4000行)
-- =============================================================================

INSERT INTO fact_sales_order (
    so_number, customer_id, channel_id, order_date,
    requested_delivery_date, actual_delivery_date,
    ship_from_factory_id, ship_to_country_id, currency_id,
    total_gross_revenue, total_discount, total_net_revenue,
    total_std_material_cost, total_freight_cost, total_tariff_cost,
    status, incoterm
)
WITH so_combos AS (
    SELECT
        cust.customer_id, ch.channel_id, fac.factory_id,
        dest.country_id AS dest_country_id, fac_curr.currency_id,
        gr.gross_rev, v.disc_pct, v.std_cost_pct, v.freight_pct, v.tariff_pct,
        ROW_NUMBER() OVER (ORDER BY v.cust_code) AS rn
    FROM (VALUES
        ('CUST-VW-DE',  'DIR-OEM',  'FAC-DE-LZ','DE', 0.0850, 0.18200, 0.01800, 0.0280),
        ('CUST-BMW-DE', 'DIR-OEM',  'FAC-DE-LZ','DE', 0.0650, 0.19500, 0.01500, 0.0250),
        ('CUST-FORD-US','DIR-OEM',  'FAC-US-TX','US', 0.0750, 0.20000, 0.00000, 0.0000),
        ('CUST-GM-US',  'DIR-OEM',  'FAC-US-TX','US', 0.0700, 0.19800, 0.00000, 0.0000),
        ('CUST-HONDA-JP','DIR-OEM', 'FAC-CN-SH','JP', 0.0600, 0.17500, 0.02000, 0.0000),
        ('CUST-HYUNDAI','DIR-OEM',  'FAC-CN-SH','KR', 0.0550, 0.18000, 0.01800, 0.0000),
        ('CUST-FORD-US','DIR-OEM',  'FAC-CN-SH','US', 0.0750, 0.20000, 0.03200, 0.2750),
        ('CUST-GM-US',  'DIR-OEM',  'FAC-CN-SH','US', 0.0700, 0.19800, 0.03100, 0.2750),
        ('CUST-VW-DE',  'DIR-OEM',  'FAC-CN-SH','DE', 0.0850, 0.18200, 0.02800, 0.1780),
        ('CUST-STELLANT','DIR-OEM', 'FAC-HU-DE','FR', 0.0900, 0.18500, 0.01200, 0.0000),
        ('CUST-TATA-IN','DIST-APAC','FAC-CN-SH','IN', 0.1000, 0.17000, 0.03800, 0.1500),
        ('CUST-LEAPMOTOR','DIR-OEM','FAC-CN-SH','CN', 0.0500, 0.17500, 0.00000, 0.0000),
        ('CUST-ZEEKR-CN','DIR-OEM', 'FAC-CN-SH','CN', 0.0450, 0.18000, 0.00000, 0.0000),
        ('CUST-DIST-SG','DIST-APAC','FAC-CN-SH','SG', 0.0800, 0.18500, 0.02000, 0.0000),
        ('CUST-DIST-GB','DIST-EMEA','FAC-DE-LZ','GB', 0.0850, 0.19000, 0.01500, 0.0350),
        ('CUST-GOVT-DE','GOV-FLEET','FAC-DE-LZ','DE', 0.0400, 0.19000, 0.01500, 0.0000),
        ('CUST-GOVT-US','GOV-FLEET','FAC-US-TX','US', 0.0300, 0.20500, 0.00000, 0.0000),
        ('CUST-TOYOTA-JP','DIR-OEM','FAC-CN-SH','JP', 0.0600, 0.17800, 0.02000, 0.0000),
        ('CUST-RIVIAN-US','DIR-OEM','FAC-US-TX','US', 0.0680, 0.20200, 0.00000, 0.0000),
        ('CUST-RENAULT','DIR-OEM',  'FAC-HU-DE','FR', 0.0950, 0.18500, 0.01200, 0.0000)
    ) AS v(cust_code, chan_code, fac_code, dest_code, disc_pct, std_cost_pct, freight_pct, tariff_pct)
    JOIN dim_customer cust ON cust.customer_code = v.cust_code
    JOIN dim_sales_channel ch ON ch.channel_code  = v.chan_code
    JOIN dim_factory fac      ON fac.factory_code  = v.fac_code
    JOIN dim_country dest     ON dest.country_code  = v.dest_code
    JOIN dim_currency fac_curr ON fac_curr.currency_id = (
        SELECT dc.currency_id FROM dim_country dc WHERE dc.country_id = dest.country_id
    )
    CROSS JOIN (VALUES (850000.0)) AS gr(gross_rev)
),
order_dates AS (
    SELECT d::DATE AS od, ROW_NUMBER() OVER (ORDER BY d) AS dn
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '3 days'::INTERVAL) AS d
)
SELECT
    'SO-' || TO_CHAR(od.od, 'YYYYMMDD') || '-' || LPAD(c.rn::TEXT, 3, '0'),
    c.customer_id,
    c.channel_id,
    od.od,
    od.od + 20::int,
    od.od + 22::int + (od.dn % 5)::int,
    c.factory_id,
    c.dest_country_id,
    c.currency_id,
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05))::NUMERIC, 2),
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05) * c.disc_pct)::NUMERIC, 2),
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05) * (1 - c.disc_pct))::NUMERIC, 2),
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05) * c.std_cost_pct)::NUMERIC, 2),
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05) * c.freight_pct)::NUMERIC, 2),
    ROUND((c.gross_rev * (0.7 + (od.dn % 12) * 0.05) * c.tariff_pct)::NUMERIC, 2),
    CASE WHEN od.od < CURRENT_DATE - 30 THEN 'CLOSED' ELSE 'CONFIRMED' END,
    (ARRAY['FOB','CIF','DDP','DAP','EXW'])[(c.rn % 5) + 1]
FROM so_combos c
CROSS JOIN order_dates od
WHERE (od.dn % 20) = (c.rn % 20);

-- =============================================================================
-- FACT: 销售订单行项目
-- =============================================================================

INSERT INTO fact_sales_order_item (so_id, item_seq, component_id, qty, list_price, discount_pct, net_unit_price, gross_line_amount, net_line_amount, std_material_cost, manufacturing_cost)
WITH fg_components AS (
    SELECT component_id, standard_cost_usd, list_price_usd,
           ROW_NUMBER() OVER (ORDER BY component_id) AS cn
    FROM dim_component
    WHERE is_finished_good = TRUE
)
SELECT
    so.so_id,
    10,
    fg.component_id,
    ROUND((so.total_gross_revenue / NULLIF(fg.list_price_usd, 0))::NUMERIC)::NUMERIC,
    fg.list_price_usd,
    ROUND((so.total_discount / NULLIF(so.total_gross_revenue, 0))::NUMERIC, 4),
    ROUND((fg.list_price_usd * (1 - so.total_discount / NULLIF(so.total_gross_revenue, 0)))::NUMERIC, 4),
    so.total_gross_revenue,
    so.total_net_revenue,
    ROUND((fg.standard_cost_usd * 0.85)::NUMERIC, 4),
    ROUND((fg.standard_cost_usd * 0.15)::NUMERIC, 4)
FROM fact_sales_order so
JOIN fg_components fg ON fg.cn = (so.so_id % 6) + 1;

-- =============================================================================
-- FACT: 装运单 & 运费
-- =============================================================================

INSERT INTO fact_shipping_order (shipping_no, so_id, lane_id, ship_date, eta_date, actual_arrival_date, status, container_no)
SELECT
    'SHP-' || TO_CHAR(so.order_date, 'YYYYMMDD') || '-' || LPAD(so.so_id::TEXT, 5, '0'),
    so.so_id,
    tl.lane_id,
    so.actual_delivery_date - tl.transit_days,
    so.actual_delivery_date,
    so.actual_delivery_date + (so.so_id % 3)::INT,
    CASE WHEN so.actual_delivery_date < CURRENT_DATE THEN 'DELIVERED' ELSE 'IN_TRANSIT' END,
    'MSCU' || LPAD((so.so_id * 7919 % 9999999)::TEXT, 7, '0')
FROM fact_sales_order so
JOIN dim_factory fac ON fac.factory_id = so.ship_from_factory_id
JOIN fact_trade_lane tl ON (
    tl.from_country_id = fac.country_id
    AND tl.to_country_id = so.ship_to_country_id
    AND tl.transport_mode = 'SEA'
)
WHERE so.actual_delivery_date IS NOT NULL
ON CONFLICT DO NOTHING;

INSERT INTO fact_freight_cost (so_id, lane_id, shipment_date, weight_kg, volume_cbm, freight_amount_usd, insurance_amount_usd, handling_fee_usd, total_logistics_cost_usd)
SELECT
    ship.so_id,
    ship.lane_id,
    ship.ship_date,
    ROUND((so.total_net_revenue / 25.0)::NUMERIC, 2),
    ROUND((so.total_net_revenue / 2500.0)::NUMERIC, 2),
    so.total_freight_cost * 0.88,
    so.total_freight_cost * 0.07,
    so.total_freight_cost * 0.05,
    so.total_freight_cost
FROM fact_shipping_order ship
JOIN fact_sales_order so ON so.so_id = ship.so_id;

-- =============================================================================
-- FACT: 库存快照 (月末, 2023-01 ~ 2025-03)
-- =============================================================================

INSERT INTO fact_inventory_snapshot (snapshot_date, warehouse_id, component_id, qty_on_hand, qty_reserved, avg_cost_usd, inventory_value_usd)
WITH months AS (
    SELECT (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE AS snap_d
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '1 month'::INTERVAL) AS d
),
wh_comp AS (
    SELECT w.warehouse_id, c.component_id, c.standard_cost_usd,
           ROW_NUMBER() OVER (ORDER BY w.warehouse_id, c.component_id) AS rn
    FROM dim_warehouse w
    CROSS JOIN dim_component c
    WHERE w.warehouse_type IN ('FG','RAW')
    LIMIT 150
)
SELECT
    m.snap_d,
    wc.warehouse_id,
    wc.component_id,
    ROUND((500 + (wc.rn * 17 + EXTRACT(MONTH FROM m.snap_d) * 23) % 1500)::NUMERIC, 2),
    ROUND((80  + (wc.rn * 11 + EXTRACT(MONTH FROM m.snap_d) * 17) % 300)::NUMERIC, 2),
    wc.standard_cost_usd,
    ROUND((wc.standard_cost_usd * (500 + (wc.rn * 17 + EXTRACT(MONTH FROM m.snap_d) * 23) % 1500))::NUMERIC, 2)
FROM months m
CROSS JOIN wh_comp wc;

-- =============================================================================
-- FACT: 库存持有成本 (月度)
-- =============================================================================

INSERT INTO fact_inventory_carrying_cost (period_date, warehouse_id, component_id, avg_inventory_value_usd, interest_rate_pct, storage_cost_rate_pct, obsolescence_rate_pct, carrying_cost_usd)
SELECT
    snap_d,
    warehouse_id,
    component_id,
    inventory_value_usd,
    ir.rate_pct,
    2.0,
    1.5,
    ROUND((inventory_value_usd * (ir.rate_pct + 2.0 + 1.5) / 100 / 12)::NUMERIC, 2)
FROM fact_inventory_snapshot inv
JOIN dim_warehouse wh ON wh.warehouse_id = inv.warehouse_id
JOIN dim_country wh_c ON wh_c.country_id = wh.country_id
JOIN LATERAL (
    SELECT rate_pct FROM fact_interest_rate_daily
    WHERE country_id = wh_c.country_id
      AND rate_type IN ('LPR_1Y','SOFR','EURIBOR_3M','CENTRAL_BANK')
    ORDER BY rate_date DESC LIMIT 1
) ir ON TRUE;

-- =============================================================================
-- FACT: 应收账款账龄 (月度快照)
-- =============================================================================

INSERT INTO fact_receivable_aging (snapshot_date, customer_id, country_id, currency_id, bucket_0_30, bucket_31_60, bucket_61_90, bucket_91_180, bucket_over_180, financing_cost_usd)
WITH months AS (
    SELECT (DATE_TRUNC('month', d) + INTERVAL '1 month - 1 day')::DATE AS snap_d
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '1 month'::INTERVAL) AS d
)
SELECT
    m.snap_d,
    c.customer_id,
    c.country_id,
    c.currency_id,
    ROUND((c.credit_limit_usd * 0.25 * (0.8 + (c.customer_id % 5) * 0.08))::NUMERIC, 2),
    ROUND((c.credit_limit_usd * 0.12 * (0.6 + (c.customer_id % 4) * 0.1))::NUMERIC, 2),
    ROUND((c.credit_limit_usd * 0.06 * (0.4 + (c.customer_id % 3) * 0.1))::NUMERIC, 2),
    ROUND((c.credit_limit_usd * 0.03 * (0.3 + (c.customer_id % 5) * 0.05))::NUMERIC, 2),
    ROUND((c.credit_limit_usd * CASE WHEN c.customer_id % 7 = 0 THEN 0.02 ELSE 0.005 END)::NUMERIC, 2),
    ROUND((c.credit_limit_usd * 0.46 * ir.rate_pct / 100 / 12)::NUMERIC, 2)
FROM dim_customer c
CROSS JOIN months m
JOIN LATERAL (
    SELECT rate_pct FROM fact_interest_rate_daily ir
    WHERE ir.country_id = c.country_id
      AND ir.rate_type IN ('LPR_1Y','SOFR','EURIBOR_3M','CENTRAL_BANK','LIBOR_3M')
    ORDER BY rate_date DESC LIMIT 1
) ir ON TRUE;

-- =============================================================================
-- FACT: 工厂能耗碳排放 (月度, Scope 2 电力)
-- =============================================================================

INSERT INTO fact_factory_energy_consumption (factory_id, period_month, scope_id, energy_type, consumption_kwh, emission_factor_kgco2e_per_kwh, total_emission_tco2e, renewable_pct)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '1 month'::INTERVAL) AS d
),
fac_energy AS (
    SELECT
        f.factory_id, f.country_id,
        v.grid_kwh, v.gas_mj, v.renew_pct, v.ef
    FROM (VALUES
        ('FAC-CN-SH', 8500000, 1200000, 0.12, 0.581),
        ('FAC-CN-WH', 4200000,  800000, 0.15, 0.581),
        ('FAC-CN-CQ', 2800000,  500000, 0.10, 0.581),
        ('FAC-DE-LZ', 3800000,  600000, 0.45, 0.366),
        ('FAC-DE-MU', 1200000,  250000, 0.60, 0.366),
        ('FAC-US-TX', 5500000,  900000, 0.35, 0.420),
        ('FAC-US-OH', 2200000,  400000, 0.28, 0.420),
        ('FAC-HU-DE', 2600000,  450000, 0.38, 0.270),
        ('FAC-MX-MO', 1800000,  320000, 0.20, 0.450),
        ('FAC-TH-AM', 1500000,  280000, 0.18, 0.510)
    ) AS v(fac_code, grid_kwh, gas_mj, renew_pct, ef)
    JOIN dim_factory f ON f.factory_code = v.fac_code
)
SELECT
    fe.factory_id,
    m.m,
    (SELECT scope_id FROM dim_emission_scope WHERE scope_code='S2'),
    'GRID_ELEC',
    ROUND((fe.grid_kwh * (0.85 + (EXTRACT(MONTH FROM m.m) % 4) * 0.05))::NUMERIC, 2),
    fe.ef,
    ROUND((fe.grid_kwh * (0.85 + (EXTRACT(MONTH FROM m.m) % 4) * 0.05) * fe.ef / 1000)::NUMERIC, 4),
    ROUND((fe.renew_pct * (1 + (fe.factory_id % 5) * 0.02))::NUMERIC, 4)
FROM fac_energy fe
CROSS JOIN months m;

-- Scope 1 天然气
INSERT INTO fact_factory_energy_consumption (factory_id, period_month, scope_id, energy_type, consumption_mj, emission_factor_kgco2e_per_kwh, total_emission_tco2e, renewable_pct)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '1 month'::INTERVAL) AS d
),
fac_gas AS (
    SELECT f.factory_id,
           v.gas_mj
    FROM (VALUES
        ('FAC-CN-SH',1200000),('FAC-CN-WH',800000),('FAC-DE-LZ',600000),
        ('FAC-US-TX',900000), ('FAC-HU-DE',450000),('FAC-MX-MO',320000)
    ) AS v(fac_code, gas_mj)
    JOIN dim_factory f ON f.factory_code = v.fac_code
)
SELECT
    fg.factory_id,
    m.m,
    (SELECT scope_id FROM dim_emission_scope WHERE scope_code='S1'),
    'NATURAL_GAS',
    ROUND((fg.gas_mj * (0.9 + (EXTRACT(MONTH FROM m.m) % 3) * 0.05))::NUMERIC, 2),
    0.0000556,
    ROUND((fg.gas_mj * (0.9 + (EXTRACT(MONTH FROM m.m) % 3) * 0.05) * 0.0000556)::NUMERIC, 4),
    0.0
FROM fac_gas fg
CROSS JOIN months m;

-- =============================================================================
-- FACT: 零部件碳足迹
-- =============================================================================

INSERT INTO fact_component_carbon_footprint (component_id, factory_id, calc_year, scope1_kgco2e_per_unit, scope2_kgco2e_per_unit, scope3_kgco2e_per_unit)
SELECT
    c.component_id,
    f.factory_id,
    yr,
    ROUND((v.s1 * (1 - (yr - 2022) * 0.03))::NUMERIC, 4),
    ROUND((v.s2 * (1 - (yr - 2022) * 0.05) * CASE f.country_code WHEN 'DE' THEN 0.63 WHEN 'US' THEN 0.72 ELSE 1.0 END)::NUMERIC, 4),
    ROUND((v.s3 * (1 - (yr - 2022) * 0.02))::NUMERIC, 4)
FROM (VALUES
    ('BP-100-NMC', 8.5,  125.0, 680.0),
    ('BP-075-LFP', 5.2,   88.0, 420.0),
    ('BP-050-LFP', 3.8,   62.0, 310.0),
    ('BP-120-NMC', 9.8,  142.0, 780.0),
    ('MTR-200KW-PMSM',2.1, 18.0, 95.0),
    ('MTR-150KW-PMSM',1.7, 14.0, 75.0),
    ('INV-200KW-SIC', 0.8, 6.5,  42.0),
    ('BM-NMC-12S', 0.6,  8.2,  48.0),
    ('BM-LFP-16S', 0.4,  6.1,  32.0)
) AS v(comp_code, s1, s2, s3)
JOIN dim_component c ON c.component_code = v.comp_code
CROSS JOIN (
    SELECT f.factory_id, cnt.country_code
    FROM dim_factory f JOIN dim_country cnt ON cnt.country_id = f.country_id
    WHERE f.factory_code IN ('FAC-CN-SH','FAC-DE-LZ','FAC-US-TX','FAC-HU-DE')
) f
CROSS JOIN generate_series(2022, 2024) AS yr;

-- =============================================================================
-- FACT: 碳税 (月度, 仅欧盟+英国)
-- =============================================================================

INSERT INTO fact_carbon_tax (factory_id, period_month, country_id, total_emission_tco2e, free_allowance_tco2e, taxable_emission_tco2e, carbon_price_usd_per_tco2e, carbon_tax_usd)
SELECT
    ec.factory_id,
    ec.period_month,
    f.country_id,
    ec.total_emission_tco2e,
    ROUND((ec.total_emission_tco2e * 0.30)::NUMERIC, 4),
    ROUND((ec.total_emission_tco2e * 0.70)::NUMERIC, 4),
    cp.price_usd_per_tco2e,
    ROUND((ec.total_emission_tco2e * 0.70 * cp.price_usd_per_tco2e)::NUMERIC, 2)
FROM (
    SELECT factory_id, period_month, SUM(total_emission_tco2e) AS total_emission_tco2e
    FROM fact_factory_energy_consumption
    GROUP BY factory_id, period_month
) ec
JOIN dim_factory f ON f.factory_id = ec.factory_id
JOIN dim_country fc ON fc.country_id = f.country_id
JOIN LATERAL (
    SELECT price_usd_per_tco2e FROM fact_carbon_price
    WHERE country_id = f.country_id
    ORDER BY ABS(price_date - ec.period_month) LIMIT 1
) cp ON TRUE
WHERE fc.country_code IN ('DE','FR','HU','PL','GB');

-- =============================================================================
-- FACT: 运输碳排放
-- =============================================================================

INSERT INTO fact_shipping_emission (shipping_id, transport_mode, distance_km, weight_mt, emission_factor_kgco2e_per_tkm, total_emission_kgco2e)
SELECT
    s.shipping_id,
    tl.transport_mode,
    tl.transit_days * CASE tl.transport_mode WHEN 'SEA' THEN 800 WHEN 'AIR' THEN 900 WHEN 'ROAD' THEN 400 ELSE 500 END,
    COALESCE(fc.weight_kg / 1000.0, 5.0),
    CASE tl.transport_mode WHEN 'SEA' THEN 0.011 WHEN 'AIR' THEN 0.602 WHEN 'ROAD' THEN 0.095 ELSE 0.050 END,
    ROUND((COALESCE(fc.weight_kg / 1000.0, 5.0)
        * tl.transit_days * CASE tl.transport_mode WHEN 'SEA' THEN 800 WHEN 'AIR' THEN 900 WHEN 'ROAD' THEN 400 ELSE 500 END
        * CASE tl.transport_mode WHEN 'SEA' THEN 0.011 WHEN 'AIR' THEN 0.602 WHEN 'ROAD' THEN 0.095 ELSE 0.050 END
    )::NUMERIC, 2)
FROM fact_shipping_order s
JOIN fact_trade_lane tl ON tl.lane_id = s.lane_id
LEFT JOIN fact_freight_cost fc ON fc.so_id = s.so_id;

-- =============================================================================
-- FACT: 保修索赔 (~800条)
-- =============================================================================

INSERT INTO fact_warranty_claim (claim_no, customer_id, component_id, failure_id, so_item_id, claim_date, failure_date, mileage_km, claim_qty, claim_amount_usd, approved_amount_usd, status, root_cause_analysis)
SELECT
    'WC-' || TO_CHAR(soi.so_id * 10000 + soi.so_item_id, 'FM0000000000'),
    so.customer_id,
    soi.component_id,
    fm.failure_id,
    soi.so_item_id,
    so.actual_delivery_date + (EXTRACT(MONTH FROM so.actual_delivery_date)::INT * 30 + soi.so_item_id % 300),
    so.actual_delivery_date + (soi.so_item_id % 200)::INT,
    (soi.so_item_id % 80000 + 5000)::NUMERIC,
    1,
    ROUND((soi.net_unit_price * 0.15)::NUMERIC, 2),
    ROUND((soi.net_unit_price * 0.12)::NUMERIC, 2),
    (ARRAY['APPROVED','UNDER_REVIEW','PAID','REJECTED'])[(soi.so_item_id % 4) + 1],
    (ARRAY[
        'Root cause: manufacturing defect in cell formation process. Corrective action: SPC tightening.',
        'Root cause: supplier incoming quality escape. Corrective action: enhanced IQC protocol.',
        'Root cause: design specification boundary condition. Corrective action: firmware OTA update.',
        'Root cause: customer misuse / improper charging. Claim rejected.',
        'Root cause: thermal management boundary case at extreme temp. Corrective action: revised cooling map.'
    ])[(soi.so_item_id % 5) + 1]
FROM fact_sales_order_item soi
JOIN fact_sales_order so ON so.so_id = soi.so_id
JOIN dim_failure_mode fm ON fm.failure_id = (soi.so_item_id % 12) + 1
WHERE so.status = 'CLOSED'
  AND (soi.so_item_id % 15) < 2
LIMIT 800;

-- =============================================================================
-- FACT: 返利
-- =============================================================================

INSERT INTO fact_rebate (customer_id, component_id, period_year, period_quarter, rebate_type, rebate_amount_usd, basis_revenue_usd, rebate_rate, paid_date)
SELECT
    c.customer_id,
    NULL,
    yr,
    qtr,
    rtype,
    ROUND((c.credit_limit_usd * 0.02 * (0.8 + (c.customer_id % 5) * 0.1))::NUMERIC, 2),
    ROUND((c.credit_limit_usd * 0.40)::NUMERIC, 2),
    0.0200,
    TO_DATE(yr::TEXT || '-' || (qtr * 3 + 1)::TEXT || '-15', 'YYYY-MM-DD')
FROM dim_customer c
CROSS JOIN generate_series(2023, 2024) AS yr
CROSS JOIN generate_series(1, 4) AS qtr
CROSS JOIN (VALUES ('VOLUME')) AS rt(rtype)
WHERE c.is_strategic = TRUE;

-- =============================================================================
-- FACT: 断货事件
-- =============================================================================

INSERT INTO fact_stockout_event (event_date, warehouse_id, component_id, stockout_days, lost_demand_qty, lost_revenue_est_usd, root_cause)
SELECT
    '2023-01-01'::DATE + (rn * 11 % 820),
    wh.warehouse_id,
    c.component_id,
    (rn % 5) + 1,
    ROUND((rn % 50 + 10)::NUMERIC, 2),
    ROUND((c.list_price_usd * ((rn % 50) + 10))::NUMERIC, 2),
    (ARRAY['SUPPLIER_DELAY','DEMAND_SPIKE','TRANSPORT_DISRUPTION','FORECAST_ERROR','QUALITY_HOLD'])[(rn % 5) + 1]
FROM (SELECT ROW_NUMBER() OVER () AS rn, warehouse_id FROM dim_warehouse WHERE warehouse_type='FG') wh
CROSS JOIN (SELECT component_id, list_price_usd, ROW_NUMBER() OVER (ORDER BY component_id) AS cn FROM dim_component WHERE is_finished_good=TRUE) c
WHERE (wh.rn + c.cn) % 7 < 2
LIMIT 200;

-- =============================================================================
-- FACT: 碳信用
-- =============================================================================

INSERT INTO fact_carbon_credit (factory_id, credit_date, credit_type, qty_tco2e, purchase_price_usd, total_cost_usd, retired_qty)
SELECT
    f.factory_id,
    '2023-01-01'::DATE + (f.factory_id * 45 % 365),
    (ARRAY['VCS','GOLD_STANDARD','I_REC'])[(f.factory_id % 3) + 1],
    ROUND((5000 + f.factory_id * 800)::NUMERIC, 2),
    ROUND((12.0 + f.factory_id * 1.5)::NUMERIC, 2),
    ROUND((5000 + f.factory_id * 800) * (12.0 + f.factory_id * 1.5)::NUMERIC, 2),
    ROUND((2000 + f.factory_id * 300)::NUMERIC, 2)
FROM dim_factory f;

INSERT INTO fact_carbon_credit (factory_id, credit_date, credit_type, qty_tco2e, purchase_price_usd, total_cost_usd, retired_qty)
SELECT
    f.factory_id,
    '2024-01-01'::DATE + (f.factory_id * 60 % 365),
    (ARRAY['VCS','CCER','I_REC'])[(f.factory_id % 3) + 1],
    ROUND((6000 + f.factory_id * 900)::NUMERIC, 2),
    ROUND((14.0 + f.factory_id * 1.8)::NUMERIC, 2),
    ROUND((6000 + f.factory_id * 900) * (14.0 + f.factory_id * 1.8)::NUMERIC, 2),
    ROUND((3000 + f.factory_id * 400)::NUMERIC, 2)
FROM dim_factory f;

-- =============================================================================
-- FACT: 现场失效率
-- =============================================================================

INSERT INTO fact_field_failure (component_id, failure_id, country_id, failure_month, units_in_field, failure_count, campaign_cost_usd)
WITH months AS (
    SELECT DATE_TRUNC('month', d)::DATE AS m
    FROM generate_series('2023-01-01'::DATE, '2025-03-31'::DATE, '1 month'::INTERVAL) AS d
)
SELECT
    c.component_id,
    fm.failure_id,
    cnt.country_id,
    m.m,
    ROUND((10000 + (c.component_id * cnt.country_id * 37) % 50000)::NUMERIC, 2),
    ROUND((50 + (c.component_id * 7 + cnt.country_id * 11 + EXTRACT(MONTH FROM m.m)::INT * 3) % 200)::INT, 0),
    ROUND(((50 + (c.component_id * 7 + cnt.country_id * 11 + EXTRACT(MONTH FROM m.m)::INT * 3) % 200) * 1500.0)::NUMERIC, 2)
FROM dim_component c
CROSS JOIN dim_failure_mode fm
CROSS JOIN dim_country cnt
CROSS JOIN months m
WHERE c.is_finished_good = TRUE
  AND cnt.country_code IN ('CN','DE','US','JP','KR')
  AND fm.failure_id % 4 = c.component_id % 4
LIMIT 2000;

-- =============================================================================
-- FACT: 价格协议（战略客户）
-- =============================================================================

INSERT INTO fact_price_agreement (agreement_no, customer_id, component_id, currency_id, agreed_price, discount_pct, min_qty_per_year, effective_from, effective_to, is_active)
SELECT
    'PA-' || LPAD((c.customer_id * 100 + comp.component_id)::TEXT, 6, '0'),
    c.customer_id,
    comp.component_id,
    c.currency_id,
    ROUND((comp.list_price_usd * 0.88)::NUMERIC, 4),
    0.1200,
    ROUND((c.credit_limit_usd / NULLIF(comp.list_price_usd, 0) * 0.5)::NUMERIC, 2),
    '2024-01-01',
    '2025-12-31',
    TRUE
FROM dim_customer c
CROSS JOIN dim_component comp
WHERE c.is_strategic = TRUE
  AND comp.is_finished_good = TRUE
  AND (c.customer_id + comp.component_id) % 3 = 0;

-- =============================================================================
-- ANALYZE - 更新统计信息
-- =============================================================================

ANALYZE geo.dim_country;
ANALYZE geo.dim_currency;
ANALYZE product.dim_component;
ANALYZE product.dim_raw_material;
ANALYZE procurement.dim_supplier;
ANALYZE sales.dim_customer;
ANALYZE sales.fact_sales_order;
ANALYZE sales.fact_sales_order_item;
ANALYZE production.fact_production_order;
ANALYZE production.fact_quality_inspection;
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
            SELECT relname, reltuples::BIGINT
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE c.relkind = 'r'
              AND n.nspname = schema_name
            ORDER BY reltuples DESC
        LOOP
            total := total + GREATEST(cnt, 0);
            RAISE NOTICE '[%] % => ~% rows', schema_name, tbl, cnt;
        END LOOP;
    END LOOP;
    RAISE NOTICE '=== Total estimated rows across all schemas: % ===', total;
    RAISE NOTICE '=== EV Parts Lakehouse seed data loaded successfully! ===';
END;
$$;
