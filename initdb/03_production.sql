-- =============================================================================
-- EV Parts Lakehouse - production schema: 工厂 / 生产线 / 生产订单 / 质量
-- PostgreSQL 16
-- =============================================================================

SET search_path TO production, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_factory (
    factory_id      SERIAL PRIMARY KEY,
    factory_code    VARCHAR(20)  NOT NULL UNIQUE,
    factory_name    VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES geo.dim_country(country_id),
    city            VARCHAR(100),
    capacity_uom    VARCHAR(20)  NOT NULL DEFAULT 'UNITS/YEAR',
    annual_capacity NUMERIC(14,2),
    headcount       INT,
    iso_certified   BOOLEAN      NOT NULL DEFAULT FALSE,
    iatf_certified  BOOLEAN      NOT NULL DEFAULT FALSE,
    opened_date     DATE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_factory IS '生产工厂主数据，含产能、认证、所在国家';

CREATE TABLE dim_production_line (
    line_id         SERIAL PRIMARY KEY,
    line_code       VARCHAR(20)  NOT NULL UNIQUE,
    line_name       VARCHAR(200) NOT NULL,
    factory_id      INT          NOT NULL REFERENCES dim_factory(factory_id),
    primary_category_id INT      REFERENCES product.dim_component_category(category_id),
    designed_takt_sec   NUMERIC(8,2),
    current_takt_sec    NUMERIC(8,2),
    shift_count     SMALLINT     NOT NULL DEFAULT 2,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_production_line IS '生产线主数据，含节拍、班次、所属工厂';

CREATE TABLE fact_production_order (
    prod_order_id   BIGSERIAL PRIMARY KEY,
    prod_order_no   VARCHAR(30)  NOT NULL UNIQUE,
    component_id    INT          NOT NULL REFERENCES product.dim_component(component_id),
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
    std_material_cost_usd NUMERIC(16,4),
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
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    scrap_qty       NUMERIC(12,2) NOT NULL,
    scrap_reason    VARCHAR(100),
    scrap_cost_usd  NUMERIC(14,4),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_scrap_event IS '废品事件明细；废品成本 = scrap_qty * standard_cost';
CREATE INDEX idx_scrap_date ON fact_scrap_event(scrap_date);

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_factory (factory_code, factory_name, country_id, city, annual_capacity, headcount, iso_certified, iatf_certified, opened_date) VALUES
('FAC-CN-SH', 'Shanghai Battery Assembly Plant',     (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'Shanghai',  200000, 3200, TRUE, TRUE,  '2018-03-01'),
('FAC-CN-WH', 'Wuhan Motor & Drive System Plant',    (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'Wuhan',     120000, 2100, TRUE, TRUE,  '2019-06-01'),
('FAC-CN-CQ', 'Chongqing Component Manufacturing',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'Chongqing',  80000, 1400, TRUE, FALSE, '2020-09-01'),
('FAC-DE-LZ', 'Leipzig Battery Module Plant',        (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'Leipzig',    80000, 1800, TRUE, TRUE,  '2020-01-01'),
('FAC-DE-MU', 'Munich R&D & Low-Volume Assembly',   (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'Munich',     20000,  850, TRUE, TRUE,  '2017-05-01'),
('FAC-US-TX', 'Texas Gigafactory',                  (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'Austin TX', 150000, 2800, TRUE, TRUE,  '2022-04-01'),
('FAC-US-OH', 'Ohio Drive Unit Plant',               (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'Columbus OH', 60000, 1200, TRUE, FALSE, '2021-07-01'),
('FAC-HU-DE', 'Debrecen Battery Pack Plant',         (SELECT country_id FROM geo.dim_country WHERE country_code='HU'), 'Debrecen',   60000, 1600, TRUE, TRUE,  '2023-02-01'),
('FAC-MX-MO', 'Monterrey Sub-Assembly Plant',        (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), 'Monterrey',  40000,  900, TRUE, FALSE, '2021-11-01'),
('FAC-TH-AM', 'Amata City EV Components Plant',      (SELECT country_id FROM geo.dim_country WHERE country_code='TH'), 'Amata City', 30000,  750, TRUE, FALSE, '2022-08-01');

INSERT INTO dim_production_line (line_code, line_name, factory_id, primary_category_id, designed_takt_sec, current_takt_sec, shift_count) VALUES
('LINE-SH-BP1', 'Shanghai Battery Pack Line 1',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_PACK'), 180, 185, 3),
('LINE-SH-BP2', 'Shanghai Battery Pack Line 2',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_PACK'), 180, 190, 3),
('LINE-SH-BM1', 'Shanghai Module Assembly Line 1',   (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_MOD'),  90,  92, 3),
('LINE-WH-MT1', 'Wuhan Motor Line 1 PMSM',           (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'),   240, 245, 2),
('LINE-WH-IV1', 'Wuhan Inverter Line 1',             (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 300, 310, 2),
('LINE-DE-LZ1', 'Leipzig Module Line 1 NMC',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_MOD'),  95, 100, 2),
('LINE-DE-LZ2', 'Leipzig Module Line 2 LFP',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_MOD'),  95,  98, 2),
('LINE-TX-BP1', 'Texas Battery Pack Line 1',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-US-TX'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_PACK'), 175, 180, 3),
('LINE-HU-BP1', 'Debrecen Battery Pack Line 1',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-HU-DE'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_PACK'), 190, 195, 2),
('LINE-MX-SM1', 'Monterrey Sub-Module Assembly',     (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-MX-MO'), (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_MOD'),  120, 125, 2);
