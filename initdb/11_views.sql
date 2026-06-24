-- =============================================================================
-- EV Parts Lakehouse - Cross-Schema Views (in public schema)
-- PostgreSQL 16
-- =============================================================================

SET search_path TO public, sales, product, procurement, production, esg, geo, inventory, finance, logistics, aftersales;

-- =============================================================================
-- VIEW: 行项目调整后毛利
-- =============================================================================

CREATE OR REPLACE VIEW v_adjusted_gross_margin AS
SELECT
    soi.so_item_id,
    so.so_number,
    so.order_date,
    c.customer_name,
    cp.country_name            AS ship_to_country,
    comp.component_code,
    comp.component_name,
    soi.qty,
    soi.net_line_amount        AS net_revenue,
    soi.std_material_cost * soi.qty AS std_material_cost,
    soi.manufacturing_cost * soi.qty AS manufacturing_cost,
    COALESCE(so.total_freight_cost * (soi.net_line_amount / NULLIF(so.total_net_revenue,0)), 0) AS allocated_freight,
    COALESCE(so.total_tariff_cost  * (soi.net_line_amount / NULLIF(so.total_net_revenue,0)), 0) AS allocated_tariff,
    (soi.net_line_amount
        - soi.std_material_cost * soi.qty
        - soi.manufacturing_cost * soi.qty
        - COALESCE(so.total_freight_cost * (soi.net_line_amount / NULLIF(so.total_net_revenue,0)), 0)
        - COALESCE(so.total_tariff_cost  * (soi.net_line_amount / NULLIF(so.total_net_revenue,0)), 0)
    ) AS adjusted_gross_margin
FROM sales.fact_sales_order_item soi
JOIN sales.fact_sales_order so    ON so.so_id = soi.so_id
JOIN sales.dim_customer c         ON c.customer_id = so.customer_id
JOIN geo.dim_country  cp          ON cp.country_id = so.ship_to_country_id
JOIN product.dim_component comp   ON comp.component_id = soi.component_id;

COMMENT ON VIEW v_adjusted_gross_margin IS '行项目调整后毛利视图（扣除运费、关税按净收入比例分摊）';

-- =============================================================================
-- VIEW: 供应商风险综合评分卡
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
