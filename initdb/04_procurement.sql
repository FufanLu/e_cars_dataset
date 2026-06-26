-- =============================================================================
-- EV OEM Lakehouse - procurement schema: 供应商 / 采购订单 / 来料质量
-- PostgreSQL 16
-- =============================================================================

SET search_path TO procurement, production, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_supplier (
    supplier_id     SERIAL PRIMARY KEY,
    supplier_code   VARCHAR(20)  NOT NULL UNIQUE,
    supplier_name   VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES geo.dim_country(country_id),
    tier            SMALLINT     NOT NULL DEFAULT 1 CHECK (tier IN (1,2,3)),
    category_id     INT          REFERENCES product.dim_component_category(category_id),
    payment_terms_days INT       NOT NULL DEFAULT 60,
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    is_strategic    BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    risk_rating     VARCHAR(10)  CHECK (risk_rating IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_supplier IS '供应商主数据；tier=1直供EV，tier=2二级供应商';
COMMENT ON COLUMN dim_supplier.supplier_code IS '供应商代码，如SUP-CATL(宁德时代)、SUP-TSMC(台积电)';
COMMENT ON COLUMN dim_supplier.tier IS '供应商层级: 1=直供EV, 2=二级物料, 3=原材料';
COMMENT ON COLUMN dim_supplier.category_id IS '供应品类，关联dim_component_category';
COMMENT ON COLUMN dim_supplier.payment_terms_days IS '账期（天），EV通常30-60天';
COMMENT ON COLUMN dim_supplier.is_strategic IS '是否战略供应商（电池/FSD芯片/稀土等关键物料）';
COMMENT ON COLUMN dim_supplier.risk_rating IS '供应风险评级: LOW/MEDIUM/HIGH/CRITICAL';

CREATE TABLE fact_purchase_order (
    po_id           BIGSERIAL PRIMARY KEY,
    po_number       VARCHAR(30)  NOT NULL UNIQUE,
    supplier_id     INT          NOT NULL REFERENCES dim_supplier(supplier_id),
    factory_id      INT          NOT NULL REFERENCES production.dim_factory(factory_id),
    po_date         DATE         NOT NULL,
    delivery_date   DATE         NOT NULL,
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    total_amount    NUMERIC(18,4) NOT NULL,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('OPEN','PARTIAL','RECEIVED','INVOICED','CLOSED','CANCELLED')),
    incoterm        VARCHAR(10),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_purchase_order IS '采购订单头表；EV主要采购电芯/原材料/芯片/玻璃等外购件';
COMMENT ON COLUMN fact_purchase_order.po_number IS '采购单号，格式PRC-YYYYMMDD-SUPPLIER';
COMMENT ON COLUMN fact_purchase_order.supplier_id IS '供应商ID，关联dim_supplier';
COMMENT ON COLUMN fact_purchase_order.factory_id IS '收货工厂ID，关联dim_factory';
COMMENT ON COLUMN fact_purchase_order.po_date IS '下单日期';
COMMENT ON COLUMN fact_purchase_order.delivery_date IS '要求交货日期';
COMMENT ON COLUMN fact_purchase_order.total_amount IS '订单总金额（USD）';
COMMENT ON COLUMN fact_purchase_order.status IS '订单状态：OPEN/PARTIAL/RECEIVED/INVOICED/CLOSED/CANCELLED';
COMMENT ON COLUMN fact_purchase_order.incoterm IS '贸易术语：FOB/CIF/DDP/EXW/DAP';
CREATE INDEX idx_po_supplier ON fact_purchase_order(supplier_id);
CREATE INDEX idx_po_podate   ON fact_purchase_order(po_date);

CREATE TABLE fact_purchase_order_item (
    po_item_id      BIGSERIAL PRIMARY KEY,
    po_id           BIGINT        NOT NULL REFERENCES fact_purchase_order(po_id),
    item_seq        SMALLINT      NOT NULL DEFAULT 10,
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    ordered_qty     NUMERIC(12,2) NOT NULL,
    received_qty    NUMERIC(12,2) NOT NULL DEFAULT 0,
    unit_price      NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    net_unit_price  NUMERIC(14,4) NOT NULL,
    line_amount     NUMERIC(18,4) NOT NULL,
    UNIQUE (po_id, item_seq)
);
COMMENT ON TABLE  fact_purchase_order_item IS '采购订单行项目，含折扣后净价';
COMMENT ON COLUMN fact_purchase_order_item.po_id IS '关联采购订单头';
COMMENT ON COLUMN fact_purchase_order_item.component_id IS '采购的零部件/原材料ID';
COMMENT ON COLUMN fact_purchase_order_item.ordered_qty IS '订购量';
COMMENT ON COLUMN fact_purchase_order_item.received_qty IS '实际收货量';
COMMENT ON COLUMN fact_purchase_order_item.unit_price IS '原始单价（USD）';
COMMENT ON COLUMN fact_purchase_order_item.discount_pct IS '折扣率（%）';
COMMENT ON COLUMN fact_purchase_order_item.net_unit_price IS '折后净单价（USD）';
COMMENT ON COLUMN fact_purchase_order_item.line_amount IS '行金额 = 订购量 × 净单价';
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
COMMENT ON COLUMN fact_supplier_delivery.po_id IS '关联采购订单';
COMMENT ON COLUMN fact_supplier_delivery.promised_date IS '承诺交货日期';
COMMENT ON COLUMN fact_supplier_delivery.actual_date IS '实际交货日期';
COMMENT ON COLUMN fact_supplier_delivery.qty_delivered IS '实际交货数量';
COMMENT ON COLUMN fact_supplier_delivery.is_on_time IS '是否准时交货（实际≤承诺）';
COMMENT ON COLUMN fact_supplier_delivery.days_late IS '延迟天数（生成列），用于供应商绩效评分';
CREATE INDEX idx_sd_supplier ON fact_supplier_delivery(supplier_id);
CREATE INDEX idx_sd_date     ON fact_supplier_delivery(promised_date);

CREATE TABLE fact_supplier_quality (
    sq_id           BIGSERIAL PRIMARY KEY,
    supplier_id     INT           NOT NULL REFERENCES dim_supplier(supplier_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    inspection_date DATE          NOT NULL,
    lot_qty         NUMERIC(12,2) NOT NULL,
    defect_qty      NUMERIC(12,2) NOT NULL DEFAULT 0,
    defect_ppm      NUMERIC(10,2) GENERATED ALWAYS AS (
                        CASE WHEN lot_qty > 0 THEN defect_qty / lot_qty * 1000000 ELSE 0 END
                    ) STORED,
    rejection_reason VARCHAR(200),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_supplier_quality IS '来料检验事实表；defect_ppm自动计算';
COMMENT ON COLUMN fact_supplier_quality.supplier_id IS '供应商ID';
COMMENT ON COLUMN fact_supplier_quality.component_id IS '来料零部件ID';
COMMENT ON COLUMN fact_supplier_quality.lot_qty IS '检验批次数量';
COMMENT ON COLUMN fact_supplier_quality.defect_qty IS '缺陷数量';
COMMENT ON COLUMN fact_supplier_quality.defect_ppm IS '缺陷率PPM（生成列=defect_qty/lot_qty*1M），用于供应商质量排名';
COMMENT ON COLUMN fact_supplier_quality.rejection_reason IS '退货原因：DIMENSIONAL_OOT/ELECTRICAL_FAIL/SURFACE_DEFECT等';
CREATE INDEX idx_squal_supplier ON fact_supplier_quality(supplier_id);

-- =============================================================================
-- SEED DATA — EV真实供应商 (12家)
-- =============================================================================

INSERT INTO dim_supplier (supplier_code, supplier_name, country_id, tier, category_id, payment_terms_days, currency_id, is_strategic, risk_rating) VALUES
-- Tier 1 战略供应商
('SUP-CATL',    'CATL(宁德时代)',          (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'LOW'),
('SUP-PANASONIC','Panasonic Energy(大阪)',  (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'LOW'),
('SUP-LGES',    'LG Energy Solution',      (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'LOW'),
('SUP-TSMC',    'TSMC(台积电)',            (SELECT country_id FROM geo.dim_country WHERE country_code='TW'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD'),      30, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'LOW'),

-- Tier 1/2 原材料
('SUP-GANFENG', '赣锋锂业',                (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),  60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'MEDIUM'),
('SUP-GLENCORE','Glencore(钴/镍)',         (SELECT country_id FROM geo.dim_country WHERE country_code='CH'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),  45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'HIGH'),
('SUP-NOVELIS', 'Novelis(铝板/铝卷)',      (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),  30, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW'),
('SUP-OUTOKUMPU','Outokumpu(不锈钢)',      (SELECT country_id FROM geo.dim_country WHERE country_code='FI'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),  45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW'),

-- Tier 2 零部件
('SUP-SGOBAIN', 'Saint-Gobain(汽车玻璃)',  (SELECT country_id FROM geo.dim_country WHERE country_code='FR'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='GLASS'),    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW'),
('SUP-STMICRO', 'STMicroelectronics(SiC)', (SELECT country_id FROM geo.dim_country WHERE country_code='NL'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'MEDIUM'),
('SUP-APTIV',   'Aptiv(线束/连接器)',      (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'), 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW'),
('SUP-CONTINENTAL','Continental(轮胎)',    (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='CHASSIS'),  45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW');
