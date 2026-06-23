# Sample Analysis Questions & Reference SQL

> **数据库**：`ev_parts`　**连接串**：`postgresql://ev_user:ev_password@localhost:5432/ev_parts`
>
> 本文件列出 10 大业务场景的分析问题，每题附 **口径说明** + **可直接执行的参考 SQL**。
> 所有 SQL 在 PostgreSQL 16 上测试可运行。

---

## 目录

| # | 场景 | 核心指标 |
|---|------|----------|
| Q1 | 不同国家销售同一零部件的调整后毛利率 | Adjusted Gross Margin Rate |
| Q2 | 利率上升 1% 对库存资金占用成本的影响 | Inventory Carrying Cost |
| Q3 | 德国碳税对电池模组毛利率的影响 | Carbon Tax Cost, Gross Margin |
| Q4 | 哪个国家工厂生产电池包的单位碳排最低 | Carbon Emission per Unit |
| Q5 | 关税 + 物流让哪些跨国订单亏损 | Adjusted Gross Margin |
| Q6 | 供应商 ESG 风险高且质量缺陷率也高 | Supplier Defect Rate, ESG Score |
| Q7 | 锂价上涨影响哪些 BOM 产品 | Standard Material Cost |
| Q8 | 哪些国家应收账款融资成本最高 | Receivable Financing Cost |
| Q9 | 哪些产品在不同国家存在价格倒挂 | Country Price List |
| Q10 | 本地生产 vs 跨国出口调整后毛利对比 | Adjusted Gross Margin |

---

## 指标口径定义

```
Gross Revenue              = SUM(soi.gross_line_amount)          -- 含折扣前收入
Net Revenue                = SUM(soi.net_line_amount)            -- 扣减折扣后
Standard Material Cost     = SUM(po.standard_material_cost)      -- BOM 标准材料成本
Manufacturing Cost         = SUM(po.actual_total_cost)           -- 实际制造成本（含人工、制造费用）
Freight Cost               = SUM(fc.total_freight_usd)           -- USD 运费+保险+装卸
Tariff Cost                = SUM(so.total_tariff_cost)           -- 关税 = 货值 * tariff_pct
Carbon Tax Cost            = SUM(ct.carbon_tax_usd)              -- 碳税支出（EU/UK ETS 等）
Inventory Carrying Cost    = inventory_value * (interest_rate
                             + storage_rate + obsolescence_rate)
                             * days / 365                        -- 参见 fact_inventory_carrying_cost
Receivable Financing Cost  = outstanding_amount * annual_rate
                             * days_outstanding / 360            -- 参见 fact_receivable_aging
Gross Margin               = Net Revenue - Standard Material Cost
                             - Manufacturing Cost
Adjusted Gross Margin      = Gross Margin
                             - Freight Cost (分摊)
                             - Tariff Cost  (分摊)
                             - Carbon Tax Cost (分摊)
                             - Inventory Carrying Cost (分摊)
                             - Receivable Financing Cost (分摊)
Adjusted Gross Margin Rate = Adjusted Gross Margin / Net Revenue
FX Impact                  = (actual_fx_rate - budget_fx_rate) * foreign_currency_revenue
Carbon Emission per Unit   = total_kgco2e / qty_produced
Carbon Cost per Unit       = carbon_tax_usd / qty_produced
Supplier On-Time Delivery  = on_time_deliveries / total_deliveries * 100
Supplier Defect Rate       = defect_ppm / 1_000_000
First Pass Yield (FPY)     = qty_pass_first / qty_inspected * 100
Scrap Rate                 = qty_scrapped / qty_produced * 100
Stockout Rate              = stockout_days / total_days * 100
```

---

## Q1 — 不同国家销售同一零部件的调整后毛利率

**业务问题**：同一款电池模组（COMP-006），在中国、德国、美国市场销售，扣除运费和关税后，哪个市场利润率最高？

**口径**：Adjusted Gross Margin Rate = (Net Revenue − Std Material Cost − Mfg Cost − 分摊运费 − 分摊关税) / Net Revenue

```sql
WITH item_cost AS (
    -- 行项目级：净收入、标准材料成本、制造成本
    SELECT
        soi.soi_id,
        soi.so_id,
        soi.component_id,
        comp.component_code,
        comp.component_name,
        cp_dest.country_name                                                   AS dest_country,
        soi.qty_ordered,
        soi.gross_line_amount,
        soi.net_line_amount,
        soi.std_material_cost_total,
        soi.manufacturing_cost_total,
        -- 按行项目净收入占订单净收入比例分摊运费和关税
        COALESCE(so.total_freight_cost, 0)
            * soi.net_line_amount / NULLIF(so.total_net_revenue, 0)            AS alloc_freight,
        COALESCE(so.total_tariff_cost, 0)
            * soi.net_line_amount / NULLIF(so.total_net_revenue, 0)            AS alloc_tariff
    FROM fact_sales_order_item soi
    JOIN fact_sales_order      so   ON so.so_id = soi.so_id
    JOIN dim_component         comp ON comp.component_id = soi.component_id
    JOIN dim_country           cp_dest ON cp_dest.country_id = so.ship_to_country_id
    WHERE comp.component_code = 'COMP-006'          -- 电池模组
      AND so.order_status NOT IN ('cancelled')
)
SELECT
    dest_country,
    COUNT(DISTINCT so_id)                                                       AS order_count,
    ROUND(SUM(net_line_amount)::NUMERIC, 0)                                     AS net_revenue_usd,
    ROUND(SUM(std_material_cost_total + manufacturing_cost_total)::NUMERIC, 0)  AS total_cost_usd,
    ROUND(SUM(alloc_freight)::NUMERIC, 0)                                       AS total_freight_usd,
    ROUND(SUM(alloc_tariff)::NUMERIC, 0)                                        AS total_tariff_usd,
    ROUND((
        SUM(net_line_amount)
        - SUM(std_material_cost_total + manufacturing_cost_total)
        - SUM(alloc_freight)
        - SUM(alloc_tariff)
    )::NUMERIC, 0)                                                              AS adj_gross_margin_usd,
    ROUND((
        (SUM(net_line_amount)
         - SUM(std_material_cost_total + manufacturing_cost_total)
         - SUM(alloc_freight)
         - SUM(alloc_tariff))
        / NULLIF(SUM(net_line_amount), 0) * 100
    )::NUMERIC, 2)                                                              AS adj_gm_rate_pct
FROM item_cost
GROUP BY dest_country
ORDER BY adj_gm_rate_pct DESC NULLS LAST;
```

**预期洞察**：发往美国的订单因 27.5% 关税，调整后毛利率可能为负；德国因 17.8% EU 反补贴税次之；中国本地最高。

---

## Q2 — 利率上升 1% 对库存资金占用成本的影响

**业务问题**：当前各仓库每月库存持有成本是多少？如果基准利率整体上升 1%，全年额外成本是多少？

**口径**：Inventory Carrying Cost = inventory_value × (interest_rate + storage_rate + obsolescence_rate) × days / 365

```sql
-- 2a. 当前各仓库实际库存持有成本（最近 12 个月）
SELECT
    w.warehouse_name,
    w.country_id,
    cnt.country_name,
    DATE_TRUNC('month', icc.period_date)::DATE                 AS period_month,
    ROUND(SUM(icc.inventory_value_usd)::NUMERIC, 0)            AS inventory_value_usd,
    ROUND(AVG(icc.interest_rate_annual)::NUMERIC, 4)           AS avg_interest_rate,
    ROUND(AVG(icc.storage_rate_annual)::NUMERIC, 4)            AS avg_storage_rate,
    ROUND(AVG(icc.obsolescence_rate_annual)::NUMERIC, 4)       AS avg_obsolescence_rate,
    ROUND(SUM(icc.carrying_cost_usd)::NUMERIC, 0)              AS carrying_cost_usd
FROM fact_inventory_carrying_cost icc
JOIN dim_warehouse w   ON w.warehouse_id = icc.warehouse_id
JOIN dim_country   cnt ON cnt.country_id = w.country_id
WHERE icc.period_date >= CURRENT_DATE - INTERVAL '12 months'
GROUP BY w.warehouse_name, w.country_id, cnt.country_name,
         DATE_TRUNC('month', icc.period_date)
ORDER BY period_month DESC, carrying_cost_usd DESC;

-- 2b. 利率 +1% 情景分析：全年额外成本
WITH base AS (
    SELECT
        cnt.country_name,
        SUM(icc.inventory_value_usd)                           AS total_inventory_value,
        SUM(icc.carrying_cost_usd)                             AS current_carrying_cost,
        -- 额外成本 = 库存价值 × 1% × days/365
        SUM(icc.inventory_value_usd * 0.01 * icc.days_in_period / 365.0) AS extra_cost_1pct_rise
    FROM fact_inventory_carrying_cost icc
    JOIN dim_warehouse w   ON w.warehouse_id = icc.warehouse_id
    JOIN dim_country   cnt ON cnt.country_id = w.country_id
    WHERE icc.period_date >= DATE_TRUNC('year', CURRENT_DATE)
    GROUP BY cnt.country_name
)
SELECT
    country_name,
    ROUND(total_inventory_value::NUMERIC, 0)                   AS inventory_value_usd,
    ROUND(current_carrying_cost::NUMERIC, 0)                   AS current_carrying_cost_usd,
    ROUND(extra_cost_1pct_rise::NUMERIC, 0)                    AS extra_cost_if_rate_up_1pct,
    ROUND(extra_cost_1pct_rise / NULLIF(current_carrying_cost, 0) * 100 ::NUMERIC, 1)
                                                               AS pct_increase
FROM base
ORDER BY extra_cost_if_rate_up_1pct DESC;
```

---

## Q3 — 德国碳税对电池模组毛利率的影响

**业务问题**：德国工厂生产电池模组（COMP-006）每月碳税支出多少？占毛利的百分比是多少？

**口径**：Carbon Tax Cost 分摊至行项目 = 工厂月度碳税 × (该产品产量 / 工厂总产量)

```sql
WITH de_factory AS (
    -- 德国工厂
    SELECT f.factory_id, f.factory_name
    FROM dim_factory f
    JOIN dim_country c ON c.country_id = f.country_id
    WHERE c.country_code = 'DE'
),
monthly_production AS (
    -- 德国工厂各产品月度产量（仅 COMP-006）
    SELECT
        po.factory_id,
        DATE_TRUNC('month', po.planned_start_date)::DATE AS prod_month,
        po.component_id,
        SUM(po.qty_produced)                             AS qty_produced,
        SUM(po.actual_total_cost)                        AS mfg_cost_total
    FROM fact_production_order po
    WHERE po.factory_id IN (SELECT factory_id FROM de_factory)
      AND po.component_id = (SELECT component_id FROM dim_component WHERE component_code = 'COMP-006')
    GROUP BY po.factory_id, DATE_TRUNC('month', po.planned_start_date), po.component_id
),
factory_total_production AS (
    -- 德国工厂月度总产量（用于碳税分摊）
    SELECT
        po.factory_id,
        DATE_TRUNC('month', po.planned_start_date)::DATE AS prod_month,
        SUM(po.qty_produced)                             AS total_qty
    FROM fact_production_order po
    WHERE po.factory_id IN (SELECT factory_id FROM de_factory)
    GROUP BY po.factory_id, DATE_TRUNC('month', po.planned_start_date)
),
carbon_tax_monthly AS (
    SELECT ct.factory_id, ct.period_month, SUM(ct.carbon_tax_usd) AS carbon_tax_usd
    FROM fact_carbon_tax ct
    WHERE ct.factory_id IN (SELECT factory_id FROM de_factory)
    GROUP BY ct.factory_id, ct.period_month
),
sales_revenue AS (
    -- 德国工厂发货，COMP-006 净收入
    SELECT
        so.factory_id,
        DATE_TRUNC('month', so.order_date)::DATE AS order_month,
        SUM(soi.net_line_amount)                 AS net_revenue,
        SUM(soi.std_material_cost_total)         AS std_mat_cost
    FROM fact_sales_order_item soi
    JOIN fact_sales_order so ON so.so_id = soi.so_id
    WHERE so.factory_id IN (SELECT factory_id FROM de_factory)
      AND soi.component_id = (SELECT component_id FROM dim_component WHERE component_code = 'COMP-006')
    GROUP BY so.factory_id, DATE_TRUNC('month', so.order_date)
)
SELECT
    mp.prod_month,
    df.factory_name,
    mp.qty_produced,
    ROUND(sr.net_revenue::NUMERIC, 0)                                           AS net_revenue_usd,
    ROUND((sr.net_revenue - sr.std_mat_cost - mp.mfg_cost_total)::NUMERIC, 0)  AS gross_margin_usd,
    -- 碳税按产量比例分摊
    ROUND((ct.carbon_tax_usd * mp.qty_produced / NULLIF(ftp.total_qty, 0))::NUMERIC, 0)
                                                                                AS alloc_carbon_tax_usd,
    ROUND((ct.carbon_tax_usd * mp.qty_produced / NULLIF(ftp.total_qty, 0)
           / NULLIF(sr.net_revenue, 0) * 100)::NUMERIC, 2)                     AS carbon_tax_as_pct_revenue,
    ROUND(((sr.net_revenue - sr.std_mat_cost - mp.mfg_cost_total
            - ct.carbon_tax_usd * mp.qty_produced / NULLIF(ftp.total_qty, 0))
           / NULLIF(sr.net_revenue, 0) * 100)::NUMERIC, 2)                     AS adj_gm_after_carbon_pct
FROM monthly_production   mp
JOIN de_factory           df  ON df.factory_id = mp.factory_id
JOIN factory_total_production ftp ON ftp.factory_id = mp.factory_id AND ftp.prod_month = mp.prod_month
LEFT JOIN carbon_tax_monthly ct ON ct.factory_id = mp.factory_id AND ct.period_month = mp.prod_month
LEFT JOIN sales_revenue      sr ON sr.factory_id = mp.factory_id AND sr.order_month = mp.prod_month
ORDER BY mp.prod_month;
```

---

## Q4 — 哪个国家工厂生产电池包的单位碳排最低

**业务问题**：电池包（COMP-007）的 PCF（产品碳足迹）在各国工厂中如何分布？

**口径**：Carbon Emission per Unit = total_kgco2e_per_unit（已在 fact_component_carbon_footprint 中预计算）

```sql
SELECT
    comp.component_code,
    comp.component_name,
    f.factory_name,
    cnt.country_name,
    f.energy_mix_renewable_pct,
    pcf.assessment_year,
    ROUND(pcf.scope1_kgco2e_per_unit::NUMERIC, 3)              AS scope1_kg_per_unit,
    ROUND(pcf.scope2_kgco2e_per_unit::NUMERIC, 3)              AS scope2_kg_per_unit,
    ROUND(pcf.scope3_kgco2e_per_unit::NUMERIC, 3)              AS scope3_kg_per_unit,
    ROUND(pcf.total_kgco2e_per_unit::NUMERIC, 3)               AS total_kgco2e_per_unit,
    -- 同产品同年度排名
    RANK() OVER (
        PARTITION BY pcf.component_id, pcf.assessment_year
        ORDER BY pcf.total_kgco2e_per_unit
    )                                                           AS carbon_rank
FROM fact_component_carbon_footprint pcf
JOIN dim_component comp ON comp.component_id = pcf.component_id
JOIN dim_factory   f    ON f.factory_id = pcf.factory_id
JOIN dim_country   cnt  ON cnt.country_id = f.country_id
WHERE comp.component_code = 'COMP-007'          -- 电池包
ORDER BY pcf.assessment_year DESC, pcf.total_kgco2e_per_unit;
```

**扩展：跨所有成品的工厂碳排对比**

```sql
SELECT
    f.factory_name,
    cnt.country_name,
    f.energy_mix_renewable_pct                                 AS renewable_pct,
    COUNT(DISTINCT pcf.component_id)                           AS product_count,
    ROUND(AVG(pcf.total_kgco2e_per_unit)::NUMERIC, 3)         AS avg_kgco2e_per_unit,
    ROUND(MIN(pcf.total_kgco2e_per_unit)::NUMERIC, 3)         AS min_kgco2e_per_unit,
    ROUND(MAX(pcf.total_kgco2e_per_unit)::NUMERIC, 3)         AS max_kgco2e_per_unit
FROM fact_component_carbon_footprint pcf
JOIN dim_factory f    ON f.factory_id = pcf.factory_id
JOIN dim_country cnt  ON cnt.country_id = f.country_id
WHERE pcf.assessment_year = 2024
GROUP BY f.factory_name, cnt.country_name, f.energy_mix_renewable_pct
ORDER BY avg_kgco2e_per_unit;
```

---

## Q5 — 关税 + 物流成本让哪些跨国订单亏损

**业务问题**：列出调整后毛利为负（亏损）的跨国销售订单，按亏损金额排序。

**口径**：Adjusted Gross Margin = Net Revenue − Std Material Cost − Mfg Cost − Freight − Tariff

```sql
WITH order_margin AS (
    SELECT
        so.so_number,
        so.order_date,
        cnt_src.country_name                                    AS source_country,
        cnt_dst.country_name                                    AS dest_country,
        -- 是否跨国
        (so.factory_id IS DISTINCT FROM NULL
         AND cnt_src.country_id <> cnt_dst.country_id)         AS is_cross_border,
        SUM(soi.net_line_amount)                                AS net_revenue,
        SUM(soi.std_material_cost_total
            + soi.manufacturing_cost_total)                     AS total_cost,
        COALESCE(so.total_freight_cost, 0)                      AS freight_cost,
        COALESCE(so.total_tariff_cost, 0)                       AS tariff_cost,
        so.total_net_revenue,
        so.total_tariff_cost AS so_tariff,
        so.total_freight_cost AS so_freight
    FROM fact_sales_order so
    JOIN fact_sales_order_item soi ON soi.so_id = so.so_id
    JOIN dim_factory f             ON f.factory_id = so.factory_id
    JOIN dim_country cnt_src       ON cnt_src.country_id = f.country_id
    JOIN dim_country cnt_dst       ON cnt_dst.country_id = so.ship_to_country_id
    WHERE so.order_status NOT IN ('cancelled')
      AND cnt_src.country_id <> cnt_dst.country_id             -- 仅跨国订单
    GROUP BY so.so_id, so.so_number, so.order_date,
             cnt_src.country_name, cnt_dst.country_name,
             so.total_freight_cost, so.total_tariff_cost, so.total_net_revenue,
             f.country_id, cnt_src.country_id, cnt_dst.country_id
)
SELECT
    so_number,
    order_date,
    source_country,
    dest_country,
    ROUND(net_revenue::NUMERIC, 0)                              AS net_revenue_usd,
    ROUND(total_cost::NUMERIC, 0)                               AS prod_cost_usd,
    ROUND(freight_cost::NUMERIC, 0)                             AS freight_usd,
    ROUND(tariff_cost::NUMERIC, 0)                              AS tariff_usd,
    ROUND((net_revenue - total_cost - freight_cost - tariff_cost)::NUMERIC, 0)
                                                                AS adj_gross_margin_usd,
    ROUND(((net_revenue - total_cost - freight_cost - tariff_cost)
           / NULLIF(net_revenue, 0) * 100)::NUMERIC, 1)        AS adj_gm_pct,
    -- 关税+运费占收入比
    ROUND(((freight_cost + tariff_cost) / NULLIF(net_revenue, 0) * 100)::NUMERIC, 1)
                                                                AS tariff_freight_burden_pct
FROM order_margin
WHERE (net_revenue - total_cost - freight_cost - tariff_cost) < 0
ORDER BY adj_gross_margin_usd
LIMIT 50;
```

---

## Q6 — 供应商 ESG 风险高且质量缺陷率也高

**业务问题**：哪些供应商同时存在 ESG 评分低（< 60）且质量缺陷率高（> 500 PPM）的双重风险？

**口径**：直接使用预建视图 `v_supplier_risk_scorecard`，或展开如下：

```sql
-- 使用视图（最简洁）
SELECT *
FROM v_supplier_risk_scorecard
WHERE avg_esg_score < 60
  AND avg_defect_ppm > 500
ORDER BY avg_defect_ppm DESC, avg_esg_score;

-- 展开版：同时显示采购金额和主要供应零部件
WITH supplier_risk AS (
    SELECT
        s.supplier_id,
        s.supplier_code,
        s.supplier_name,
        cnt.country_name,
        s.tier,
        s.risk_rating,
        ROUND(AVG(esg.overall_score)::NUMERIC, 1)              AS avg_esg_score,
        ROUND(AVG(sq.defect_ppm)::NUMERIC, 0)                  AS avg_defect_ppm,
        COUNT(CASE WHEN sd.is_on_time = FALSE THEN 1 END)::NUMERIC
            / NULLIF(COUNT(sd.delivery_id), 0) * 100           AS late_delivery_pct
    FROM dim_supplier s
    JOIN dim_country cnt ON cnt.country_id = s.country_id
    LEFT JOIN fact_supplier_esg_score  esg ON esg.supplier_id = s.supplier_id
    LEFT JOIN fact_supplier_quality    sq  ON sq.supplier_id = s.supplier_id
    LEFT JOIN fact_supplier_delivery   sd  ON sd.supplier_id = s.supplier_id
    GROUP BY s.supplier_id, s.supplier_code, s.supplier_name,
             cnt.country_name, s.tier, s.risk_rating
),
supplier_spend AS (
    SELECT
        poi.supplier_id,
        SUM(poi.total_amount_usd)                              AS total_spend_usd,
        STRING_AGG(DISTINCT comp.component_name, '; ')         AS components_supplied
    FROM fact_purchase_order_item poi
    JOIN fact_purchase_order po    ON po.po_id = poi.po_id
    JOIN dim_component        comp ON comp.component_id = poi.component_id
    GROUP BY poi.supplier_id
)
SELECT
    sr.supplier_code,
    sr.supplier_name,
    sr.country_name,
    sr.tier,
    sr.risk_rating,
    ROUND(sr.avg_esg_score, 1)                                 AS avg_esg_score,
    ROUND(sr.avg_defect_ppm, 0)                                AS avg_defect_ppm,
    ROUND(sr.late_delivery_pct::NUMERIC, 1)                    AS late_delivery_pct,
    ROUND(ss.total_spend_usd::NUMERIC, 0)                      AS total_spend_usd,
    ss.components_supplied
FROM supplier_risk sr
LEFT JOIN supplier_spend ss ON ss.supplier_id = sr.supplier_id
WHERE sr.avg_esg_score < 60
  AND sr.avg_defect_ppm > 500
ORDER BY sr.avg_defect_ppm DESC;
```

---

## Q7 — 锂价上涨影响哪些 BOM 产品

**业务问题**：识别锂（RAW-LI）用量最大的成品，估算锂价上涨 20% 对标准材料成本的影响。

**口径**：
- 锂价涨幅影响 = 锂用量(kg) × 锂价涨幅(USD/kg) × BOM 层级放大系数
- 锂含量系数 = component_material_usage.usage_kg_per_unit（已考虑 BOM 层级）

```sql
-- 7a. 近期锂价走势
SELECT
    price_date,
    ROUND(price_usd_per_kg::NUMERIC, 3)            AS lithium_price_usd_per_kg,
    ROUND(price_usd_per_kg / FIRST_VALUE(price_usd_per_kg) OVER (
        ORDER BY price_date
    ) - 1, 4)                                      AS cumulative_change_pct
FROM fact_raw_material_price_daily
WHERE material_id = (
    SELECT material_id FROM dim_raw_material WHERE material_code = 'RAW-LI'
)
  AND price_date >= CURRENT_DATE - INTERVAL '90 days'
ORDER BY price_date DESC
LIMIT 30;

-- 7b. 各成品的锂含量及涨价 20% 后的成本影响
WITH lithium_usage AS (
    SELECT
        cmu.component_id,
        comp.component_code,
        comp.component_name,
        cat.category_name,
        cmu.usage_kg_per_unit,
        cmu.is_critical_material
    FROM component_material_usage cmu
    JOIN dim_component         comp ON comp.component_id = cmu.component_id
    JOIN dim_component_category cat ON cat.category_id = comp.category_id
    WHERE cmu.material_id = (
        SELECT material_id FROM dim_raw_material WHERE material_code = 'RAW-LI'
    )
),
latest_li_price AS (
    SELECT price_usd_per_kg AS current_price
    FROM fact_raw_material_price_daily
    WHERE material_id = (
        SELECT material_id FROM dim_raw_material WHERE material_code = 'RAW-LI'
    )
    ORDER BY price_date DESC
    LIMIT 1
),
recent_sales AS (
    SELECT
        soi.component_id,
        SUM(soi.qty_ordered)                       AS qty_sold_ytd,
        SUM(soi.net_line_amount)                   AS revenue_ytd
    FROM fact_sales_order_item soi
    JOIN fact_sales_order so ON so.so_id = soi.so_id
    WHERE so.order_date >= DATE_TRUNC('year', CURRENT_DATE)
    GROUP BY soi.component_id
)
SELECT
    lu.component_code,
    lu.component_name,
    lu.category_name,
    lu.is_critical_material,
    ROUND(lu.usage_kg_per_unit::NUMERIC, 3)        AS li_kg_per_unit,
    ROUND(lp.current_price::NUMERIC, 3)            AS current_li_price_usd_per_kg,
    ROUND(lu.usage_kg_per_unit * lp.current_price::NUMERIC, 3)
                                                   AS current_li_cost_per_unit,
    ROUND(lu.usage_kg_per_unit * lp.current_price * 0.20::NUMERIC, 3)
                                                   AS extra_cost_per_unit_if_20pct_rise,
    COALESCE(rs.qty_sold_ytd, 0)                   AS qty_sold_ytd,
    ROUND(
        lu.usage_kg_per_unit * lp.current_price * 0.20
        * COALESCE(rs.qty_sold_ytd, 0)::NUMERIC, 0
    )                                              AS total_extra_cost_ytd_usd,
    ROUND(
        lu.usage_kg_per_unit * lp.current_price * 0.20
        * COALESCE(rs.qty_sold_ytd, 0)
        / NULLIF(rs.revenue_ytd, 0) * 100::NUMERIC, 2
    )                                              AS pct_of_revenue
FROM lithium_usage lu
CROSS JOIN latest_li_price lp
LEFT JOIN recent_sales rs ON rs.component_id = lu.component_id
ORDER BY total_extra_cost_ytd_usd DESC NULLS LAST;
```

---

## Q8 — 哪些国家应收账款融资成本最高

**业务问题**：各目标市场的应收账款逾期情况和融资成本，哪些国家客户付款最慢？

**口径**：Receivable Financing Cost = outstanding_amount_usd × annual_interest_rate × days_outstanding / 360

```sql
SELECT
    cnt.country_name,
    cnt.country_code,
    COUNT(DISTINCT ra.customer_id)                              AS customer_count,
    ROUND(SUM(ra.total_outstanding_usd)::NUMERIC, 0)           AS total_ar_usd,
    ROUND(SUM(ra.bucket_0_30_usd)::NUMERIC, 0)                 AS current_0_30d,
    ROUND(SUM(ra.bucket_31_60_usd)::NUMERIC, 0)                AS overdue_31_60d,
    ROUND(SUM(ra.bucket_61_90_usd)::NUMERIC, 0)                AS overdue_61_90d,
    ROUND(SUM(ra.bucket_over_90_usd)::NUMERIC, 0)              AS overdue_over_90d,
    -- 逾期率
    ROUND(
        (SUM(ra.bucket_31_60_usd + ra.bucket_61_90_usd + ra.bucket_over_90_usd))
        / NULLIF(SUM(ra.total_outstanding_usd), 0) * 100::NUMERIC, 1
    )                                                           AS overdue_rate_pct,
    -- 加权平均账期
    ROUND(
        SUM(ra.weighted_avg_days_outstanding * ra.total_outstanding_usd)
        / NULLIF(SUM(ra.total_outstanding_usd), 0)::NUMERIC, 1
    )                                                           AS wtd_avg_days_outstanding,
    ROUND(SUM(ra.financing_cost_usd)::NUMERIC, 0)              AS total_financing_cost_usd,
    -- 融资成本占 AR 比例（年化）
    ROUND(
        SUM(ra.financing_cost_usd)
        / NULLIF(SUM(ra.total_outstanding_usd), 0)
        * (360.0 / 30) * 100::NUMERIC, 2
    )                                                           AS annualized_financing_cost_pct
FROM fact_receivable_aging ra
JOIN dim_customer c  ON c.customer_id = ra.customer_id
JOIN dim_country  cnt ON cnt.country_id = c.country_id
WHERE ra.snapshot_date = (
    SELECT MAX(snapshot_date) FROM fact_receivable_aging
)
GROUP BY cnt.country_name, cnt.country_code
ORDER BY total_financing_cost_usd DESC;
```

---

## Q9 — 哪些产品在不同国家存在价格倒挂

**业务问题**：同一零部件，A 国标价低于 B 国，但运费+关税后 A 国客户实际到手价反而更高（价格倒挂）。

**口径**：价格倒挂 = 低价国含税到岸价 > 高价国含税到岸价

```sql
-- 9a. 各国标价清单对比
WITH price_matrix AS (
    SELECT
        comp.component_code,
        comp.component_name,
        cnt.country_name,
        pl.list_price_usd,
        pl.currency_code,
        RANK() OVER (
            PARTITION BY pl.component_id
            ORDER BY pl.list_price_usd
        )                                                       AS price_rank_asc,
        MAX(pl.list_price_usd) OVER (
            PARTITION BY pl.component_id
        ) - MIN(pl.list_price_usd) OVER (
            PARTITION BY pl.component_id
        )                                                       AS price_spread_usd,
        MIN(pl.list_price_usd) OVER (
            PARTITION BY pl.component_id
        )                                                       AS min_price,
        MAX(pl.list_price_usd) OVER (
            PARTITION BY pl.component_id
        )                                                       AS max_price
    FROM fact_country_price_list pl
    JOIN dim_component comp ON comp.component_id = pl.component_id
    JOIN dim_country   cnt  ON cnt.country_id = pl.country_id
    WHERE pl.effective_date <= CURRENT_DATE
      AND (pl.expiry_date IS NULL OR pl.expiry_date >= CURRENT_DATE)
)
SELECT
    component_code,
    component_name,
    country_name,
    ROUND(list_price_usd::NUMERIC, 2)                          AS list_price_usd,
    price_rank_asc,
    ROUND(price_spread_usd::NUMERIC, 2)                        AS price_spread_usd,
    ROUND((price_spread_usd / NULLIF(min_price, 0) * 100)::NUMERIC, 1)
                                                               AS spread_pct_of_min_price
FROM price_matrix
ORDER BY price_spread_usd DESC, component_code, price_rank_asc;

-- 9b. 含关税的到岸价倒挂检测
WITH landed_cost AS (
    SELECT
        pl.component_id,
        comp.component_code,
        comp.component_name,
        cnt_src.country_name                                    AS manufacturing_country,
        cnt_dst.country_name                                    AS sales_country,
        pl.list_price_usd,
        tl.freight_cost_usd_per_unit,
        COALESCE(tr.tariff_pct, 0)                             AS tariff_pct,
        pl.list_price_usd * (1 + COALESCE(tr.tariff_pct, 0))
            + COALESCE(tl.freight_cost_usd_per_unit, 0)        AS landed_cost_usd
    FROM fact_country_price_list pl
    JOIN dim_component comp ON comp.component_id = pl.component_id
    JOIN dim_country   cnt_dst ON cnt_dst.country_id = pl.country_id
    -- 假设主要从中国生产工厂发货
    CROSS JOIN (
        SELECT country_id, country_code FROM dim_country WHERE country_code = 'CN'
    ) cnt_src
    LEFT JOIN fact_tariff_rate tr ON tr.from_country_id = cnt_src.country_id
        AND tr.to_country_id = cnt_dst.country_id
        AND CURRENT_DATE BETWEEN tr.effective_date AND COALESCE(tr.expiry_date, '2099-12-31')
    LEFT JOIN fact_trade_lane tl ON tl.from_country_id = cnt_src.country_id
        AND tl.to_country_id = cnt_dst.country_id
    WHERE pl.effective_date <= CURRENT_DATE
      AND (pl.expiry_date IS NULL OR pl.expiry_date >= CURRENT_DATE)
)
SELECT
    component_code,
    component_name,
    sales_country,
    ROUND(list_price_usd::NUMERIC, 2)                          AS list_price_usd,
    ROUND(tariff_pct * 100::NUMERIC, 1)                        AS tariff_pct,
    ROUND(freight_cost_usd_per_unit::NUMERIC, 2)               AS freight_per_unit,
    ROUND(landed_cost_usd::NUMERIC, 2)                         AS landed_cost_usd,
    -- 与所有目标国最低到岸价比较
    MIN(landed_cost_usd) OVER (PARTITION BY component_id)      AS min_landed_cost,
    ROUND((landed_cost_usd
           - MIN(landed_cost_usd) OVER (PARTITION BY component_id))::NUMERIC, 2)
                                                               AS premium_vs_cheapest_dest
FROM landed_cost
ORDER BY component_code, landed_cost_usd;
```

---

## Q10 — 本地生产 vs 跨国出口调整后毛利对比

**业务问题**：对于同一款零部件，同一工厂的本地销售（工厂所在国）和出口销售，哪种模式调整后毛利更高？

**口径**：本地 = ship_to_country = factory_country；跨国 = ship_to_country ≠ factory_country

```sql
WITH order_classification AS (
    SELECT
        soi.component_id,
        comp.component_code,
        comp.component_name,
        CASE
            WHEN f_cnt.country_id = so.ship_to_country_id THEN 'Local'
            ELSE 'Export'
        END                                                     AS sales_mode,
        so.ship_to_country_id,
        dst_cnt.country_name                                    AS dest_country,
        soi.qty_ordered,
        soi.net_line_amount,
        soi.std_material_cost_total + soi.manufacturing_cost_total
                                                                AS prod_cost,
        COALESCE(so.total_freight_cost, 0)
            * soi.net_line_amount / NULLIF(so.total_net_revenue, 0)
                                                                AS alloc_freight,
        COALESCE(so.total_tariff_cost, 0)
            * soi.net_line_amount / NULLIF(so.total_net_revenue, 0)
                                                                AS alloc_tariff
    FROM fact_sales_order_item soi
    JOIN fact_sales_order  so       ON so.so_id = soi.so_id
    JOIN dim_component     comp     ON comp.component_id = soi.component_id
    JOIN dim_factory       f        ON f.factory_id = so.factory_id
    JOIN dim_country       f_cnt    ON f_cnt.country_id = f.country_id
    JOIN dim_country       dst_cnt  ON dst_cnt.country_id = so.ship_to_country_id
    WHERE so.order_status NOT IN ('cancelled')
)
SELECT
    component_code,
    component_name,
    sales_mode,
    COUNT(*)                                                    AS order_line_count,
    ROUND(SUM(qty_ordered)::NUMERIC, 0)                        AS total_qty,
    ROUND(SUM(net_line_amount)::NUMERIC, 0)                    AS net_revenue_usd,
    ROUND(SUM(prod_cost)::NUMERIC, 0)                          AS prod_cost_usd,
    ROUND(SUM(alloc_freight)::NUMERIC, 0)                      AS freight_usd,
    ROUND(SUM(alloc_tariff)::NUMERIC, 0)                       AS tariff_usd,
    ROUND((SUM(net_line_amount) - SUM(prod_cost)
           - SUM(alloc_freight) - SUM(alloc_tariff))::NUMERIC, 0)
                                                                AS adj_gross_margin_usd,
    ROUND(
        (SUM(net_line_amount) - SUM(prod_cost) - SUM(alloc_freight) - SUM(alloc_tariff))
        / NULLIF(SUM(net_line_amount), 0) * 100::NUMERIC, 2
    )                                                           AS adj_gm_rate_pct,
    -- 人均单位毛利（便于 Local vs Export 对比）
    ROUND(
        (SUM(net_line_amount) - SUM(prod_cost) - SUM(alloc_freight) - SUM(alloc_tariff))
        / NULLIF(SUM(qty_ordered), 0)::NUMERIC, 2
    )                                                           AS adj_gm_per_unit_usd
FROM order_classification
GROUP BY component_code, component_name, sales_mode
ORDER BY component_code, sales_mode;
```

**带国家维度的完整矩阵**

```sql
-- Local vs Export 按目标国展开
SELECT
    component_code,
    component_name,
    sales_mode,
    dest_country,
    ROUND(SUM(net_line_amount)::NUMERIC, 0)                    AS revenue_usd,
    ROUND(
        (SUM(net_line_amount) - SUM(prod_cost) - SUM(alloc_freight) - SUM(alloc_tariff))
        / NULLIF(SUM(net_line_amount), 0) * 100::NUMERIC, 2
    )                                                           AS adj_gm_rate_pct
FROM (
    SELECT
        comp.component_code,
        comp.component_name,
        CASE WHEN f_cnt.country_id = so.ship_to_country_id THEN 'Local' ELSE 'Export' END AS sales_mode,
        dst_cnt.country_name                                    AS dest_country,
        soi.qty_ordered,
        soi.net_line_amount,
        soi.std_material_cost_total + soi.manufacturing_cost_total AS prod_cost,
        COALESCE(so.total_freight_cost,0) * soi.net_line_amount / NULLIF(so.total_net_revenue,0) AS alloc_freight,
        COALESCE(so.total_tariff_cost,0)  * soi.net_line_amount / NULLIF(so.total_net_revenue,0) AS alloc_tariff
    FROM fact_sales_order_item soi
    JOIN fact_sales_order so      ON so.so_id = soi.so_id
    JOIN dim_component comp       ON comp.component_id = soi.component_id
    JOIN dim_factory   f          ON f.factory_id = so.factory_id
    JOIN dim_country   f_cnt      ON f_cnt.country_id = f.country_id
    JOIN dim_country   dst_cnt    ON dst_cnt.country_id = so.ship_to_country_id
    WHERE so.order_status NOT IN ('cancelled')
) t
GROUP BY component_code, component_name, sales_mode, dest_country
ORDER BY component_code, adj_gm_rate_pct DESC NULLS LAST;
```

---

## 附录：快速验证 SQL

启动数据库后，可运行以下查询快速确认数据加载情况：

```sql
-- 各表行数汇总
SELECT
    schemaname,
    relname                                        AS table_name,
    n_live_tup                                     AS estimated_row_count
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC;

-- 重要事实表时间范围
SELECT 'fact_sales_order'         AS tbl, MIN(order_date)::TEXT AS min_date, MAX(order_date)::TEXT AS max_date, COUNT(*) AS rows FROM fact_sales_order
UNION ALL
SELECT 'fact_production_order',   MIN(planned_start_date)::TEXT, MAX(planned_end_date)::TEXT, COUNT(*) FROM fact_production_order
UNION ALL
SELECT 'fact_exchange_rate_daily', MIN(rate_date)::TEXT, MAX(rate_date)::TEXT, COUNT(*) FROM fact_exchange_rate_daily
UNION ALL
SELECT 'fact_raw_material_price_daily', MIN(price_date)::TEXT, MAX(price_date)::TEXT, COUNT(*) FROM fact_raw_material_price_daily
UNION ALL
SELECT 'fact_inventory_snapshot', MIN(snapshot_date)::TEXT, MAX(snapshot_date)::TEXT, COUNT(*) FROM fact_inventory_snapshot;

-- 外键完整性抽查
SELECT COUNT(*) AS orphan_soi FROM fact_sales_order_item soi
LEFT JOIN fact_sales_order so ON so.so_id = soi.so_id
WHERE so.so_id IS NULL;
```

---

*最后更新：2025-03 | 数据库版本：PostgreSQL 16 | 项目：ev-parts-lakehouse*
