-- =============================================================================
-- EV Parts Lakehouse - Schema DDL
-- PostgreSQL 16
-- Database: ev_parts
-- =============================================================================

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

-- -----------------------------------------------------------------------------
-- EXTENSIONS
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- =============================================================================
-- DOMAIN I: 国家 / 币种 / 地区
-- =============================================================================

CREATE TABLE dim_region (
    region_id     SERIAL PRIMARY KEY,
    region_code   VARCHAR(10)  NOT NULL UNIQUE,
    region_name   VARCHAR(100) NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_region IS '销售/生产大区：APAC、EMEA、AMER 等';
COMMENT ON COLUMN dim_region.region_code IS '内部大区代码，如 APAC';

CREATE TABLE dim_currency (
    currency_id     SERIAL PRIMARY KEY,
    currency_code   CHAR(3)      NOT NULL UNIQUE,  -- ISO 4217
    currency_name   VARCHAR(80)  NOT NULL,
    symbol          VARCHAR(5),
    decimal_places  SMALLINT     NOT NULL DEFAULT 2,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_currency IS 'ISO 4217 货币主数据';
COMMENT ON COLUMN dim_currency.currency_code IS 'ISO 4217 三字母代码，如 CNY';

CREATE TABLE dim_country (
    country_id      SERIAL PRIMARY KEY,
    country_code    CHAR(2)       NOT NULL UNIQUE,  -- ISO 3166-1 alpha-2
    country_name    VARCHAR(100)  NOT NULL,
    region_id       INT           NOT NULL REFERENCES dim_region(region_id),
    currency_id     INT           NOT NULL REFERENCES dim_currency(currency_id),
    vat_rate        NUMERIC(6,4),   -- 增值税率 e.g. 0.2000 = 20%
    corporate_tax_rate NUMERIC(6,4),
    is_eu_member    BOOLEAN       NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_country IS 'ISO 3166-1 国家主数据，含税率、大区、本币';
COMMENT ON COLUMN dim_country.vat_rate IS '当地增值税 / GST 税率（小数形式）';

-- =============================================================================
-- DOMAIN II: 产品 / BOM / 原材料
-- =============================================================================

CREATE TABLE dim_component_category (
    category_id     SERIAL PRIMARY KEY,
    category_code   VARCHAR(20)  NOT NULL UNIQUE,
    category_name   VARCHAR(100) NOT NULL,
    parent_id       INT          REFERENCES dim_component_category(category_id),
    level           SMALLINT     NOT NULL DEFAULT 1,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_component_category IS '零部件品类层级，支持多级（电池系统 > 电池模组 > 电芯）';
COMMENT ON COLUMN dim_component_category.level IS '层级深度，1=顶层大类';

CREATE TABLE dim_component (
    component_id        SERIAL PRIMARY KEY,
    component_code      VARCHAR(30)   NOT NULL UNIQUE,
    component_name      VARCHAR(200)  NOT NULL,
    category_id         INT           NOT NULL REFERENCES dim_component_category(category_id),
    uom                 VARCHAR(10)   NOT NULL DEFAULT 'PCS',  -- 计量单位
    weight_kg           NUMERIC(10,4),
    standard_cost_usd   NUMERIC(14,4) NOT NULL,
    list_price_usd      NUMERIC(14,4),
    is_finished_good    BOOLEAN       NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN       NOT NULL DEFAULT TRUE,
    lifecycle_stage     VARCHAR(20)   CHECK (lifecycle_stage IN ('NPI','RAMP','MASS','EOL')),
    hs_code             VARCHAR(20),   -- 海关编码
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_component IS '零部件/产品主数据；is_finished_good=TRUE 表示整机/总成';
COMMENT ON COLUMN dim_component.standard_cost_usd IS '标准成本（USD），用于成本核算基准';
COMMENT ON COLUMN dim_component.hs_code IS 'HS 关税编码，用于跨境贸易关税查询';

CREATE TABLE bom_header (
    bom_id          SERIAL PRIMARY KEY,
    bom_code        VARCHAR(40)  NOT NULL UNIQUE,
    parent_component_id INT      NOT NULL REFERENCES dim_component(component_id),
    bom_version     VARCHAR(10)  NOT NULL DEFAULT '1.0',
    effective_from  DATE         NOT NULL,
    effective_to    DATE,
    is_current      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_by      VARCHAR(80),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  bom_header IS 'BOM 版本头；支持多版本（版本变更时新建记录）';
COMMENT ON COLUMN bom_header.is_current IS '是否当前有效版本';

CREATE TABLE bom_item (
    bom_item_id         SERIAL PRIMARY KEY,
    bom_id              INT           NOT NULL REFERENCES bom_header(bom_id),
    child_component_id  INT           NOT NULL REFERENCES dim_component(component_id),
    qty_per_parent      NUMERIC(12,4) NOT NULL,
    item_seq            SMALLINT      NOT NULL DEFAULT 10,
    scrap_rate          NUMERIC(6,4)  NOT NULL DEFAULT 0,  -- 废品率 e.g. 0.005
    substitutable       BOOLEAN       NOT NULL DEFAULT FALSE,
    notes               TEXT,
    UNIQUE (bom_id, child_component_id)
);
COMMENT ON TABLE  bom_item IS 'BOM 明细行；qty_per_parent 为每件父件需用量';
COMMENT ON COLUMN bom_item.scrap_rate IS '计划废品率，用于 MRP 投料量计算';

CREATE TABLE dim_raw_material (
    material_id     SERIAL PRIMARY KEY,
    material_code   VARCHAR(30)  NOT NULL UNIQUE,
    material_name   VARCHAR(200) NOT NULL,
    category        VARCHAR(50),           -- 锂、镍、钴、铜、铝、稀土等
    uom             VARCHAR(10)  NOT NULL DEFAULT 'MT',  -- 公吨
    commodity_ticker VARCHAR(20),          -- 大宗商品代码
    primary_source_country_id INT REFERENCES dim_country(country_id),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_raw_material IS '原材料主数据（大宗商品级别，如碳酸锂、镍板）';

CREATE TABLE component_material_usage (
    usage_id        SERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    material_id     INT           NOT NULL REFERENCES dim_raw_material(material_id),
    usage_kg_per_unit NUMERIC(10,4) NOT NULL,
    notes           TEXT,
    UNIQUE (component_id, material_id)
);
COMMENT ON TABLE  component_material_usage IS '零部件原材料消耗折算（每个零件含多少 kg 原材料）';

CREATE TABLE fact_raw_material_price_daily (
    price_id        BIGSERIAL PRIMARY KEY,
    material_id     INT           NOT NULL REFERENCES dim_raw_material(material_id),
    price_date      DATE          NOT NULL,
    price_usd_per_mt NUMERIC(14,4) NOT NULL,
    price_source    VARCHAR(50),           -- LME / SMM / Platts 等
    UNIQUE (material_id, price_date)
);
COMMENT ON TABLE  fact_raw_material_price_daily IS '原材料每日现货价格（USD/公吨）';
CREATE INDEX idx_rmp_material_date ON fact_raw_material_price_daily(material_id, price_date DESC);

-- =============================================================================
-- DOMAIN III: 工厂 / 生产线 / 生产订单 / 质量
-- =============================================================================

CREATE TABLE dim_factory (
    factory_id      SERIAL PRIMARY KEY,
    factory_code    VARCHAR(20)  NOT NULL UNIQUE,
    factory_name    VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES dim_country(country_id),
    city            VARCHAR(100),
    capacity_uom    VARCHAR(20)  NOT NULL DEFAULT 'UNITS/YEAR',
    annual_capacity NUMERIC(14,2),
    headcount       INT,
    iso_certified   BOOLEAN      NOT NULL DEFAULT FALSE,
    iatf_certified  BOOLEAN      NOT NULL DEFAULT FALSE,  -- IATF 16949 质量认证
    opened_date     DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_factory IS '生产工厂主数据，含产能、认证、所在国家';

CREATE TABLE dim_production_line (
    line_id         SERIAL PRIMARY KEY,
    line_code       VARCHAR(20)  NOT NULL UNIQUE,
    line_name       VARCHAR(200) NOT NULL,
    factory_id      INT          NOT NULL REFERENCES dim_factory(factory_id),
    primary_category_id INT      REFERENCES dim_component_category(category_id),
    designed_takt_sec   NUMERIC(8,2),  -- 设计节拍（秒）
    current_takt_sec    NUMERIC(8,2),
    shift_count     SMALLINT     NOT NULL DEFAULT 2,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_production_line IS '生产线主数据，含节拍、班次、所属工厂';

CREATE TABLE fact_production_order (
    prod_order_id   BIGSERIAL PRIMARY KEY,
    prod_order_no   VARCHAR(30)  NOT NULL UNIQUE,
    component_id    INT          NOT NULL REFERENCES dim_component(component_id),
    line_id         INT          NOT NULL REFERENCES dim_production_line(line_id),
    factory_id      INT          NOT NULL REFERENCES dim_factory(factory_id),
    planned_qty     NUMERIC(12,2) NOT NULL,
    actual_qty      NUMERIC(12,2),
    scrap_qty       NUMERIC(12,2) NOT NULL DEFAULT 0,
    planned_start   TIMESTAMPTZ  NOT NULL,
    planned_end     TIMESTAMPTZ  NOT NULL,
    actual_start    TIMESTAMPTZ,
    actual_end      TIMESTAMPTZ,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('PLANNED','RELEASED','IN_PROGRESS','COMPLETED','CANCELLED')),
    std_material_cost_usd NUMERIC(16,4),  -- 标准材料成本
    actual_material_cost_usd NUMERIC(16,4),
    std_labor_cost_usd    NUMERIC(16,4),
    actual_labor_cost_usd NUMERIC(16,4),
    std_overhead_cost_usd NUMERIC(16,4),
    actual_overhead_cost_usd NUMERIC(16,4),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_production_order IS '生产订单事实表，含计划/实际数量、标准/实际成本三科目';
CREATE INDEX idx_po_component ON fact_production_order(component_id);
CREATE INDEX idx_po_factory   ON fact_production_order(factory_id);
CREATE INDEX idx_po_date      ON fact_production_order(planned_start);

CREATE TABLE fact_quality_inspection (
    inspection_id   BIGSERIAL PRIMARY KEY,
    prod_order_id   BIGINT        NOT NULL REFERENCES fact_production_order(prod_order_id),
    inspection_date DATE          NOT NULL,
    inspected_qty   NUMERIC(12,2) NOT NULL,
    passed_qty      NUMERIC(12,2) NOT NULL,
    failed_qty      NUMERIC(12,2) NOT NULL,
    rework_qty      NUMERIC(12,2) NOT NULL DEFAULT 0,
    scrap_qty       NUMERIC(12,2) NOT NULL DEFAULT 0,
    defect_code     VARCHAR(30),
    inspector_id    VARCHAR(30),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_quality_inspection IS '过程质量检验事实表；FPY = passed_qty / inspected_qty';
CREATE INDEX idx_qi_order  ON fact_quality_inspection(prod_order_id);
CREATE INDEX idx_qi_date   ON fact_quality_inspection(inspection_date);

CREATE TABLE fact_scrap_event (
    scrap_id        BIGSERIAL PRIMARY KEY,
    prod_order_id   BIGINT        NOT NULL REFERENCES fact_production_order(prod_order_id),
    scrap_date      DATE          NOT NULL,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    scrap_qty       NUMERIC(12,2) NOT NULL,
    scrap_reason    VARCHAR(100),
    scrap_cost_usd  NUMERIC(14,4),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_scrap_event IS '废品事件明细；废品成本 = scrap_qty * standard_cost';
CREATE INDEX idx_scrap_date ON fact_scrap_event(scrap_date);

-- =============================================================================
-- DOMAIN IV: 供应商 / 采购
-- =============================================================================

CREATE TABLE dim_supplier (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_code   VARCHAR(20)  NOT NULL UNIQUE,
    supplier_name   VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES dim_country(country_id),
    tier            SMALLINT     NOT NULL DEFAULT 1 CHECK (tier IN (1,2,3)),
    category_id     INT          REFERENCES dim_component_category(category_id),
    payment_terms_days INT       NOT NULL DEFAULT 60,
    currency_id     INT          NOT NULL REFERENCES dim_currency(currency_id),
    is_strategic    BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    risk_rating     VARCHAR(10)  CHECK (risk_rating IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_supplier IS '供应商主数据；tier=1 直供，tier=2 二级，含风险评级';

CREATE TABLE fact_purchase_order (
    po_id           BIGSERIAL PRIMARY KEY,
    po_number       VARCHAR(30)  NOT NULL UNIQUE,
    supplier_id     INT          NOT NULL REFERENCES dim_supplier(supplier_id),
    factory_id      INT          NOT NULL REFERENCES dim_factory(factory_id),
    po_date         DATE         NOT NULL,
    delivery_date   DATE         NOT NULL,
    currency_id     INT          NOT NULL REFERENCES dim_currency(currency_id),
    total_amount    NUMERIC(18,4) NOT NULL,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('OPEN','PARTIAL','RECEIVED','INVOICED','CLOSED','CANCELLED')),
    incoterm        VARCHAR(10),  -- EXW / FOB / CIF / DDP 等
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_purchase_order IS '采购订单头表';
CREATE INDEX idx_po_supplier ON fact_purchase_order(supplier_id);
CREATE INDEX idx_po_podate   ON fact_purchase_order(po_date);

CREATE TABLE fact_purchase_order_item (
    po_item_id      BIGSERIAL PRIMARY KEY,
    po_id           BIGINT        NOT NULL REFERENCES fact_purchase_order(po_id),
    item_seq        SMALLINT      NOT NULL DEFAULT 10,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    ordered_qty     NUMERIC(12,2) NOT NULL,
    received_qty    NUMERIC(12,2) NOT NULL DEFAULT 0,
    unit_price      NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    net_unit_price  NUMERIC(14,4) NOT NULL,
    line_amount     NUMERIC(18,4) NOT NULL,
    UNIQUE (po_id, item_seq)
);
COMMENT ON TABLE  fact_purchase_order_item IS '采购订单行项目，含折扣后净价';
CREATE INDEX idx_poi_component ON fact_purchase_order_item(component_id);

CREATE TABLE fact_supplier_delivery (
    delivery_id     BIGSERIAL PRIMARY KEY,
    po_id           BIGINT        NOT NULL REFERENCES fact_purchase_order(po_id),
    supplier_id     INT           NOT NULL REFERENCES dim_supplier(supplier_id),
    promised_date   DATE          NOT NULL,
    actual_date     DATE,
    qty_delivered   NUMERIC(12,2) NOT NULL,
    is_on_time      BOOLEAN,
    days_late       INT           GENERATED ALWAYS AS (
                        CASE WHEN actual_date IS NOT NULL AND actual_date > promised_date
                             THEN actual_date - promised_date ELSE 0 END
                    ) STORED,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_supplier_delivery IS '供应商交货记录；on-time delivery = is_on_time = TRUE';
CREATE INDEX idx_sd_supplier ON fact_supplier_delivery(supplier_id);
CREATE INDEX idx_sd_date     ON fact_supplier_delivery(promised_date);

CREATE TABLE fact_supplier_quality (
    sq_id           BIGSERIAL PRIMARY KEY,
    supplier_id     INT           NOT NULL REFERENCES dim_supplier(supplier_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    inspection_date DATE          NOT NULL,
    lot_qty         NUMERIC(12,2) NOT NULL,
    defect_qty      NUMERIC(12,2) NOT NULL DEFAULT 0,
    defect_ppm      NUMERIC(10,2) GENERATED ALWAYS AS (
                        CASE WHEN lot_qty > 0 THEN defect_qty / lot_qty * 1000000 ELSE 0 END
                    ) STORED,
    rejection_reason VARCHAR(200),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_supplier_quality IS '来料检验事实表；defect_ppm 自动计算';
CREATE INDEX idx_squal_supplier ON fact_supplier_quality(supplier_id);

-- =============================================================================
-- DOMAIN V: 客户 / 渠道 / 价格 / 销售
-- =============================================================================

CREATE TABLE dim_customer (
    customer_id     SERIAL PRIMARY KEY,
    customer_code   VARCHAR(20)  NOT NULL UNIQUE,
    customer_name   VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES dim_country(country_id),
    customer_type   VARCHAR(30)  CHECK (customer_type IN ('OEM','TIER1','DISTRIBUTOR','AFTERMARKET','GOVT')),
    credit_limit_usd NUMERIC(18,4),
    payment_terms_days INT       NOT NULL DEFAULT 45,
    currency_id     INT          NOT NULL REFERENCES dim_currency(currency_id),
    is_strategic    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_customer IS '客户主数据；customer_type 区分 OEM/经销商/售后等';

CREATE TABLE dim_sales_channel (
    channel_id      SERIAL PRIMARY KEY,
    channel_code    VARCHAR(20)  NOT NULL UNIQUE,
    channel_name    VARCHAR(100) NOT NULL,
    channel_type    VARCHAR(30)  CHECK (channel_type IN ('DIRECT','DISTRIBUTION','ONLINE','GOVT_TENDER')),
    commission_rate NUMERIC(6,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_sales_channel IS '销售渠道主数据，含佣金率';

CREATE TABLE fact_country_price_list (
    price_list_id   BIGSERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    country_id      INT           NOT NULL REFERENCES dim_country(country_id),
    currency_id     INT           NOT NULL REFERENCES dim_currency(currency_id),
    list_price      NUMERIC(14,4) NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    is_current      BOOLEAN       NOT NULL DEFAULT TRUE,
    UNIQUE (component_id, country_id, effective_from)
);
COMMENT ON TABLE  fact_country_price_list IS '分国家标准价格表；支持多币种、多时间段版本';
CREATE INDEX idx_cpl_component ON fact_country_price_list(component_id);
CREATE INDEX idx_cpl_country   ON fact_country_price_list(country_id);

CREATE TABLE fact_price_agreement (
    agreement_id    BIGSERIAL PRIMARY KEY,
    agreement_no    VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT          NOT NULL REFERENCES dim_component(component_id),
    currency_id     INT          NOT NULL REFERENCES dim_currency(currency_id),
    agreed_price    NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    min_qty_per_year NUMERIC(14,2),
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_price_agreement IS '客户专项价格协议，优先级高于国家价格表';
CREATE INDEX idx_pa_customer  ON fact_price_agreement(customer_id);
CREATE INDEX idx_pa_component ON fact_price_agreement(component_id);

CREATE TABLE fact_sales_order (
    so_id           BIGSERIAL PRIMARY KEY,
    so_number       VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    channel_id      INT          NOT NULL REFERENCES dim_sales_channel(channel_id),
    order_date      DATE         NOT NULL,
    requested_delivery_date DATE,
    actual_delivery_date DATE,
    ship_from_factory_id INT     REFERENCES dim_factory(factory_id),
    ship_to_country_id   INT     NOT NULL REFERENCES dim_country(country_id),
    currency_id     INT          NOT NULL REFERENCES dim_currency(currency_id),
    total_gross_revenue    NUMERIC(18,4) NOT NULL,
    total_discount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_net_revenue      NUMERIC(18,4) NOT NULL,
    total_std_material_cost NUMERIC(18,4),
    total_freight_cost     NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_tariff_cost      NUMERIC(18,4) NOT NULL DEFAULT 0,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('DRAFT','CONFIRMED','SHIPPED','DELIVERED','INVOICED','CLOSED','CANCELLED')),
    incoterm        VARCHAR(10),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_sales_order IS '销售订单头表，聚合毛收入/净收入/成本/运费/关税';
CREATE INDEX idx_so_customer ON fact_sales_order(customer_id);
CREATE INDEX idx_so_date     ON fact_sales_order(order_date);
CREATE INDEX idx_so_country  ON fact_sales_order(ship_to_country_id);

CREATE TABLE fact_sales_order_item (
    so_item_id      BIGSERIAL PRIMARY KEY,
    so_id           BIGINT        NOT NULL REFERENCES fact_sales_order(so_id),
    item_seq        SMALLINT      NOT NULL DEFAULT 10,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    qty             NUMERIC(12,2) NOT NULL,
    list_price      NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    net_unit_price  NUMERIC(14,4) NOT NULL,
    gross_line_amount NUMERIC(18,4) NOT NULL,
    net_line_amount   NUMERIC(18,4) NOT NULL,
    std_material_cost NUMERIC(14,4),
    manufacturing_cost NUMERIC(14,4),
    UNIQUE (so_id, item_seq)
);
COMMENT ON TABLE  fact_sales_order_item IS '销售订单行项目，含标准成本、制造成本分摊';
CREATE INDEX idx_soi_so        ON fact_sales_order_item(so_id);
CREATE INDEX idx_soi_component ON fact_sales_order_item(component_id);

CREATE TABLE fact_rebate (
    rebate_id       BIGSERIAL PRIMARY KEY,
    customer_id     INT           NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT           REFERENCES dim_component(component_id),
    period_year     SMALLINT      NOT NULL,
    period_quarter  SMALLINT,
    rebate_type     VARCHAR(30)   CHECK (rebate_type IN ('VOLUME','ANNUAL','PROMO','LOYALTY')),
    rebate_amount_usd NUMERIC(16,4) NOT NULL,
    basis_revenue_usd NUMERIC(16,4),
    rebate_rate     NUMERIC(6,4),
    paid_date       DATE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_rebate IS '返利事实表；影响净收入口径（从 Net Revenue 中扣除）';

CREATE TABLE fact_volume_discount (
    vd_id           BIGSERIAL PRIMARY KEY,
    customer_id     INT           NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    tier_from_qty   NUMERIC(14,2) NOT NULL,
    tier_to_qty     NUMERIC(14,2),
    discount_pct    NUMERIC(6,4)  NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_volume_discount IS '阶梯数量折扣协议';

-- =============================================================================
-- DOMAIN VI: 库存 / 仓储
-- =============================================================================

CREATE TABLE dim_warehouse (
    warehouse_id    SERIAL PRIMARY KEY,
    warehouse_code  VARCHAR(20)  NOT NULL UNIQUE,
    warehouse_name  VARCHAR(200) NOT NULL,
    factory_id      INT          REFERENCES dim_factory(factory_id),
    country_id      INT          NOT NULL REFERENCES dim_country(country_id),
    warehouse_type  VARCHAR(20)  CHECK (warehouse_type IN ('RAW','WIP','FG','TRANSIT','3PL')),
    capacity_sqm    NUMERIC(10,2),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_warehouse IS '仓库主数据；含原料/在制/成品/在途/三方仓';

CREATE TABLE fact_inventory_snapshot (
    snapshot_id     BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    qty_on_hand     NUMERIC(14,2) NOT NULL,
    qty_reserved    NUMERIC(14,2) NOT NULL DEFAULT 0,
    qty_available   NUMERIC(14,2) GENERATED ALWAYS AS (qty_on_hand - qty_reserved) STORED,
    avg_cost_usd    NUMERIC(14,4),  -- 移动平均成本
    inventory_value_usd NUMERIC(18,4),
    UNIQUE (snapshot_date, warehouse_id, component_id)
);
COMMENT ON TABLE  fact_inventory_snapshot IS '月末/日末库存快照；inventory_value = qty * avg_cost';
CREATE INDEX idx_inv_snap_date      ON fact_inventory_snapshot(snapshot_date DESC);
CREATE INDEX idx_inv_snap_component ON fact_inventory_snapshot(component_id);
CREATE INDEX idx_inv_snap_warehouse ON fact_inventory_snapshot(warehouse_id);

CREATE TABLE fact_inventory_movement (
    movement_id     BIGSERIAL PRIMARY KEY,
    movement_date   TIMESTAMPTZ   NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    movement_type   VARCHAR(20)   NOT NULL CHECK (movement_type IN ('GR','GI','TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT','RETURN')),
    qty             NUMERIC(14,2) NOT NULL,  -- 正数=入，负数=出
    reference_doc   VARCHAR(30),
    unit_cost_usd   NUMERIC(14,4),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_inventory_movement IS '库存移动明细；GR=收货，GI=发货，TRANSFER=调拨';
CREATE INDEX idx_im_date      ON fact_inventory_movement(movement_date DESC);
CREATE INDEX idx_im_component ON fact_inventory_movement(component_id);

CREATE TABLE fact_stockout_event (
    stockout_id     BIGSERIAL PRIMARY KEY,
    event_date      DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    stockout_days   INT           NOT NULL DEFAULT 1,
    lost_demand_qty NUMERIC(14,2),
    lost_revenue_est_usd NUMERIC(16,4),
    root_cause      VARCHAR(100),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_stockout_event IS '断货事件记录；用于计算 Stockout Rate 和潜在损失';

-- =============================================================================
-- DOMAIN VII: 财务 / 汇率 / 利率 / 应收
-- =============================================================================

CREATE TABLE fact_exchange_rate_daily (
    fx_id           BIGSERIAL PRIMARY KEY,
    rate_date       DATE          NOT NULL,
    from_currency_id INT          NOT NULL REFERENCES dim_currency(currency_id),
    to_currency_id  INT          NOT NULL REFERENCES dim_currency(currency_id),
    rate            NUMERIC(18,8) NOT NULL,   -- 1 from = rate * to
    rate_source     VARCHAR(30)  DEFAULT 'ECB',
    UNIQUE (rate_date, from_currency_id, to_currency_id)
);
COMMENT ON TABLE  fact_exchange_rate_daily IS '每日汇率，支持任意货币对；用于 FX Impact 计算';
CREATE INDEX idx_fx_date ON fact_exchange_rate_daily(rate_date DESC);

CREATE TABLE fact_interest_rate_daily (
    ir_id           BIGSERIAL PRIMARY KEY,
    rate_date       DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES dim_country(country_id),
    rate_type       VARCHAR(30)   NOT NULL CHECK (rate_type IN ('CENTRAL_BANK','LIBOR_3M','SOFR','EURIBOR_3M','SHIBOR_3M','LPR_1Y')),
    rate_pct        NUMERIC(8,4)  NOT NULL,
    UNIQUE (rate_date, country_id, rate_type)
);
COMMENT ON TABLE  fact_interest_rate_daily IS '各国基准利率日表；用于库存资金占用成本和应收融资成本计算';

CREATE TABLE fact_receivable_aging (
    aging_id        BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE          NOT NULL,
    customer_id     INT           NOT NULL REFERENCES dim_customer(customer_id),
    country_id      INT           NOT NULL REFERENCES dim_country(country_id),
    currency_id     INT           NOT NULL REFERENCES dim_currency(currency_id),
    bucket_0_30     NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_31_60    NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_61_90    NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_91_180   NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_over_180 NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_outstanding NUMERIC(18,4) GENERATED ALWAYS AS (
        bucket_0_30 + bucket_31_60 + bucket_61_90 + bucket_91_180 + bucket_over_180
    ) STORED,
    financing_cost_usd NUMERIC(16,4),  -- 当期融资成本（应收 * 利率 * 天数/360）
    UNIQUE (snapshot_date, customer_id)
);
COMMENT ON TABLE  fact_receivable_aging IS '应收账款账龄快照；financing_cost = outstanding * ir * days/360';
CREATE INDEX idx_recv_date     ON fact_receivable_aging(snapshot_date DESC);
CREATE INDEX idx_recv_customer ON fact_receivable_aging(customer_id);

CREATE TABLE fact_inventory_carrying_cost (
    icc_id          BIGSERIAL PRIMARY KEY,
    period_date     DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    avg_inventory_value_usd NUMERIC(18,4) NOT NULL,
    interest_rate_pct       NUMERIC(8,4)  NOT NULL,
    storage_cost_rate_pct   NUMERIC(8,4)  NOT NULL DEFAULT 2.0,  -- 仓储成本率（年化）
    obsolescence_rate_pct   NUMERIC(8,4)  NOT NULL DEFAULT 1.5,  -- 过时风险率（年化）
    carrying_cost_usd       NUMERIC(16,4) NOT NULL,
    UNIQUE (period_date, warehouse_id, component_id)
);
COMMENT ON TABLE  fact_inventory_carrying_cost IS '库存持有成本 = 库存价值 * (利率+仓储率+过时率) * 天数/365';
CREATE INDEX idx_icc_date ON fact_inventory_carrying_cost(period_date DESC);

-- =============================================================================
-- DOMAIN VIII: 跨国贸易 / 关税 / 物流
-- =============================================================================

CREATE TABLE fact_tariff_rate (
    tariff_id       BIGSERIAL PRIMARY KEY,
    hs_code         VARCHAR(20)   NOT NULL,
    from_country_id INT           NOT NULL REFERENCES dim_country(country_id),
    to_country_id   INT           NOT NULL REFERENCES dim_country(country_id),
    tariff_rate_pct NUMERIC(8,4)  NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    tariff_type     VARCHAR(30)   CHECK (tariff_type IN ('MFN','FTA','ANTI_DUMPING','PREFERENTIAL','RETALIATORY')),
    notes           TEXT,
    UNIQUE (hs_code, from_country_id, to_country_id, effective_from)
);
COMMENT ON TABLE  fact_tariff_rate IS '关税税率表，按 HS Code + 贸易路线 + 时间段';
CREATE INDEX idx_tariff_hs      ON fact_tariff_rate(hs_code);
CREATE INDEX idx_tariff_route   ON fact_tariff_rate(from_country_id, to_country_id);

CREATE TABLE fact_trade_lane (
    lane_id         BIGSERIAL PRIMARY KEY,
    lane_code       VARCHAR(30)   NOT NULL UNIQUE,
    from_country_id INT           NOT NULL REFERENCES dim_country(country_id),
    to_country_id   INT           NOT NULL REFERENCES dim_country(country_id),
    transport_mode  VARCHAR(20)   NOT NULL CHECK (transport_mode IN ('SEA','AIR','RAIL','ROAD','MULTIMODAL')),
    transit_days    INT           NOT NULL,
    base_rate_usd_per_cbm NUMERIC(10,4),
    base_rate_usd_per_kg  NUMERIC(10,4),
    carrier         VARCHAR(100),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_trade_lane IS '贸易航线/运输路线主数据';
CREATE INDEX idx_tl_route ON fact_trade_lane(from_country_id, to_country_id);

CREATE TABLE fact_freight_cost (
    freight_id      BIGSERIAL PRIMARY KEY,
    so_id           BIGINT        REFERENCES fact_sales_order(so_id),
    lane_id         BIGINT        NOT NULL REFERENCES fact_trade_lane(lane_id),
    shipment_date   DATE          NOT NULL,
    weight_kg       NUMERIC(12,4),
    volume_cbm      NUMERIC(10,4),
    chargeable_weight_kg NUMERIC(12,4),
    freight_amount_usd   NUMERIC(16,4) NOT NULL,
    insurance_amount_usd NUMERIC(14,4) NOT NULL DEFAULT 0,
    handling_fee_usd     NUMERIC(14,4) NOT NULL DEFAULT 0,
    total_logistics_cost_usd NUMERIC(16,4) NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_freight_cost IS '运费事实表，含运费+保险+装卸费';
CREATE INDEX idx_fc_so   ON fact_freight_cost(so_id);
CREATE INDEX idx_fc_date ON fact_freight_cost(shipment_date);

CREATE TABLE fact_shipping_order (
    shipping_id     BIGSERIAL PRIMARY KEY,
    shipping_no     VARCHAR(30)   NOT NULL UNIQUE,
    so_id           BIGINT        REFERENCES fact_sales_order(so_id),
    lane_id         BIGINT        NOT NULL REFERENCES fact_trade_lane(lane_id),
    ship_date       DATE          NOT NULL,
    eta_date        DATE,
    actual_arrival_date DATE,
    status          VARCHAR(20)   NOT NULL CHECK (status IN ('BOOKED','IN_TRANSIT','ARRIVED','CLEARED','DELIVERED')),
    container_no    VARCHAR(30),
    bl_no           VARCHAR(30),  -- 提单号
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_shipping_order IS '装运单/提单主数据，关联运费和销售订单';

-- =============================================================================
-- DOMAIN IX: ESG 碳排放
-- =============================================================================

CREATE TABLE dim_emission_scope (
    scope_id        SERIAL PRIMARY KEY,
    scope_code      VARCHAR(10)  NOT NULL UNIQUE,
    scope_name      VARCHAR(100) NOT NULL,
    description     TEXT
);
COMMENT ON TABLE  dim_emission_scope IS 'GHG Protocol Scope 1/2/3 分类';

CREATE TABLE fact_factory_energy_consumption (
    energy_id       BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES dim_factory(factory_id),
    period_month    DATE          NOT NULL,  -- 每月第一天
    scope_id        INT           NOT NULL REFERENCES dim_emission_scope(scope_id),
    energy_type     VARCHAR(30)   CHECK (energy_type IN ('GRID_ELEC','NATURAL_GAS','DIESEL','RENEWABLE','COAL','STEAM')),
    consumption_kwh NUMERIC(16,4),
    consumption_mj  NUMERIC(16,4),
    emission_factor_kgco2e_per_kwh NUMERIC(10,6),
    total_emission_tco2e   NUMERIC(14,4) NOT NULL,
    renewable_pct   NUMERIC(6,4)  NOT NULL DEFAULT 0,
    UNIQUE (factory_id, period_month, scope_id, energy_type)
);
COMMENT ON TABLE  fact_factory_energy_consumption IS '工厂能耗碳排放（月度）；tCO2e = 吨二氧化碳当量';
CREATE INDEX idx_fec_factory ON fact_factory_energy_consumption(factory_id);
CREATE INDEX idx_fec_month   ON fact_factory_energy_consumption(period_month);

CREATE TABLE fact_component_carbon_footprint (
    footprint_id    BIGSERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    factory_id      INT           NOT NULL REFERENCES dim_factory(factory_id),
    calc_year       SMALLINT      NOT NULL,
    scope1_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    scope2_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    scope3_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    total_kgco2e_per_unit  NUMERIC(12,6) GENERATED ALWAYS AS (
        scope1_kgco2e_per_unit + scope2_kgco2e_per_unit + scope3_kgco2e_per_unit
    ) STORED,
    cert_standard   VARCHAR(30),  -- ISO 14064 / PAS 2050 / GHG Protocol
    UNIQUE (component_id, factory_id, calc_year)
);
COMMENT ON TABLE  fact_component_carbon_footprint IS '单位产品碳足迹（PCF），按工厂+年度';
CREATE INDEX idx_ccf_component ON fact_component_carbon_footprint(component_id);
CREATE INDEX idx_ccf_factory   ON fact_component_carbon_footprint(factory_id);

CREATE TABLE fact_supplier_esg_score (
    esg_id          BIGSERIAL PRIMARY KEY,
    supplier_id     INT           NOT NULL REFERENCES dim_supplier(supplier_id),
    assess_year     SMALLINT      NOT NULL,
    env_score       NUMERIC(5,2),   -- 0-100
    social_score    NUMERIC(5,2),
    governance_score NUMERIC(5,2),
    overall_score   NUMERIC(5,2),
    carbon_intensity_tco2e_per_mrevenue NUMERIC(10,4),  -- 百万收入碳强度
    water_usage_m3_per_unit NUMERIC(10,4),
    assessor        VARCHAR(100),
    UNIQUE (supplier_id, assess_year)
);
COMMENT ON TABLE  fact_supplier_esg_score IS '供应商 ESG 评分（年度）；与供应商质量联合分析供应链风险';

CREATE TABLE fact_shipping_emission (
    se_id           BIGSERIAL PRIMARY KEY,
    shipping_id     BIGINT        NOT NULL REFERENCES fact_shipping_order(shipping_id),
    transport_mode  VARCHAR(20)   NOT NULL,
    distance_km     NUMERIC(10,2),
    weight_mt       NUMERIC(12,4),
    emission_factor_kgco2e_per_tkm NUMERIC(10,6),
    total_emission_kgco2e NUMERIC(14,4) NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_shipping_emission IS '运输碳排放；scope3 物流碳排 = 重量(t) * 距离(km) * 排放因子';

CREATE TABLE fact_carbon_price (
    cp_id           BIGSERIAL PRIMARY KEY,
    price_date      DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES dim_country(country_id),
    scheme          VARCHAR(50)   NOT NULL,  -- EU ETS / UK ETS / CCER / California CAP
    price_usd_per_tco2e NUMERIC(12,4) NOT NULL,
    UNIQUE (price_date, country_id, scheme)
);
COMMENT ON TABLE  fact_carbon_price IS '碳价格（每日，按国家/碳市场）；EU ETS 约 60-90 USD/tCO2e';
CREATE INDEX idx_cp_date ON fact_carbon_price(price_date DESC);

CREATE TABLE fact_carbon_tax (
    ct_id           BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES dim_factory(factory_id),
    period_month    DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES dim_country(country_id),
    total_emission_tco2e   NUMERIC(14,4) NOT NULL,
    free_allowance_tco2e   NUMERIC(14,4) NOT NULL DEFAULT 0,
    taxable_emission_tco2e NUMERIC(14,4) NOT NULL,
    carbon_price_usd_per_tco2e NUMERIC(12,4) NOT NULL,
    carbon_tax_usd  NUMERIC(16,4) NOT NULL,
    UNIQUE (factory_id, period_month)
);
COMMENT ON TABLE  fact_carbon_tax IS '工厂碳税月度汇总；taxable = total - free_allowance';
CREATE INDEX idx_ct_factory ON fact_carbon_tax(factory_id);

CREATE TABLE fact_carbon_credit (
    credit_id       BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES dim_factory(factory_id),
    credit_date     DATE          NOT NULL,
    credit_type     VARCHAR(30)   CHECK (credit_type IN ('VCS','GOLD_STANDARD','CDM','CCER','I_REC')),
    qty_tco2e       NUMERIC(14,4) NOT NULL,
    purchase_price_usd NUMERIC(12,4),
    total_cost_usd  NUMERIC(16,4),
    retired_qty     NUMERIC(14,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_carbon_credit IS '碳信用购买与注销记录';

-- =============================================================================
-- DOMAIN X: 售后 / 保修 / 索赔
-- =============================================================================

CREATE TABLE dim_failure_mode (
    failure_id      SERIAL PRIMARY KEY,
    failure_code    VARCHAR(20)  NOT NULL UNIQUE,
    failure_name    VARCHAR(200) NOT NULL,
    component_category_id INT   REFERENCES dim_component_category(category_id),
    severity        VARCHAR(10)  CHECK (severity IN ('CRITICAL','MAJOR','MINOR')),
    avg_repair_cost_usd NUMERIC(12,4),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_failure_mode IS '故障模式主数据（FMEA 导出）；severity 分级';

CREATE TABLE fact_warranty_claim (
    claim_id        BIGSERIAL PRIMARY KEY,
    claim_no        VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT          NOT NULL REFERENCES dim_component(component_id),
    failure_id      INT          REFERENCES dim_failure_mode(failure_id),
    so_item_id      BIGINT       REFERENCES fact_sales_order_item(so_item_id),
    claim_date      DATE         NOT NULL,
    failure_date    DATE,
    mileage_km      NUMERIC(10,2),
    claim_qty       NUMERIC(10,2) NOT NULL DEFAULT 1,
    claim_amount_usd NUMERIC(16,4) NOT NULL,
    approved_amount_usd NUMERIC(16,4),
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('OPEN','UNDER_REVIEW','APPROVED','REJECTED','PAID')),
    root_cause_analysis TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_warranty_claim IS '保修索赔事实表；关联销售行项目追溯源头批次';
CREATE INDEX idx_wc_customer  ON fact_warranty_claim(customer_id);
CREATE INDEX idx_wc_component ON fact_warranty_claim(component_id);
CREATE INDEX idx_wc_date      ON fact_warranty_claim(claim_date);

CREATE TABLE fact_field_failure (
    ff_id           BIGSERIAL PRIMARY KEY,
    component_id    INT          NOT NULL REFERENCES dim_component(component_id),
    failure_id      INT          NOT NULL REFERENCES dim_failure_mode(failure_id),
    country_id      INT          NOT NULL REFERENCES dim_country(country_id),
    failure_month   DATE         NOT NULL,
    units_in_field  NUMERIC(14,2) NOT NULL,
    failure_count   INT           NOT NULL,
    failure_rate_ppm NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE WHEN units_in_field > 0 THEN failure_count::NUMERIC / units_in_field * 1000000 ELSE 0 END
    ) STORED,
    campaign_cost_usd NUMERIC(16,4),  -- 召回 / 现场修复成本
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_field_failure IS '现场失效率统计（按月、国家、零件）；ppm 自动计算';
CREATE INDEX idx_ff_component ON fact_field_failure(component_id);
CREATE INDEX idx_ff_month     ON fact_field_failure(failure_month);

-- =============================================================================
-- VIEWS：常用分析视图（供 text2ontology 发现关系）
-- =============================================================================

CREATE VIEW v_adjusted_gross_margin AS
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
FROM fact_sales_order_item soi
JOIN fact_sales_order so    ON so.so_id = soi.so_id
JOIN dim_customer c         ON c.customer_id = so.customer_id
JOIN dim_country  cp        ON cp.country_id = so.ship_to_country_id
JOIN dim_component comp     ON comp.component_id = soi.component_id;

COMMENT ON VIEW v_adjusted_gross_margin IS '行项目调整后毛利视图（扣除运费、关税按净收入比例分摊）';

CREATE VIEW v_supplier_risk_scorecard AS
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
FROM dim_supplier s
LEFT JOIN dim_country cnt       ON cnt.country_id = s.country_id
LEFT JOIN fact_supplier_esg_score esg ON esg.supplier_id = s.supplier_id
LEFT JOIN fact_supplier_quality  sq   ON sq.supplier_id = s.supplier_id
LEFT JOIN fact_supplier_delivery sd   ON sd.supplier_id = s.supplier_id
GROUP BY s.supplier_id, s.supplier_code, s.supplier_name, cnt.country_name, s.tier, s.risk_rating;

COMMENT ON VIEW v_supplier_risk_scorecard IS '供应商风险综合评分卡：ESG + 质量 + 交期';
