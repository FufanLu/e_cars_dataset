# EV Parts Lakehouse — Entity-Relationship Diagram

```mermaid
erDiagram
%% ============================================================
%% EV Parts Lakehouse — 54 tables, 93 foreign keys
%% 10 schemas: geo, product, production, procurement,
%%              sales, inventory, finance, logistics, esg, aftersales
%% ============================================================

%% ═══════════════════════════════════════════════════════════════
%% GEO — 基础地理层 (3 tables)
%% ═══════════════════════════════════════════════════════════════
dim_region {
    int region_id PK "大区ID"
    varchar region_code "大区代码"
    varchar region_name "大区名称"
}
dim_country {
    int country_id PK "国家ID"
    char country_code "国家代码"
    varchar country_name "国家名称"
    int region_id FK "大区"
    int currency_id FK "本币"
    numeric vat_rate "增值税率"
    numeric corporate_tax_rate "企业所得税率"
    bool is_eu_member "欧盟成员"
}
dim_currency {
    int currency_id PK "币种ID"
    varchar currency_code "币种代码"
    varchar currency_name "币种名称"
}
dim_region ||--o{ dim_country : ""
dim_currency ||--o{ dim_country : ""

%% ═══════════════════════════════════════════════════════════════
%% PRODUCT — 产品/BOM/原材料 (7 tables)
%% ═══════════════════════════════════════════════════════════════
dim_component_category {
    int category_id PK "品类ID"
    varchar category_code UK "品类代码"
    varchar category_name "品类名称"
    int parent_id FK "父品类"
}
dim_component {
    int component_id PK "零部件ID"
    varchar component_code UK "代码"
    varchar component_name "名称"
    int category_id FK "品类"
    numeric standard_cost_usd "标准成本"
    numeric list_price_usd "目录价"
    bool is_finished_good "是否成品"
    varchar lifecycle_stage "生命周期"
    varchar hs_code "HS编码"
}
bom_header {
    int bom_id PK "BOM版本ID"
    varchar bom_code UK "BOM代码"
    int parent_component_id FK "父零部件"
    varchar bom_version "版本号"
    bool is_current "是否当前"
}
bom_item {
    int bom_item_id PK "BOM明细ID"
    int bom_id FK "BOM版本"
    int child_component_id FK "子零部件"
    numeric qty_per_parent "每父件用量"
    numeric scrap_rate "废品率"
}
dim_raw_material {
    int material_id PK "原材料ID"
    varchar material_code UK "代码"
    varchar material_name "名称"
    varchar commodity_ticker "大宗商品代码"
    int primary_source_country_id FK "主产地"
}
component_material_usage {
    int usage_id PK "用量ID"
    int component_id FK "零部件"
    int material_id FK "原材料"
    numeric usage_kg_per_unit "每件用量kg"
}
fact_raw_material_price_daily {
    bigint price_id PK "价格ID"
    int material_id FK "原材料"
    date price_date "日期"
    numeric price_usd_per_mt "价格USD吨"
}
dim_component_category ||--o{ dim_component_category : "parent"
dim_component_category ||--o{ dim_component : ""
dim_component ||--o{ bom_header : ""
bom_header ||--o{ bom_item : ""
dim_component ||--o{ bom_item : ""
dim_component ||--o{ component_material_usage : ""
dim_raw_material ||--o{ component_material_usage : ""
dim_country ||--o{ dim_raw_material : ""
dim_raw_material ||--o{ fact_raw_material_price_daily : ""

%% ═══════════════════════════════════════════════════════════════
%% PRODUCTION — 工厂/生产线/生产订单/质量 (5 tables)
%% ═══════════════════════════════════════════════════════════════
dim_factory {
    int factory_id PK "工厂ID"
    varchar factory_code "工厂代码"
    varchar factory_name "工厂名称"
    int country_id FK "所在国"
    varchar city "城市"
    numeric annual_capacity "年产能"
    int headcount "员工数"
}
dim_production_line {
    int line_id PK "产线ID"
    varchar line_code "产线代码"
    varchar line_name "产线名称"
    int factory_id FK "工厂"
    int primary_category_id FK "主要品类"
}
fact_production_order {
    bigint prod_order_id PK "生产订单ID"
    varchar prod_order_no "生产单号"
    int component_id FK "零部件"
    int line_id FK "产线"
    int factory_id FK "工厂"
    numeric planned_qty "计划产量"
    numeric actual_qty "实际产量"
    numeric scrap_qty "报废量"
    varchar status "状态"
    numeric std_material_cost_usd "标准材料成本"
    numeric actual_material_cost_usd "实际材料成本"
    numeric std_labor_cost_usd "标准人工成本"
    numeric actual_labor_cost_usd "实际人工成本"
    numeric std_overhead_cost_usd "标准制造费用"
    numeric actual_overhead_cost_usd "实际制造费用"
}
fact_quality_inspection {
    bigint inspection_id PK "检验ID"
    bigint prod_order_id FK "生产订单"
    date inspection_date "检验日"
    numeric inspected_qty "检验量"
    numeric passed_qty "合格量"
    numeric failed_qty "不合格量"
    numeric rework_qty "返工量"
    numeric scrap_qty "报废量"
    varchar defect_code "缺陷代码"
}
fact_scrap_event {
    bigint scrap_id PK "报废事件ID"
    bigint prod_order_id FK "生产订单"
    int component_id FK "零部件"
    date scrap_date "报废日"
    numeric scrap_qty "报废量"
    varchar scrap_reason "报废原因"
}
dim_country ||--o{ dim_factory : ""
dim_factory ||--o{ dim_production_line : ""
dim_component_category ||--o{ dim_production_line : ""
dim_factory ||--o{ fact_production_order : ""
dim_production_line ||--o{ fact_production_order : ""
dim_component ||--o{ fact_production_order : ""
fact_production_order ||--o{ fact_quality_inspection : ""
fact_production_order ||--o{ fact_scrap_event : ""

%% ═══════════════════════════════════════════════════════════════
%% PROCUREMENT — 供应商/采购 (5 tables)
%% ═══════════════════════════════════════════════════════════════
dim_supplier {
    int supplier_id PK "供应商ID"
    varchar supplier_code "代码"
    varchar supplier_name "名称"
    int country_id FK "所在国"
    smallint tier "层级"
    int category_id FK "供应品类"
    bool is_strategic "战略供应商"
    varchar risk_rating "风险评级"
}
fact_purchase_order {
    bigint po_id PK "采购订单ID"
    varchar po_number "采购单号"
    int supplier_id FK "供应商"
    int factory_id FK "收货工厂"
    date po_date "采购日"
    numeric total_amount "金额"
    varchar status "状态"
}
fact_purchase_order_item {
    bigint po_item_id PK "采购明细ID"
    bigint po_id FK "采购订单"
    int component_id FK "零部件"
    numeric ordered_qty "订购量"
    numeric unit_price "单价"
    numeric line_amount "行金额"
}
fact_supplier_delivery {
    bigint delivery_id PK "交货ID"
    bigint po_id FK "采购订单"
    int supplier_id FK "供应商"
    date promised_date "承诺日"
    date actual_date "实际日"
    bool is_on_time "是否准时"
}
fact_supplier_quality {
    bigint sq_id PK "来料质量ID"
    int supplier_id FK "供应商"
    int component_id FK "零部件"
    date inspection_date "检验日"
    numeric defect_ppm "缺陷PPM"
}
dim_country ||--o{ dim_supplier : ""
dim_component_category ||--o{ dim_supplier : ""
dim_supplier ||--o{ fact_purchase_order : ""
dim_factory ||--o{ fact_purchase_order : ""
fact_purchase_order ||--o{ fact_purchase_order_item : ""
dim_component ||--o{ fact_purchase_order_item : ""
fact_purchase_order ||--o{ fact_supplier_delivery : ""
dim_supplier ||--o{ fact_supplier_delivery : ""
dim_supplier ||--o{ fact_supplier_quality : ""
dim_component ||--o{ fact_supplier_quality : ""

%% ═══════════════════════════════════════════════════════════════
%% SALES — 客户/渠道/销售订单/定价 (8 tables)
%% ═══════════════════════════════════════════════════════════════
dim_customer {
    int customer_id PK "客户ID"
    varchar customer_code "代码"
    varchar customer_name "名称"
    int country_id FK "所在国"
    varchar customer_type "客户类型"
    numeric credit_limit_usd "信用额度"
    int payment_terms_days "账期天"
    bool is_strategic "战略客户"
}
dim_sales_channel {
    int channel_id PK "渠道ID"
    varchar channel_code "代码"
    varchar channel_name "名称"
}
fact_sales_order {
    bigint so_id PK "销售订单ID"
    varchar so_number "订单号"
    int customer_id FK "客户"
    int channel_id FK "渠道"
    date order_date "下单日"
    int ship_from_factory_id FK "发货工厂"
    int ship_to_country_id FK "目的国"
    numeric total_gross_revenue "总收入"
    numeric total_discount "折扣"
    numeric total_net_revenue "净收入"
    numeric total_freight_cost "运费"
    numeric total_tariff_cost "关税"
    varchar status "状态"
    varchar incoterm "贸易术语"
}
fact_sales_order_item {
    bigint so_item_id PK "销售明细ID"
    bigint so_id FK "销售订单"
    int component_id FK "零部件"
    numeric qty "数量"
    numeric net_line_amount "净行金额"
    numeric std_material_cost "材料成本"
    numeric manufacturing_cost "制造成本"
}
fact_country_price_list {
    bigint price_list_id PK "国别定价ID"
    int country_id FK "国家"
    int component_id FK "零部件"
    numeric list_price "目录价"
}
fact_price_agreement {
    bigint agreement_id PK "价格协议ID"
    int customer_id FK "客户"
    int component_id FK "零部件"
    numeric agreed_price "协议价"
    numeric discount_pct "折扣%"
}
fact_rebate {
    bigint rebate_id PK "返利ID"
    int customer_id FK "客户"
    int component_id FK "零部件"
    numeric rebate_rate "返利率"
    numeric rebate_amount_usd "返利金额"
}
fact_volume_discount {
    bigint vd_id PK "数量折扣ID"
    int customer_id FK "客户"
    int component_id FK "零部件"
    int tier_from_qty "起订量"
    numeric discount_pct "折扣%"
}
dim_country ||--o{ dim_customer : ""
dim_customer ||--o{ fact_sales_order : ""
dim_sales_channel ||--o{ fact_sales_order : ""
dim_factory ||--o{ fact_sales_order : "ship_from"
dim_country ||--o{ fact_sales_order : "ship_to"
fact_sales_order ||--o{ fact_sales_order_item : ""
dim_component ||--o{ fact_sales_order_item : ""
dim_country ||--o{ fact_country_price_list : ""
dim_component ||--o{ fact_country_price_list : ""
dim_customer ||--o{ fact_price_agreement : ""
dim_component ||--o{ fact_price_agreement : ""
dim_customer ||--o{ fact_rebate : ""
dim_component ||--o{ fact_rebate : ""
dim_customer ||--o{ fact_volume_discount : ""
dim_component ||--o{ fact_volume_discount : ""

%% ═══════════════════════════════════════════════════════════════
%% INVENTORY — 仓库/库存 (4 tables)
%% ═══════════════════════════════════════════════════════════════
dim_warehouse {
    int warehouse_id PK "仓库ID"
    varchar warehouse_code "代码"
    varchar warehouse_name "名称"
    int factory_id FK "所属工厂"
    int country_id FK "所在国"
}
fact_inventory_snapshot {
    bigint snapshot_id PK "快照ID"
    date snapshot_date "快照日"
    int warehouse_id FK "仓库"
    int component_id FK "零部件"
    numeric qty_on_hand "在库量"
    numeric qty_available "可用量"
    numeric inventory_value_usd "库存价值"
}
fact_inventory_movement {
    bigint movement_id PK "移动ID"
    int component_id FK "零部件"
    int warehouse_id FK "仓库"
    date movement_date "移动日"
    varchar movement_type "移动类型"
    numeric qty "数量"
}
fact_stockout_event {
    bigint stockout_id PK "断货ID"
    int component_id FK "零部件"
    int warehouse_id FK "仓库"
    date event_date "断货日"
    int stockout_days "断货天"
    varchar root_cause "根因"
}
dim_factory ||--o{ dim_warehouse : ""
dim_country ||--o{ dim_warehouse : ""
dim_warehouse ||--o{ fact_inventory_snapshot : ""
dim_component ||--o{ fact_inventory_snapshot : ""
dim_component ||--o{ fact_inventory_movement : ""
dim_warehouse ||--o{ fact_inventory_movement : ""
dim_component ||--o{ fact_stockout_event : ""
dim_warehouse ||--o{ fact_stockout_event : ""

%% ═══════════════════════════════════════════════════════════════
%% FINANCE — 汇率/利率/应收/持有成本 (4 tables)
%% ═══════════════════════════════════════════════════════════════
fact_exchange_rate_daily {
    bigint fx_id PK "汇率ID"
    int from_currency_id FK "从币种"
    int to_currency_id FK "到币种"
    date rate_date "日期"
    numeric rate "汇率"
}
fact_interest_rate_daily {
    bigint ir_id PK "利率ID"
    int country_id FK "国家"
    date rate_date "日期"
    numeric rate_pct "利率%"
}
fact_receivable_aging {
    bigint aging_id PK "应收账龄ID"
    int customer_id FK "客户"
    int country_id FK "国家"
    int currency_id FK "币种"
    numeric total_outstanding "应收总额"
    numeric financing_cost_usd "融资成本"
}
fact_inventory_carrying_cost {
    bigint icc_id PK "持有成本ID"
    int warehouse_id FK "仓库"
    int component_id FK "零部件"
    numeric carrying_cost_usd "持有成本"
}
dim_currency ||--o{ fact_exchange_rate_daily : "from"
dim_currency ||--o{ fact_exchange_rate_daily : "to"
dim_country ||--o{ fact_interest_rate_daily : ""
dim_customer ||--o{ fact_receivable_aging : ""
dim_country ||--o{ fact_receivable_aging : ""
dim_currency ||--o{ fact_receivable_aging : ""
dim_warehouse ||--o{ fact_inventory_carrying_cost : ""
dim_component ||--o{ fact_inventory_carrying_cost : ""

%% ═══════════════════════════════════════════════════════════════
%% LOGISTICS — 关税/航线/运费/装运 (4 tables)
%% ═══════════════════════════════════════════════════════════════
fact_tariff_rate {
    bigint tariff_id PK "关税ID"
    varchar hs_code "HS编码"
    int from_country_id FK "从国"
    int to_country_id FK "到国"
    numeric tariff_rate_pct "关税%"
}
fact_trade_lane {
    bigint lane_id PK "航线ID"
    varchar lane_code "航线代码"
    int from_country_id FK "从国"
    int to_country_id FK "到国"
    varchar transport_mode "运输方式"
    int transit_days "运输天"
}
fact_freight_cost {
    bigint freight_id PK "运费ID"
    bigint so_id FK "销售订单"
    bigint lane_id FK "航线"
    numeric freight_amount_usd "运费金额"
}
fact_shipping_order {
    bigint shipping_id PK "装运ID"
    varchar shipping_no "装运号"
    bigint so_id FK "销售订单"
    bigint lane_id FK "航线"
    date ship_date "发运日"
    varchar status "状态"
}
dim_country ||--o{ fact_tariff_rate : "from"
dim_country ||--o{ fact_tariff_rate : "to"
dim_country ||--o{ fact_trade_lane : "from"
dim_country ||--o{ fact_trade_lane : "to"
fact_sales_order ||--o{ fact_freight_cost : ""
fact_trade_lane ||--o{ fact_freight_cost : ""
fact_sales_order ||--o{ fact_shipping_order : ""
fact_trade_lane ||--o{ fact_shipping_order : ""

%% ═══════════════════════════════════════════════════════════════
%% ESG — 碳排放/能源/碳价/碳税/碳信用 (8 tables)
%% ═══════════════════════════════════════════════════════════════
dim_emission_scope {
    int scope_id PK "范围ID"
    varchar scope_code "范围代码"
    varchar scope_name "范围名称"
}
fact_carbon_tax {
    bigint ct_id PK "碳税ID"
    int factory_id FK "工厂"
    date period_month "月份"
    int country_id FK "国家"
    numeric total_emission_tco2e "总排放吨"
    numeric free_allowance_tco2e "免费配额"
    numeric taxable_emission_tco2e "应税排放"
    numeric carbon_price_usd_per_tco2e "碳价"
    numeric carbon_tax_usd "碳税金额"
}
fact_carbon_price {
    bigint cp_id PK "碳价ID"
    int country_id FK "国家"
    date price_date "日期"
    numeric price_usd_per_tco2e "碳价"
}
fact_carbon_credit {
    bigint credit_id PK "碳信用ID"
    int factory_id FK "工厂"
    numeric qty_tco2e "数量"
    numeric total_cost_usd "总成本"
}
fact_component_carbon_footprint {
    bigint footprint_id PK "碳足迹ID"
    int component_id FK "零部件"
    int factory_id FK "工厂"
    numeric scope1_kgco2e_per_unit "范围1"
    numeric scope2_kgco2e_per_unit "范围2"
    numeric scope3_kgco2e_per_unit "范围3"
    numeric total_kgco2e_per_unit "总碳足迹"
}
fact_factory_energy_consumption {
    bigint energy_id PK "能耗ID"
    int factory_id FK "工厂"
    int scope_id FK "范围"
    date period_month "月份"
    numeric consumption_kwh "耗电kWh"
    numeric total_emission_tco2e "碳排放吨"
}
fact_shipping_emission {
    bigint se_id PK "运输排放ID"
    bigint shipping_id FK "装运单"
    numeric total_emission_kgco2e "排放kg"
}
fact_supplier_esg_score {
    bigint esg_id PK "ESG评分ID"
    int supplier_id FK "供应商"
    int assess_year "评估年"
    numeric env_score "环境分"
    numeric social_score "社会分"
    numeric governance_score "治理分"
    numeric overall_score "总分"
}
dim_factory ||--o{ fact_carbon_tax : ""
dim_country ||--o{ fact_carbon_tax : ""
dim_country ||--o{ fact_carbon_price : ""
dim_factory ||--o{ fact_carbon_credit : ""
dim_component ||--o{ fact_component_carbon_footprint : ""
dim_factory ||--o{ fact_component_carbon_footprint : ""
dim_factory ||--o{ fact_factory_energy_consumption : ""
dim_emission_scope ||--o{ fact_factory_energy_consumption : ""
fact_shipping_order ||--o{ fact_shipping_emission : ""
dim_supplier ||--o{ fact_supplier_esg_score : ""

%% ═══════════════════════════════════════════════════════════════
%% AFTERSALES — 故障/保修/现场失效 (3 tables)
%% ═══════════════════════════════════════════════════════════════
dim_failure_mode {
    int failure_id PK "故障ID"
    varchar failure_code "故障代码"
    varchar failure_name "故障名称"
    int component_category_id FK "品类"
    varchar severity "严重度"
}
fact_warranty_claim {
    bigint claim_id PK "索赔ID"
    varchar claim_no "索赔号"
    bigint so_item_id FK "销售明细"
    int customer_id FK "客户"
    int component_id FK "零部件"
    int failure_id FK "故障模式"
    date claim_date "索赔日"
    numeric claim_amount_usd "索赔金额"
    varchar status "状态"
}
fact_field_failure {
    bigint ff_id PK "现场失效ID"
    int component_id FK "零部件"
    int failure_id FK "故障模式"
    int country_id FK "国家"
    date failure_month "失效月"
    int failure_count "失效数"
    numeric failure_rate_ppm "失效率PPM"
}
dim_component_category ||--o{ dim_failure_mode : ""
fact_sales_order_item ||--o{ fact_warranty_claim : ""
dim_customer ||--o{ fact_warranty_claim : ""
dim_component ||--o{ fact_warranty_claim : ""
dim_failure_mode ||--o{ fact_warranty_claim : ""
dim_component ||--o{ fact_field_failure : ""
dim_failure_mode ||--o{ fact_field_failure : ""
dim_country ||--o{ fact_field_failure : ""

%% ═══════════════════════════════════════════════════════════════
%% PUBLIC VIEWS — 跨表视图 (3 views)
%% ═══════════════════════════════════════════════════════════════
v_net_profit {
    bigint so_item_id "订单行ID"
    varchar so_number "订单号"
    date order_date "订单日期"
    varchar customer_name "客户"
    varchar ship_to_country "目的国"
    varchar component_name "零部件"
    numeric qty "数量"
    numeric net_revenue "净收入"
    numeric material_cost "材料成本"
    numeric manufacturing_cost "制造成本"
    numeric gross_margin "毛利"
    numeric freight_cost "运费"
    numeric tariff_cost "关税"
    numeric carbon_cost "碳成本"
    numeric carbon_tax "碳税"
    numeric inventory_carrying_cost "库存持有成本"
    numeric net_profit "净利润"
    numeric net_profit_margin_pct "净利率%"
}
```
