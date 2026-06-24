-- =============================================================================
-- EV Parts Lakehouse - procurement schema: 供应商 / 采购订单 / 来料质量
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
COMMENT ON TABLE  dim_supplier IS '供应商主数据；tier=1 直供，tier=2 二级，含风险评级';

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
COMMENT ON TABLE  fact_purchase_order IS '采购订单头表';
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
COMMENT ON TABLE  fact_supplier_quality IS '来料检验事实表；defect_ppm 自动计算';
CREATE INDEX idx_squal_supplier ON fact_supplier_quality(supplier_id);

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_supplier (supplier_code, supplier_name, country_id, tier, category_id, payment_terms_days, currency_id, is_strategic, risk_rating) VALUES
('SUP-CATL-CN',  'CATL (Contemporary Amperex)',    (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),    60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), TRUE,  'LOW'),
('SUP-BYD-CN',   'BYD Component Supply',           (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_MOD'), 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), TRUE,  'LOW'),
('SUP-PANASONIC-JP','Panasonic Energy',             (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), TRUE,  'LOW'),
('SUP-SAMSUNG-KR','Samsung SDI',                   (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='KRW'), TRUE,  'LOW'),
('SUP-LGE-KR',   'LG Energy Solution',             (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='KRW'), TRUE,  'LOW'),
('SUP-ROHM-JP',  'Rohm Semiconductor',             (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), FALSE, 'LOW'),
('SUP-INF-DE',   'Infineon Technologies',          (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE,  'LOW'),
('SUP-BOSCH-DE', 'Bosch EV Components',            (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='ECU'),     45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE,  'LOW'),
('SUP-NIDEC-JP', 'Nidec Motor Corporation',        (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'),   60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), FALSE, 'MEDIUM'),
('SUP-ALUM-CN',  'Novelis China Aluminum',         (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='CHASSIS'),  90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), FALSE, 'LOW'),
('SUP-COPPER-CN','Jiangxi Copper Co.',              (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 2, NULL, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), FALSE, 'LOW'),
('SUP-RARE-CN',  'China Northern Rare Earth',      (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 1, NULL, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), TRUE,  'HIGH'),
('SUP-CONT-DE',  'Continental EV Systems',         (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='ECU'),     45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), FALSE, 'LOW'),
('SUP-SENATA-MX','Sensata Technologies Mexico',    (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), 2, NULL, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='MXN'), FALSE, 'MEDIUM'),
('SUP-UNIPRESS-IN','Unipress India Stampings',     (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), 2, (SELECT category_id FROM product.dim_component_category WHERE category_code='CHASSIS'),  90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='INR'), FALSE, 'MEDIUM'),
('SUP-VIET-WIRE','Vietnam Wiring Harness Co.',     (SELECT country_id FROM geo.dim_country WHERE country_code='VN'), 2, NULL, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='VND'), FALSE, 'MEDIUM'),
('SUP-LIVENT-US','Livent Lithium USA',             (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 1, NULL, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'MEDIUM'),
('SUP-VALE-BR',  'Vale Nickel Brazil',             (SELECT country_id FROM geo.dim_country WHERE country_code='BR'), 1, NULL, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'HIGH'),
('SUP-GLENCORE', 'Glencore Cobalt Supply',         (SELECT country_id FROM geo.dim_country WHERE country_code='GB'), 1, NULL, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE,  'HIGH'),
('SUP-UMICORE-DE','Umicore Battery Materials',     (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),    60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE,  'LOW');
