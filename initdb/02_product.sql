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
('BP-100-NMC', '100 kWh NMC Battery Pack',      (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 540.0,  8200.00, 12500.00, TRUE,  'MASS', '8507600090'),
('BP-075-LFP', '75 kWh LFP Battery Pack',        (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 420.0,  5800.00,  8900.00, TRUE,  'MASS', '8507600090'),
('BP-050-LFP', '50 kWh LFP Battery Pack (Std)',  (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 310.0,  4100.00,  6200.00, TRUE,  'MASS', '8507600090'),
('BP-120-NMC', '120 kWh NMC Battery Pack (Premium)', (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 620.0, 10500.00, 15800.00, TRUE, 'RAMP', '8507600090'),
-- 电池模组
('BM-NMC-12S', 'NMC Battery Module 12S4P',       (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  'PCS',  38.0,   520.00,   780.00, FALSE, 'MASS', '8507600090'),
('BM-LFP-16S', 'LFP Battery Module 16S2P',       (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  'PCS',  45.0,   380.00,   570.00, FALSE, 'MASS', '8507600090'),
-- 电芯
('CELL-NMC-21700', 'NMC 21700 Cylindrical Cell 5Ah',   (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),   'PCS',   0.07,    4.20,    6.50, FALSE, 'MASS', '8507600010'),
('CELL-LFP-280AH', 'LFP Prismatic Cell 280Ah',         (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),   'PCS',   0.63,    8.80,   13.20, FALSE, 'MASS', '8507600010'),
('CELL-NMC-4680',  'NMC 4680 Cylindrical Cell 23Ah',   (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),   'PCS',   0.36,   18.50,   28.00, FALSE, 'RAMP', '8507600010'),
-- BMS
('BMS-96S-PRO',  'BMS 96S High-Voltage Pro',          (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),    'PCS',   3.2,   320.00,   480.00, FALSE, 'MASS', '8537109900'),
('BMS-48S-STD',  'BMS 48S Standard',                  (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),    'PCS',   2.1,   185.00,   275.00, FALSE, 'MASS', '8537109900'),
-- 电机
('MTR-200KW-PMSM','200 kW PMSM Drive Motor',           (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),  'PCS',  68.0,  1850.00,  2800.00, TRUE,  'MASS', '8501532090'),
('MTR-150KW-PMSM','150 kW PMSM Drive Motor',           (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),  'PCS',  52.0,  1420.00,  2150.00, TRUE,  'MASS', '8501532090'),
('MTR-100KW-IM',  '100 kW Induction Motor',            (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),  'PCS',  58.0,   980.00,  1480.00, FALSE, 'MASS', '8501532090'),
-- 逆变器
('INV-200KW-SIC', '200 kW SiC Power Inverter',         (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'),'PCS', 12.5,   980.00,  1480.00, TRUE,  'MASS', '8504401990'),
('INV-150KW-IGBT','150 kW IGBT Inverter',               (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'),'PCS', 14.2,   720.00,  1080.00, TRUE,  'MASS', '8504401990'),
-- 减速器
('GBX-1SPD-180', 'Single-Speed Reducer 180 Nm',        (SELECT category_id FROM dim_component_category WHERE category_code='GEARBOX'), 'PCS',  18.0,   380.00,   570.00, FALSE, 'MASS', '8483409000'),
-- 热管理
('CHL-LIQUID-7L', 'Liquid Cooling Plate 7L Battery',   (SELECT category_id FROM dim_component_category WHERE category_code='COOLANT'), 'PCS',   4.5,   145.00,   220.00, FALSE, 'MASS', '8419899090'),
('HP-6KW-R290',   '6 kW Heat Pump R290',               (SELECT category_id FROM dim_component_category WHERE category_code='HEAT_PUMP'),'PCS', 14.0,   520.00,   780.00, TRUE,  'MASS', '8415819000'),
-- OBC / DCDC
('OBC-11KW-AC',   '11 kW AC On-Board Charger',         (SELECT category_id FROM dim_component_category WHERE category_code='OBC'),    'PCS',   4.8,   280.00,   420.00, TRUE,  'MASS', '8504401990'),
('DCDC-1500W-48', 'DC-DC Converter 1500W 48V',         (SELECT category_id FROM dim_component_category WHERE category_code='DCDC'),   'PCS',   1.9,   125.00,   188.00, FALSE, 'MASS', '8504401990'),
-- ECU
('VCU-EV-GEN4',   'Vehicle Control Unit Gen4',         (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),    'PCS',   0.8,   420.00,   630.00, FALSE, 'MASS', '8537109900'),
('MCU-MOTOR-V3',  'Motor Control Unit V3',              (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),    'PCS',   0.6,   185.00,   278.00, FALSE, 'MASS', '8537109900'),
-- 底盘结构
('FRAME-AL-FRONT','Front Aluminum Crash Frame',         (SELECT category_id FROM dim_component_category WHERE category_code='CHASSIS'),'PCS',  28.0,   180.00,   270.00, FALSE, 'MASS', '8302300000'),
('TRAY-BAT-AL',   'Battery Tray Aluminum Extrusion',   (SELECT category_id FROM dim_component_category WHERE category_code='CHASSIS'),'PCS',  22.0,   210.00,   315.00, FALSE, 'MASS', '7616999000');

INSERT INTO bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current) VALUES
('BOM-BP100-V2',  (SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), '2.0', '2023-01-01', TRUE),
('BOM-BP075-V2',  (SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), '2.0', '2023-01-01', TRUE),
('BOM-BP050-V1',  (SELECT component_id FROM dim_component WHERE component_code='BP-050-LFP'), '1.0', '2022-06-01', TRUE),
('BOM-BP120-V1',  (SELECT component_id FROM dim_component WHERE component_code='BP-120-NMC'), '1.0', '2024-01-01', TRUE),
('BOM-BM-NMC-V1', (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), '1.0', '2022-01-01', TRUE),
('BOM-BM-LFP-V1', (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'), '1.0', '2022-01-01', TRUE);

INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate) VALUES
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), 16, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='BMS-96S-PRO'),  1,  20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 2, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='VCU-EV-GEN4'),   1, 50, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'),  12, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='BMS-48S-STD'),   1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 2, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'),   8, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='BMS-48S-STD'),   1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 1, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), 20, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='BMS-96S-PRO'),  1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 3, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-NMC-V1'), (SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), 48, 10, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-NMC-V1'), (SELECT component_id FROM dim_component WHERE component_code='MCU-MOTOR-V3'),   1,  20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-LFP-V1'), (SELECT component_id FROM dim_component WHERE component_code='CELL-LFP-280AH'), 32, 10, 0.002);

INSERT INTO dim_raw_material (material_code, material_name, category, uom, commodity_ticker, primary_source_country_id) VALUES
('LCE',    'Lithium Carbonate Equivalent',   '锂',  'MT', 'LCE',    (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('NICKEL', 'Nickel (Class 1)',               '镍',  'MT', 'NI-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('COBALT', 'Cobalt Metal',                   '钴',  'MT', 'CO-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('COPPER', 'Copper Cathode',                 '铜',  'MT', 'CU-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('ALUM',   'Primary Aluminum',              '铝',  'MT', 'AL-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('SILICON','Silicon Metal 98%',              '硅',  'MT', 'SI-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('MANG',   'Manganese Metal',               '锰',  'MT', 'MN-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('IRON',   'Iron Ore 62% Fe',               '铁',  'MT', 'IO-DCE', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('RARE_E', 'Rare Earth Mixed Oxide (NdPr)', '稀土','MT', 'NDPR',   (SELECT country_id FROM geo.dim_country WHERE country_code='CN'));

INSERT INTO component_material_usage (component_id, material_id, usage_kg_per_unit) VALUES
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), (SELECT material_id FROM dim_raw_material WHERE material_code='LCE'),    0.0020),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), (SELECT material_id FROM dim_raw_material WHERE material_code='NICKEL'),  0.0180),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), (SELECT material_id FROM dim_raw_material WHERE material_code='COBALT'),  0.0040),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), (SELECT material_id FROM dim_raw_material WHERE material_code='COPPER'),  0.0060),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP-280AH'), (SELECT material_id FROM dim_raw_material WHERE material_code='LCE'),    0.0120),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP-280AH'), (SELECT material_id FROM dim_raw_material WHERE material_code='IRON'),   0.2500),
((SELECT component_id FROM dim_component WHERE component_code='CELL-LFP-280AH'), (SELECT material_id FROM dim_raw_material WHERE material_code='COPPER'),  0.0350),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-4680'),  (SELECT material_id FROM dim_raw_material WHERE material_code='LCE'),    0.0090),
((SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-4680'),  (SELECT material_id FROM dim_raw_material WHERE material_code='NICKEL'),  0.0780),
((SELECT component_id FROM dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT material_id FROM dim_raw_material WHERE material_code='RARE_E'), 1.2000),
((SELECT component_id FROM dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT material_id FROM dim_raw_material WHERE material_code='COPPER'),  8.5000),
((SELECT component_id FROM dim_component WHERE component_code='MTR-150KW-PMSM'), (SELECT material_id FROM dim_raw_material WHERE material_code='RARE_E'), 0.9000),
((SELECT component_id FROM dim_component WHERE component_code='MTR-150KW-PMSM'), (SELECT material_id FROM dim_raw_material WHERE material_code='COPPER'),  6.8000),
((SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),    (SELECT material_id FROM dim_raw_material WHERE material_code='ALUM'),   18.0000),
((SELECT component_id FROM dim_component WHERE component_code='FRAME-AL-FRONT'), (SELECT material_id FROM dim_raw_material WHERE material_code='ALUM'),   22.0000);
