-- =============================================================================
-- Tesla OEM Lakehouse - Cross-Schema Views (in public schema)
-- PostgreSQL 16
-- =============================================================================

SET search_path TO public, sales, product, procurement, production, esg, geo, inventory, finance, logistics, aftersales;

-- =============================================================================
-- VIEW: 单车毛利率 (含运费/关税/碳税分摊)
-- =============================================================================

CREATE OR REPLACE VIEW v_vehicle_gross_margin AS
SELECT
    soi.so_item_id,
    so.so_number,
    so.vin,
    so.order_date,
    c.customer_name,
    c.customer_type,
    cp.country_name            AS ship_to_country,
    comp.component_code        AS vehicle_code,
    comp.component_name        AS vehicle_name,
    soi.net_line_amount        AS net_revenue,
    soi.std_material_cost      AS std_material_cost,
    soi.manufacturing_cost     AS manufacturing_cost,
    COALESCE(so.total_freight_cost, 0) AS freight_cost,
    COALESCE(so.total_tariff_cost,  0) AS tariff_cost,
    (soi.net_line_amount
        - soi.std_material_cost
        - soi.manufacturing_cost
        - COALESCE(so.total_freight_cost, 0)
        - COALESCE(so.total_tariff_cost,  0)
    ) AS adjusted_gross_margin,
    CASE WHEN soi.net_line_amount > 0
        THEN ROUND(((soi.net_line_amount - soi.std_material_cost - soi.manufacturing_cost
                     - COALESCE(so.total_freight_cost, 0) - COALESCE(so.total_tariff_cost, 0))
                    / soi.net_line_amount * 100)::NUMERIC, 2)
    END AS adj_gm_rate_pct
FROM sales.fact_sales_order_item soi
JOIN sales.fact_sales_order so    ON so.so_id = soi.so_id
JOIN sales.dim_customer c         ON c.customer_id = so.customer_id
JOIN geo.dim_country  cp          ON cp.country_id = so.ship_to_country_id
JOIN product.dim_component comp   ON comp.component_id = soi.component_id
WHERE comp.is_finished_good = TRUE;

COMMENT ON VIEW v_vehicle_gross_margin IS 'Tesla单车调整后毛利视图（含运费/关税全分摊），仅整车';

-- =============================================================================
-- VIEW: 供应商风险综合评分卡 (ESG + 质量 + 交期)
-- =============================================================================

CREATE OR REPLACE VIEW v_supplier_risk_scorecard AS
SELECT
    s.supplier_code,
    s.supplier_name,
    cnt.country_name,
    s.tier,
    s.risk_rating,
    ROUND(AVG(esg.overall_score),2)             AS avg_esg_score,
    ROUND(AVG(sq.defect_ppm),2)                 AS avg_defect_ppm,
    COUNT(CASE WHEN sd.is_on_time = FALSE THEN 1 END)::NUMERIC /
        NULLIF(COUNT(sd.delivery_id),0) * 100    AS late_delivery_rate_pct
FROM procurement.dim_supplier s
LEFT JOIN geo.dim_country cnt       ON cnt.country_id = s.country_id
LEFT JOIN esg.fact_supplier_esg_score esg ON esg.supplier_id = s.supplier_id
LEFT JOIN procurement.fact_supplier_quality  sq   ON sq.supplier_id = s.supplier_id
LEFT JOIN procurement.fact_supplier_delivery sd   ON sd.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.supplier_code, s.supplier_name, cnt.country_name, s.tier, s.risk_rating;

COMMENT ON VIEW v_supplier_risk_scorecard IS '供应商风险综合评分卡：ESG + 质量 + 交期';

-- =============================================================================
-- VIEW: 工厂生产效率 (按工厂/产线/月度)
-- =============================================================================

CREATE OR REPLACE VIEW v_factory_efficiency AS
SELECT
    f.factory_code,
    f.factory_name,
    l.line_code,
    l.line_name,
    DATE_TRUNC('month', po.planned_start)::DATE AS prod_month,
    COUNT(*)                                    AS order_count,
    SUM(po.planned_qty)                        AS planned_qty,
    SUM(po.actual_qty)                         AS actual_qty,
    SUM(po.scrap_qty)                          AS total_scrap,
    ROUND(AVG(po.actual_qty / NULLIF(po.planned_qty, 0))::NUMERIC, 4) AS yield_rate,
    ROUND(SUM(po.scrap_qty) / NULLIF(SUM(po.actual_qty + po.scrap_qty), 0)::NUMERIC, 4) AS scrap_rate,
    ROUND(AVG(po.actual_material_cost_usd)::NUMERIC, 2) AS avg_material_cost
FROM production.fact_production_order po
JOIN production.dim_factory f        ON f.factory_id = po.factory_id
JOIN production.dim_production_line l ON l.line_id = po.line_id
WHERE po.status = 'COMPLETED'
GROUP BY f.factory_code, f.factory_name, l.line_code, l.line_name,
         DATE_TRUNC('month', po.planned_start)
ORDER BY prod_month DESC, scrap_rate DESC;

COMMENT ON VIEW v_factory_efficiency IS '工厂/产线月度效率：良率、报废率、材料成本';

-- =============================================================================
-- VIEW: 单车碳足迹概览
-- =============================================================================

CREATE OR REPLACE VIEW v_vehicle_carbon_footprint AS
SELECT
    comp.component_code,
    comp.component_name,
    f.factory_code,
    f.factory_name,
    cnt.country_name,
    pcf.calc_year,
    ROUND(pcf.scope1_kgco2e_per_unit, 2) AS scope1_kg,
    ROUND(pcf.scope2_kgco2e_per_unit, 2) AS scope2_kg,
    ROUND(pcf.scope3_kgco2e_per_unit, 2) AS scope3_kg,
    ROUND(pcf.total_kgco2e_per_unit, 2)  AS total_kgco2e,
    RANK() OVER (PARTITION BY pcf.component_id, pcf.calc_year
                 ORDER BY pcf.total_kgco2e_per_unit) AS carbon_rank
FROM esg.fact_component_carbon_footprint pcf
JOIN product.dim_component comp ON comp.component_id = pcf.component_id
JOIN production.dim_factory f    ON f.factory_id = pcf.factory_id
JOIN geo.dim_country cnt         ON cnt.country_id = f.country_id
WHERE comp.is_finished_good = TRUE
ORDER BY pcf.calc_year DESC, pcf.total_kgco2e_per_unit;

COMMENT ON VIEW v_vehicle_carbon_footprint IS '各工厂生产的各车型碳足迹对比（按年度排名）';

-- =============================================================================
-- VIEW: 净利润明细（ALL in：含碳税分摊）
-- =============================================================================

DROP VIEW IF EXISTS public.v_net_profit CASCADE;
CREATE VIEW v_net_profit AS
WITH order_carbon_tax AS (
    SELECT
        so.so_number,
        ct.carbon_tax_usd * (so.total_net_revenue /
            NULLIF(SUM(so.total_net_revenue) OVER (PARTITION BY ct.factory_id, ct.period_month), 0)
        ) AS carbon_tax_apportioned
    FROM sales.fact_sales_order so
    JOIN esg.fact_carbon_tax ct ON ct.factory_id = so.ship_from_factory_id
        AND date_trunc('month', so.order_date) = ct.period_month
    WHERE so.status = 'DELIVERED'
)
SELECT
    v.so_item_id,
    v.so_number,
    v.vin,
    v.order_date,
    v.customer_name,
    v.customer_type,
    v.ship_to_country,
    v.vehicle_code,
    v.vehicle_name,
    v.net_revenue,
    v.std_material_cost AS material_cost,
    v.manufacturing_cost,
    v.freight_cost,
    v.tariff_cost,
    COALESCE(oct.carbon_tax_apportioned, 0) AS carbon_tax,
    0::numeric AS carbon_cost,
    v.adjusted_gross_margin AS gross_margin,
    v.adjusted_gross_margin - COALESCE(oct.carbon_tax_apportioned, 0) AS net_profit,
    CASE WHEN v.net_revenue > 0
         THEN ROUND((v.adjusted_gross_margin - COALESCE(oct.carbon_tax_apportioned, 0)) / v.net_revenue * 100, 2)
    END AS net_profit_margin_pct,
    soi.qty,
    so.ship_from_factory_id,
    f.factory_code,
    f.factory_name
FROM v_vehicle_gross_margin v
JOIN sales.fact_sales_order_item soi ON soi.so_item_id = v.so_item_id
JOIN sales.fact_sales_order so ON so.so_number = v.so_number
JOIN production.dim_factory f ON f.factory_id = so.ship_from_factory_id
LEFT JOIN order_carbon_tax oct ON oct.so_number = v.so_number;

COMMENT ON VIEW v_net_profit IS '净利润明细：含碳税、数量、工厂。ALL-in成本后的真实净利';

-- =============================================================================
-- VIEW: 供应商交付计分卡（交期+质量）
-- =============================================================================

CREATE OR REPLACE VIEW v_supplier_delivery_scorecard AS
SELECT
    s.supplier_id,
    s.supplier_code,
    s.supplier_name,
    s.tier,
    s.country_id,
    s.payment_terms_days,
    s.is_strategic,
    s.risk_rating,
    COUNT(d.delivery_id) AS total_deliveries,
    ROUND(100.0 * SUM(CASE WHEN d.is_on_time THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0), 1) AS on_time_pct,
    ROUND(AVG(d.days_late)::numeric, 1) AS avg_days_late,
    MAX(d.days_late) AS max_days_late,
    ROUND(AVG(q.defect_ppm)::numeric, 0) AS avg_defect_ppm
FROM procurement.dim_supplier s
LEFT JOIN procurement.fact_supplier_delivery d ON d.supplier_id = s.supplier_id
LEFT JOIN procurement.fact_supplier_quality q ON q.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.supplier_code, s.supplier_name, s.tier, s.country_id,
         s.payment_terms_days, s.is_strategic, s.risk_rating
ORDER BY avg_days_late DESC NULLS LAST;

COMMENT ON VIEW v_supplier_delivery_scorecard IS '供应商交付计分卡：准时率、平均延迟、来料不良PPM';

-- =============================================================================
-- VIEW: 生产单位成本（规模效应分析）
-- =============================================================================

CREATE OR REPLACE VIEW v_production_unit_cost AS
SELECT
    po.prod_order_no,
    po.factory_id,
    po.line_id,
    po.component_id,
    po.actual_qty,
    po.scrap_qty,
    po.actual_labor_cost_usd,
    po.actual_material_cost_usd,
    po.actual_overhead_cost_usd,
    ROUND((po.actual_labor_cost_usd + po.actual_material_cost_usd + po.actual_overhead_cost_usd) 
          / NULLIF(po.actual_qty, 0), 2) AS unit_cost_usd,
    ROUND(100.0 * po.scrap_qty / NULLIF(po.actual_qty, 0), 2) AS scrap_rate_pct
FROM production.fact_production_order po
WHERE po.status = 'COMPLETED';

COMMENT ON VIEW v_production_unit_cost IS '生产单位成本：批次产量 vs 单件成本，用于规模效应分析';
