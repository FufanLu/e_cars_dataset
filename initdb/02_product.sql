-- =============================================================================
-- EV Parts Lakehouse - product schema: 产品 / BOM / 原材料
-- PostgreSQL 16
-- =============================================================================

SET search_path TO product, geo, public;

-- =============================================================================
-- DDL
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
    uom                 VARCHAR(10)   NOT NULL DEFAULT 'PCS',
    weight_kg           NUMERIC(10,4),
    standard_cost_usd   NUMERIC(14,4) NOT NULL,
    list_price_usd      NUMERIC(14,4),
    is_finished_good    BOOLEAN       NOT NULL DEFAULT FALSE,
    is_active           BOOLEAN       NOT NULL DEFAULT TRUE,
    lifecycle_stage     VARCHAR(20)   CHECK (lifecycle_stage IN ('NPI','RAMP','MASS','EOL')),
    hs_code             VARCHAR(20),
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
    scrap_rate          NUMERIC(6,4)  NOT NULL DEFAULT 0,
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
    category        VARCHAR(50),
    uom             VARCHAR(10)  NOT NULL DEFAULT 'MT',
    commodity_ticker VARCHAR(20),
    primary_source_country_id INT REFERENCES geo.dim_country(country_id),
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
    price_source    VARCHAR(50),
    UNIQUE (material_id, price_date)
);
COMMENT ON TABLE  fact_raw_material_price_daily IS '原材料每日现货价格（USD/公吨）';
CREATE INDEX idx_rmp_material_date ON fact_raw_material_price_daily(material_id, price_date DESC);

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_component_category (category_code, category_name, parent_id, level) VALUES
('BAT_SYS',   'Battery System',              NULL,                                                                 1),
('DRIVE_SYS',  'Drive System',               NULL,                                                                 1),
('THERM_SYS',  'Thermal Management System',  NULL,                                                                 1),
('ELEC_SYS',   'Electronic & Control System',NULL,                                                                 1),
('STRUC',      'Structural Components',       NULL,                                                                 1),
('BAT_PACK',   'Battery Pack Assembly',       (SELECT category_id FROM dim_component_category WHERE category_code='BAT_SYS'),  2),
('BAT_MOD',    'Battery Module',              (SELECT category_id FROM dim_component_category WHERE category_code='BAT_SYS'),  2),
('CELL',       'Battery Cell',                (SELECT category_id FROM dim_component_category WHERE category_code='BAT_SYS'),  2),
('BMS',        'Battery Management System',  (SELECT category_id FROM dim_component_category WHERE category_code='BAT_SYS'),  2),
('MOTOR',      'Electric Motor',             (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE_SYS'), 2),
('INVERTER',   'Power Inverter',             (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE_SYS'), 2),
('GEARBOX',    'Reducer / Gearbox',          (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE_SYS'), 2),
('COOLANT',    'Cooling System',             (SELECT category_id FROM dim_component_category WHERE category_code='THERM_SYS'), 2),
('HEAT_PUMP',  'Heat Pump',                  (SELECT category_id FROM dim_component_category WHERE category_code='THERM_SYS'), 2),
('OBC',        'On-Board Charger',           (SELECT category_id FROM dim_component_category WHERE category_code='ELEC_SYS'),  2),
('DCDC',       'DC-DC Converter',            (SELECT category_id FROM dim_component_category WHERE category_code='ELEC_SYS'),  2),
('ECU',        'Electronic Control Unit',    (SELECT category_id FROM dim_component_category WHERE category_code='ELEC_SYS'),  2),
('CHASSIS',    'Chassis / Frame',            (SELECT category_id FROM dim_component_category WHERE category_code='STRUC'),     2);

INSERT INTO dim_component (component_code, component_name, category_id, uom, weight_kg, standard_cost_usd, list_price_usd, is_finished_good, lifecycle_stage, hs_code) VALUES
-- 电池系统成品
('BAT-100KWH',  '100kWh Battery Pack',       (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'),  'PCS', 520.00, 8500.00, 12500.00, TRUE,  'MASS', '8507.60'),
('BAT-75KWH',   '75kWh Battery Pack',         (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'),  'PCS', 400.00, 6500.00, 9500.00,  TRUE,  'MASS', '8507.60'),
('BAT-50KWH',   '50kWh Battery Pack',         (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'),  'PCS', 280.00, 4500.00, 6800.00,  TRUE,  'MASS', '8507.60'),
-- 电池模组/电芯
('BAT-MOD-LFP', 'LFP Battery Module 12S2P',  (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),   'PCS', 28.00,  720.00,  1050.00,  FALSE, 'MASS', '8507.90'),
('BAT-MOD-NCM', 'NCM 811 Battery Module',    (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),   'PCS', 25.00,  880.00,  1280.00,  FALSE, 'MASS', '8507.90'),
('CELL-LFP',    'LFP Prismatic Cell 200Ah',  (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),      'PCS', 3.80,   45.00,   68.00,    FALSE, 'MASS', '8507.60'),
('CELL-NCM',    'NCM 811 Cylindrical 5Ah',   (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),      'PCS', 0.07,   3.20,    5.50,     FALSE, 'MASS', '8507.60'),
-- BMS
('BMS-MASTER',  'BMS Master Controller',     (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),       'PCS', 1.50,   185.00,  280.00,   FALSE, 'MASS', '9032.89'),
('BMS-SLAVE',   'BMS Slave Module 12CH',     (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),       'PCS', 0.60,   72.00,   110.00,   FALSE, 'MASS', '9032.89'),
-- 驱动系统
('MOTOR-PM200', '200kW PMSM Drive Motor',    (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),     'PCS', 72.00,  1850.00, 2800.00,  FALSE, 'MASS', '8501.32'),
('MOTOR-PM120', '120kW PMSM Drive Motor',    (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),     'PCS', 52.00,  1350.00, 2050.00,  FALSE, 'MASS', '8501.32'),
('INV-SIC800',  '800V SiC Inverter 250kW',   (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'),  'PCS', 18.00,  1100.00, 1750.00,  FALSE, 'MASS', '8504.40'),
('INV-SIC400',  '400V SiC Inverter 150kW',   (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'),  'PCS', 14.00,  820.00,  1280.00,  FALSE, 'MASS', '8504.40'),
('GBX-2SPD',    '2-Speed Reducer Gearbox',   (SELECT category_id FROM dim_component_category WHERE category_code='GEARBOX'),   'PCS', 35.00,  420.00,  650.00,   FALSE, 'MASS', '8483.40'),
-- 热管理
('COOL-BATT',   'Battery Liquid Cooling Sys',(SELECT category_id FROM dim_component_category WHERE category_code='COOLANT'),   'PCS', 12.00,  280.00,  430.00,   FALSE, 'MASS', '8418.69'),
('HEATPUMP-R134','R134a Heat Pump System',   (SELECT category_id FROM dim_component_category WHERE category_code='HEAT_PUMP'), 'PCS', 8.50,   350.00,  540.00,   FALSE, 'MASS', '8418.61'),
-- 电子控制
('OBC-11KW',    '11kW On-Board Charger',     (SELECT category_id FROM dim_component_category WHERE category_code='OBC'),       'PCS', 8.00,   310.00,  480.00,   FALSE, 'MASS', '8504.40'),
('DCDC-3KW',    '3kW DC-DC Converter',       (SELECT category_id FROM dim_component_category WHERE category_code='DCDC'),      'PCS', 3.50,   145.00,  225.00,   FALSE, 'MASS', '8504.40'),
('ECU-MAIN',    'Vehicle Main ECU',          (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),       'PCS', 1.20,   210.00,  340.00,   FALSE, 'MASS', '9032.89'),
-- 结构
('CHAS-AL-SUV', 'Aluminum SUV Chassis',      (SELECT category_id FROM dim_component_category WHERE category_code='CHASSIS'),   'PCS', 320.00, 2200.00, 3500.00,  FALSE, 'MASS', '8708.29'),
-- 成品总成（组合件，标记为 finished good）
('EDU-200KW',   '200kW eDrive Unit (Motor+Inverter+Gearbox)', (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE_SYS'), 'PCS', 125.00, 3400.00, 5200.00, TRUE, 'MASS', '8501.32');

INSERT INTO bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current, created_by) VALUES
('BOM-BAT100',   (SELECT component_id FROM dim_component WHERE component_code='BAT-100KWH'), '1.0', '2024-01-01', TRUE, 'ENG'),
('BOM-EDU200',   (SELECT component_id FROM dim_component WHERE component_code='EDU-200KW'),  '1.0', '2024-01-01', TRUE, 'ENG'),
('BOM-MOD-LFP',  (SELECT component_id FROM dim_component WHERE component_code='BAT-MOD-LFP'),'1.0', '2024-01-01', TRUE, 'ENG'),
('BOM-MOD-NCM',  (SELECT component_id FROM dim_component WHERE component_code='BAT-MOD-NCM'),'1.0', '2024-01-01', TRUE, 'ENG');

INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, scrap_rate) VALUES
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BAT100'),  (SELECT component_id FROM dim_component WHERE component_code='BAT-MOD-LFP'), 20, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BAT100'),  (SELECT component_id FROM dim_component WHERE component_code='BMS-MASTER'),  1,  0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BAT100'),  (SELECT component_id FROM dim_component WHERE component_code='BMS-SLAVE'),   16, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BAT100'),  (SELECT component_id FROM dim_component WHERE component_code='COOL-BATT'),   1,  0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-EDU200'),  (SELECT component_id FROM dim_component WHERE component_code='MOTOR-PM200'), 1,  0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-EDU200'),  (SELECT component_id FROM dim_component WHERE component_code='INV-SIC800'),  1,  0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-EDU200'),  (SELECT component_id FROM dim_component WHERE component_code='GBX-2SPD'),    1,  0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-MOD-LFP'), (SELECT component_id FROM dim_component WHERE component_code='CELL-LFP'),   24, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-MOD-NCM'), (SELECT component_id FROM dim_component WHERE component_code='CELL-NCM'),   240,0.003);

INSERT INTO dim_raw_material (material_code, material_name, category, uom, commodity_ticker, primary_source_country_id) VALUES
('MAT-LI2CO3',  'Lithium Carbonate 99.5%',    'Lithium',    'MT', 'LIT-CN',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-LIOH',    'Lithium Hydroxide 56.5%',    'Lithium',    'MT', 'LIOH-CN', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-NI',      'Nickel Briquette 99.8%',     'Nickel',     'MT', 'NI-LME',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-CO',      'Cobalt Metal 99.8%',         'Cobalt',     'MT', 'CO-LME',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-MN',      'Manganese Flake 99.7%',      'Manganese',  'MT', 'MN-CN',   (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-CU',      'Copper Cathode 99.99%',      'Copper',     'MT', 'CU-LME',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-AL',      'Aluminum Ingot 99.7%',       'Aluminum',   'MT', 'AL-LME',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-GRAPH',   'Spherical Graphite 99.95%',  'Graphite',   'MT', 'GPH-CN',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MAT-ND',      'Neodymium Oxide 99.5%',      'Rare Earth', 'MT', 'ND-CN',   (SELECT country_id FROM geo.dim_country WHERE country_code='CN'));

INSERT INTO component_material_usage (component_id, material_id, usage_kg_per_unit) VALUES
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-LI2CO3'), 0.65),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-CU'),     0.15),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-AL'),     0.30),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-GRAPH'),  0.80),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NCM'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-LIOH'),   0.12),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NCM'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-NI'),     0.04),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NCM'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-CO'),     0.02),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NCM'),  (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-MN'),     0.01),
((SELECT component_id FROM dim_component WHERE component_code='MOTOR-PM200'), (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-ND'),   1.80),
((SELECT component_id FROM dim_component WHERE component_code='MOTOR-PM200'), (SELECT material_id FROM dim_raw_material WHERE material_code='MAT-CU'),   8.50);
