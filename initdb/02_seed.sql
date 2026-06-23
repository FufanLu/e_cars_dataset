-- =============================================================================
-- EV Parts Lakehouse - Seed Data
-- PostgreSQL 16 / Pure SQL / No external scripts
-- =============================================================================

SET client_encoding = 'UTF8';

-- =============================================================================
-- DOMAIN I: 地区 / 币种 / 国家
-- =============================================================================

INSERT INTO dim_region (region_code, region_name) VALUES
('APAC',  'Asia Pacific'),
('EMEA',  'Europe Middle East Africa'),
('AMER',  'Americas'),
('CHINA', 'Greater China');

INSERT INTO dim_currency (currency_code, currency_name, symbol, decimal_places) VALUES
('USD', 'US Dollar',          '$',  2),
('EUR', 'Euro',               '€',  2),
('CNY', 'Chinese Yuan',       '¥',  2),
('GBP', 'British Pound',      '£',  2),
('JPY', 'Japanese Yen',       '¥',  0),
('KRW', 'South Korean Won',   '₩',  0),
('MXN', 'Mexican Peso',       '$',  2),
('INR', 'Indian Rupee',       '₹',  2),
('THB', 'Thai Baht',          '฿',  2),
('BRL', 'Brazilian Real',     'R$', 2),
('HUF', 'Hungarian Forint',   'Ft', 2),
('PLN', 'Polish Zloty',       'zł', 2),
('MYR', 'Malaysian Ringgit',  'RM', 2),
('VND', 'Vietnamese Dong',    '₫',  0),
('SGD', 'Singapore Dollar',   'S$', 2);

-- 先插入国家，需要 currency_id 和 region_id
INSERT INTO dim_country (country_code, country_name, region_id, currency_id, vat_rate, corporate_tax_rate, is_eu_member) VALUES
('CN', 'China',          (SELECT region_id FROM dim_region WHERE region_code='CHINA'), (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), 0.1300, 0.2500, FALSE),
('DE', 'Germany',        (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 0.1900, 0.2998, TRUE),
('US', 'United States',  (SELECT region_id FROM dim_region WHERE region_code='AMER'),  (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 0.0000, 0.2100, FALSE),
('JP', 'Japan',          (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), 0.1000, 0.2374, FALSE),
('KR', 'South Korea',    (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='KRW'), 0.1000, 0.2200, FALSE),
('MX', 'Mexico',         (SELECT region_id FROM dim_region WHERE region_code='AMER'),  (SELECT currency_id FROM dim_currency WHERE currency_code='MXN'), 0.1600, 0.3000, FALSE),
('IN', 'India',          (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='INR'), 0.1800, 0.2500, FALSE),
('TH', 'Thailand',       (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='THB'), 0.0700, 0.2000, FALSE),
('GB', 'United Kingdom', (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='GBP'), 0.2000, 0.2500, FALSE),
('FR', 'France',         (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 0.2000, 0.2500, TRUE),
('HU', 'Hungary',        (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='HUF'), 0.2700, 0.0900, TRUE),
('PL', 'Poland',         (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='PLN'), 0.2300, 0.1900, TRUE),
('BR', 'Brazil',         (SELECT region_id FROM dim_region WHERE region_code='AMER'),  (SELECT currency_id FROM dim_currency WHERE currency_code='BRL'), 0.1200, 0.3400, FALSE),
('MY', 'Malaysia',       (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='MYR'), 0.0800, 0.2400, FALSE),
('VN', 'Vietnam',        (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='VND'), 0.1000, 0.2000, FALSE),
('SG', 'Singapore',      (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='SGD'), 0.0900, 0.1700, FALSE);

-- =============================================================================
-- DOMAIN II: 零部件品类 / 零部件 / BOM / 原材料
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

-- 零部件主数据（含成品、半成品、子零件）
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

-- BOM 头（当前版本）
INSERT INTO bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current) VALUES
('BOM-BP100-V2',  (SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), '2.0', '2023-01-01', TRUE),
('BOM-BP075-V2',  (SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), '2.0', '2023-01-01', TRUE),
('BOM-BP050-V1',  (SELECT component_id FROM dim_component WHERE component_code='BP-050-LFP'), '1.0', '2022-06-01', TRUE),
('BOM-BP120-V1',  (SELECT component_id FROM dim_component WHERE component_code='BP-120-NMC'), '1.0', '2024-01-01', TRUE),
('BOM-BM-NMC-V1', (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), '1.0', '2022-01-01', TRUE),
('BOM-BM-LFP-V1', (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'), '1.0', '2022-01-01', TRUE);

-- BOM 明细
-- BP-100-NMC: 包含 16 个 NMC 模组 + BMS + 冷却板 + 托盘 + 结构件
INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate) VALUES
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), 16, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='BMS-96S-PRO'),  1,  20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 2, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP100-V2'), (SELECT component_id FROM dim_component WHERE component_code='VCU-EV-GEN4'),   1, 50, 0.001),
-- BP-075-LFP
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'),  12, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='BMS-48S-STD'),   1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 2, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP075-V2'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
-- BP-050-LFP
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='BM-LFP-16S'),   8, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='BMS-48S-STD'),   1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP050-V1'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 1, 30, 0.003),
-- BP-120-NMC (Premium)
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='BM-NMC-12S'), 20, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='BMS-96S-PRO'),  1, 20, 0.001),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='CHL-LIQUID-7L'), 3, 30, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BP120-V1'), (SELECT component_id FROM dim_component WHERE component_code='TRAY-BAT-AL'),   1, 40, 0.002),
-- BM-NMC-12S: 48 个 21700 电芯
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-NMC-V1'), (SELECT component_id FROM dim_component WHERE component_code='CELL-NMC-21700'), 48, 10, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-NMC-V1'), (SELECT component_id FROM dim_component WHERE component_code='MCU-MOTOR-V3'),   1,  20, 0.001),
-- BM-LFP-16S: 32 个 LFP 电芯
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-BM-LFP-V1'), (SELECT component_id FROM dim_component WHERE component_code='CELL-LFP-280AH'), 32, 10, 0.002);

-- 原材料
INSERT INTO dim_raw_material (material_code, material_name, category, uom, commodity_ticker, primary_source_country_id) VALUES
('LCE',    'Lithium Carbonate Equivalent',   '锂',  'MT', 'LCE',    (SELECT country_id FROM dim_country WHERE country_code='CN')),
('NICKEL', 'Nickel (Class 1)',               '镍',  'MT', 'NI-LME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('COBALT', 'Cobalt Metal',                   '钴',  'MT', 'CO-LME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('COPPER', 'Copper Cathode',                 '铜',  'MT', 'CU-LME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('ALUM',   'Primary Aluminum',              '铝',  'MT', 'AL-LME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('SILICON','Silicon Metal 98%',              '硅',  'MT', 'SI-CME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('MANG',   'Manganese Metal',               '锰',  'MT', 'MN-CME', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('IRON',   'Iron Ore 62% Fe',               '铁',  'MT', 'IO-DCE', (SELECT country_id FROM dim_country WHERE country_code='CN')),
('RARE_E', 'Rare Earth Mixed Oxide (NdPr)', '稀土','MT', 'NDPR',   (SELECT country_id FROM dim_country WHERE country_code='CN'));

-- 零部件原材料用量折算
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

-- =============================================================================
-- DOMAIN III: 工厂 / 生产线
-- =============================================================================

INSERT INTO dim_factory (factory_code, factory_name, country_id, city, annual_capacity, headcount, iso_certified, iatf_certified, opened_date) VALUES
('FAC-CN-SH', 'Shanghai Battery Assembly Plant',     (SELECT country_id FROM dim_country WHERE country_code='CN'), 'Shanghai',  200000, 3200, TRUE, TRUE,  '2018-03-01'),
('FAC-CN-WH', 'Wuhan Motor & Drive System Plant',    (SELECT country_id FROM dim_country WHERE country_code='CN'), 'Wuhan',     120000, 2100, TRUE, TRUE,  '2019-06-01'),
('FAC-CN-CQ', 'Chongqing Component Manufacturing',  (SELECT country_id FROM dim_country WHERE country_code='CN'), 'Chongqing',  80000, 1400, TRUE, FALSE, '2020-09-01'),
('FAC-DE-LZ', 'Leipzig Battery Module Plant',        (SELECT country_id FROM dim_country WHERE country_code='DE'), 'Leipzig',    80000, 1800, TRUE, TRUE,  '2020-01-01'),
('FAC-DE-MU', 'Munich R&D & Low-Volume Assembly',   (SELECT country_id FROM dim_country WHERE country_code='DE'), 'Munich',     20000,  850, TRUE, TRUE,  '2017-05-01'),
('FAC-US-TX', 'Texas Gigafactory',                  (SELECT country_id FROM dim_country WHERE country_code='US'), 'Austin TX', 150000, 2800, TRUE, TRUE,  '2022-04-01'),
('FAC-US-OH', 'Ohio Drive Unit Plant',               (SELECT country_id FROM dim_country WHERE country_code='US'), 'Columbus OH', 60000, 1200, TRUE, FALSE, '2021-07-01'),
('FAC-HU-DE', 'Debrecen Battery Pack Plant',         (SELECT country_id FROM dim_country WHERE country_code='HU'), 'Debrecen',   60000, 1600, TRUE, TRUE,  '2023-02-01'),
('FAC-MX-MO', 'Monterrey Sub-Assembly Plant',        (SELECT country_id FROM dim_country WHERE country_code='MX'), 'Monterrey',  40000,  900, TRUE, FALSE, '2021-11-01'),
('FAC-TH-AM', 'Amata City EV Components Plant',      (SELECT country_id FROM dim_country WHERE country_code='TH'), 'Amata City', 30000,  750, TRUE, FALSE, '2022-08-01');

INSERT INTO dim_production_line (line_code, line_name, factory_id, primary_category_id, designed_takt_sec, current_takt_sec, shift_count) VALUES
('LINE-SH-BP1', 'Shanghai Battery Pack Line 1',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 180, 185, 3),
('LINE-SH-BP2', 'Shanghai Battery Pack Line 2',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 180, 190, 3),
('LINE-SH-BM1', 'Shanghai Module Assembly Line 1',   (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  90,  92, 3),
('LINE-WH-MT1', 'Wuhan Motor Line 1 PMSM',           (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),   240, 245, 2),
('LINE-WH-IV1', 'Wuhan Inverter Line 1',             (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 300, 310, 2),
('LINE-DE-LZ1', 'Leipzig Module Line 1 NMC',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  95, 100, 2),
('LINE-DE-LZ2', 'Leipzig Module Line 2 LFP',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  95,  98, 2),
('LINE-TX-BP1', 'Texas Battery Pack Line 1',         (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-US-TX'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 175, 180, 3),
('LINE-HU-BP1', 'Debrecen Battery Pack Line 1',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-HU-DE'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 190, 195, 2),
('LINE-MX-SM1', 'Monterrey Sub-Module Assembly',     (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-MX-MO'), (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'),  120, 125, 2);

-- =============================================================================
-- DOMAIN IV: 供应商
-- =============================================================================

INSERT INTO dim_supplier (supplier_code, supplier_name, country_id, tier, category_id, payment_terms_days, currency_id, is_strategic, risk_rating) VALUES
('SUP-CATL-CN',  'CATL (Contemporary Amperex)',    (SELECT country_id FROM dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),    60, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), TRUE,  'LOW'),
('SUP-BYD-CN',   'BYD Component Supply',           (SELECT country_id FROM dim_country WHERE country_code='CN'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='BAT_MOD'), 60, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), TRUE,  'LOW'),
('SUP-PANASONIC-JP','Panasonic Energy',             (SELECT country_id FROM dim_country WHERE country_code='JP'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), TRUE,  'LOW'),
('SUP-SAMSUNG-KR','Samsung SDI',                   (SELECT country_id FROM dim_country WHERE country_code='KR'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM dim_currency WHERE currency_code='KRW'), TRUE,  'LOW'),
('SUP-LGE-KR',   'LG Energy Solution',             (SELECT country_id FROM dim_country WHERE country_code='KR'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),    45, (SELECT currency_id FROM dim_currency WHERE currency_code='KRW'), TRUE,  'LOW'),
('SUP-ROHM-JP',  'Rohm Semiconductor',             (SELECT country_id FROM dim_country WHERE country_code='JP'), 2, (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 60, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), FALSE, 'LOW'),
('SUP-INF-DE',   'Infineon Technologies',          (SELECT country_id FROM dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE,  'LOW'),
('SUP-BOSCH-DE', 'Bosch EV Components',            (SELECT country_id FROM dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),     45, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE,  'LOW'),
('SUP-NIDEC-JP', 'Nidec Motor Corporation',        (SELECT country_id FROM dim_country WHERE country_code='JP'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),   60, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), FALSE, 'MEDIUM'),
('SUP-ALUM-CN',  'Novelis China Aluminum',         (SELECT country_id FROM dim_country WHERE country_code='CN'), 2, (SELECT category_id FROM dim_component_category WHERE category_code='CHASSIS'),  90, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), FALSE, 'LOW'),
('SUP-COPPER-CN','Jiangxi Copper Co.',              (SELECT country_id FROM dim_country WHERE country_code='CN'), 2, NULL, 90, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), FALSE, 'LOW'),
('SUP-RARE-CN',  'China Northern Rare Earth',      (SELECT country_id FROM dim_country WHERE country_code='CN'), 1, NULL, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), TRUE,  'HIGH'),
('SUP-CONT-DE',  'Continental EV Systems',         (SELECT country_id FROM dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),     45, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), FALSE, 'LOW'),
('SUP-SENATA-MX','Sensata Technologies Mexico',    (SELECT country_id FROM dim_country WHERE country_code='MX'), 2, NULL, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='MXN'), FALSE, 'MEDIUM'),
('SUP-UNIPRESS-IN','Unipress India Stampings',     (SELECT country_id FROM dim_country WHERE country_code='IN'), 2, (SELECT category_id FROM dim_component_category WHERE category_code='CHASSIS'),  90, (SELECT currency_id FROM dim_currency WHERE currency_code='INR'), FALSE, 'MEDIUM'),
('SUP-VIET-WIRE','Vietnam Wiring Harness Co.',     (SELECT country_id FROM dim_country WHERE country_code='VN'), 2, NULL, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='VND'), FALSE, 'MEDIUM'),
('SUP-LIVENT-US','Livent Lithium USA',             (SELECT country_id FROM dim_country WHERE country_code='US'), 1, NULL, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), TRUE,  'MEDIUM'),
('SUP-VALE-BR',  'Vale Nickel Brazil',             (SELECT country_id FROM dim_country WHERE country_code='BR'), 1, NULL, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), FALSE, 'HIGH'),
('SUP-GLENCORE', 'Glencore Cobalt Supply',         (SELECT country_id FROM dim_country WHERE country_code='GB'), 1, NULL, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), TRUE,  'HIGH'),
('SUP-UMICORE-DE','Umicore Battery Materials',     (SELECT country_id FROM dim_country WHERE country_code='DE'), 1, (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),    60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE,  'LOW');

-- =============================================================================
-- DOMAIN V: 客户 / 销售渠道
-- =============================================================================

INSERT INTO dim_sales_channel (channel_code, channel_name, channel_type, commission_rate) VALUES
('DIR-OEM',   'Direct OEM Sales',        'DIRECT',       0.0000),
('DIR-T1',    'Direct Tier-1 Supply',    'DIRECT',       0.0000),
('DIST-EMEA', 'EMEA Distribution',       'DISTRIBUTION', 0.0250),
('DIST-APAC', 'APAC Distribution',       'DISTRIBUTION', 0.0300),
('DIST-AMER', 'Americas Distribution',   'DISTRIBUTION', 0.0275),
('GOV-FLEET', 'Government Fleet Tender', 'GOVT_TENDER',  0.0000),
('ONLINE-B2B','B2B Online Portal',       'ONLINE',       0.0150),
('AFTERSVC',  'After-Sales & Service',   'DIRECT',       0.0000);

INSERT INTO dim_customer (customer_code, customer_name, country_id, customer_type, credit_limit_usd, payment_terms_days, currency_id, is_strategic) VALUES
('CUST-VW-DE',    'Volkswagen Group',            (SELECT country_id FROM dim_country WHERE country_code='DE'), 'OEM',         50000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-BMW-DE',   'BMW Group',                   (SELECT country_id FROM dim_country WHERE country_code='DE'), 'OEM',         40000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-STELLANT', 'Stellantis EV Procurement',   (SELECT country_id FROM dim_country WHERE country_code='FR'), 'OEM',         35000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-FORD-US',  'Ford Motor Company',           (SELECT country_id FROM dim_country WHERE country_code='US'), 'OEM',         30000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), TRUE),
('CUST-GM-US',    'General Motors EV',            (SELECT country_id FROM dim_country WHERE country_code='US'), 'OEM',         30000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), TRUE),
('CUST-HONDA-JP', 'Honda Motor Co.',              (SELECT country_id FROM dim_country WHERE country_code='JP'), 'OEM',         25000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), TRUE),
('CUST-HYUNDAI',  'Hyundai Motor Group',          (SELECT country_id FROM dim_country WHERE country_code='KR'), 'OEM',         28000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='KRW'), TRUE),
('CUST-TATA-IN',  'Tata Motors EV',               (SELECT country_id FROM dim_country WHERE country_code='IN'), 'OEM',         10000000, 90, (SELECT currency_id FROM dim_currency WHERE currency_code='INR'), FALSE),
('CUST-RENAULT',  'Renault EV Division',          (SELECT country_id FROM dim_country WHERE country_code='FR'), 'OEM',         15000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-LEAPMOTOR','Leapmotor Technology',          (SELECT country_id FROM dim_country WHERE country_code='CN'), 'OEM',         12000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), FALSE),
('CUST-ZEEKR-CN', 'Zeekr Intelligent Tech',       (SELECT country_id FROM dim_country WHERE country_code='CN'), 'OEM',         20000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), TRUE),
('CUST-MAGNA-CA', 'Magna International',           (SELECT country_id FROM dim_country WHERE country_code='US'), 'TIER1',       8000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), FALSE),
('CUST-DENSO-JP', 'Denso Corporation',             (SELECT country_id FROM dim_country WHERE country_code='JP'), 'TIER1',       9000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), FALSE),
('CUST-DIST-SG',  'EV Parts Asia Distribution',   (SELECT country_id FROM dim_country WHERE country_code='SG'), 'DISTRIBUTOR', 5000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), FALSE),
('CUST-DIST-GB',  'European EV Components Ltd',   (SELECT country_id FROM dim_country WHERE country_code='GB'), 'DISTRIBUTOR', 4000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='GBP'), FALSE),
('CUST-GOVT-DE',  'German Federal Procurement',   (SELECT country_id FROM dim_country WHERE country_code='DE'), 'GOVT',        6000000, 90, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-GOVT-US',  'US DOE / Federal Fleet',        (SELECT country_id FROM dim_country WHERE country_code='US'), 'GOVT',        8000000, 90, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), FALSE),
('CUST-TOYOTA-JP','Toyota Motor Corporation',      (SELECT country_id FROM dim_country WHERE country_code='JP'), 'OEM',         35000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), TRUE),
('CUST-VOLVO-SE', 'Volvo Cars EV',                 (SELECT country_id FROM dim_country WHERE country_code='DE'), 'OEM',         18000000, 60, (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-RIVIAN-US','Rivian Automotive',             (SELECT country_id FROM dim_country WHERE country_code='US'), 'OEM',         15000000, 45, (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), FALSE);

-- =============================================================================
-- DOMAIN VI: 仓库
-- =============================================================================

INSERT INTO dim_warehouse (warehouse_code, warehouse_name, factory_id, country_id, warehouse_type, capacity_sqm) VALUES
('WH-SH-RM', 'Shanghai Raw Material Store',     (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT country_id FROM dim_country WHERE country_code='CN'), 'RAW',     8000),
('WH-SH-FG', 'Shanghai Finished Goods DC',      (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT country_id FROM dim_country WHERE country_code='CN'), 'FG',     15000),
('WH-WH-RM', 'Wuhan Raw Material Store',        (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT country_id FROM dim_country WHERE country_code='CN'), 'RAW',     5000),
('WH-WH-FG', 'Wuhan FG Warehouse',              (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT country_id FROM dim_country WHERE country_code='CN'), 'FG',      6000),
('WH-DE-LZ', 'Leipzig Finished Goods',          (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT country_id FROM dim_country WHERE country_code='DE'), 'FG',      9000),
('WH-US-TX', 'Texas Distribution Center',       (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-US-TX'), (SELECT country_id FROM dim_country WHERE country_code='US'), 'FG',     12000),
('WH-HU-BP', 'Debrecen FG Warehouse',           (SELECT factory_id FROM dim_factory WHERE factory_code='FAC-HU-DE'), (SELECT country_id FROM dim_country WHERE country_code='HU'), 'FG',      7000),
('WH-SG-3PL','Singapore 3PL Hub',               NULL,                                                                 (SELECT country_id FROM dim_country WHERE country_code='SG'), '3PL',     4000),
('WH-US-NJ', 'New Jersey East Coast DC',        NULL,                                                                 (SELECT country_id FROM dim_country WHERE country_code='US'), '3PL',     6000),
('WH-DE-FR', 'Frankfurt Regional DC',           NULL,                                                                 (SELECT country_id FROM dim_country WHERE country_code='DE'), '3PL',     5000);

-- =============================================================================
-- DOMAIN IX: 碳排放范围
-- =============================================================================

INSERT INTO dim_emission_scope (scope_code, scope_name, description) VALUES
('S1', 'Scope 1', 'Direct GHG emissions from owned/controlled sources (fuel combustion, process emissions)'),
('S2', 'Scope 2', 'Indirect GHG from purchased electricity, steam, heat, and cooling'),
('S3', 'Scope 3', 'All other indirect emissions in value chain (upstream materials, logistics, use-phase, EoL)');

-- =============================================================================
-- DOMAIN X: 故障模式
-- =============================================================================

INSERT INTO dim_failure_mode (failure_code, failure_name, component_category_id, severity, avg_repair_cost_usd) VALUES
('FM-CELL-DENDRITE', 'Lithium Dendrite Penetration / Internal Short',     (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),     'CRITICAL', 8500),
('FM-CELL-CAPACITY',  'Abnormal Capacity Fade (>20% in 3y)',              (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),     'MAJOR',    3200),
('FM-CELL-THERMAL',   'Thermal Runaway Event',                             (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),     'CRITICAL', 15000),
('FM-BMS-SOC-ERR',    'BMS State-of-Charge Estimation Error >5%',         (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),      'MAJOR',    1200),
('FM-BMS-BALANCING',  'BMS Cell Balancing Circuit Failure',                (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),      'MAJOR',    1800),
('FM-MTR-DEMAGNET',   'PMSM Permanent Magnet Demagnetization',             (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),    'CRITICAL', 3800),
('FM-MTR-BEARING',    'Motor Bearing Premature Failure',                    (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),    'MAJOR',    950),
('FM-INV-IGBT-FAIL',  'IGBT Module Open/Short Circuit Failure',            (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 'CRITICAL', 2200),
('FM-INV-OVERHEAT',   'Inverter Overtemperature Shutdown',                  (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 'MAJOR',    480),
('FM-OBC-CHARGE-FAIL','OBC Charging Failure / Contactor Weld',             (SELECT category_id FROM dim_component_category WHERE category_code='OBC'),      'MAJOR',    750),
('FM-COOL-LEAK',      'Coolant Leak at Fitting / Plate',                   (SELECT category_id FROM dim_component_category WHERE category_code='COOLANT'),  'MAJOR',    620),
('FM-ECU-CAN-FAIL',   'CAN Bus Communication Loss / ECU Reset',            (SELECT category_id FROM dim_component_category WHERE category_code='ECU'),      'MINOR',    380);

-- =============================================================================
-- 国家价格表（重要成品，多国多币种）
-- =============================================================================

INSERT INTO fact_country_price_list (component_id, country_id, currency_id, list_price, effective_from, is_current) VALUES
-- BP-100-NMC 各国价格（刻意制造价格倒挂场景）
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='CN'), (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), 80000,  '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='DE'), (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 11200,  '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='US'), (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 11800,  '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='JP'), (SELECT currency_id FROM dim_currency WHERE currency_code='JPY'), 1650000,'2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='GB'), (SELECT currency_id FROM dim_currency WHERE currency_code='GBP'), 9500,   '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM dim_country WHERE country_code='IN'), (SELECT currency_id FROM dim_currency WHERE currency_code='INR'), 990000, '2024-01-01', TRUE),
-- BP-075-LFP
((SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM dim_country WHERE country_code='CN'), (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), 57000,  '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM dim_country WHERE country_code='DE'), (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 7800,   '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM dim_country WHERE country_code='US'), (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 8200,   '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM dim_country WHERE country_code='IN'), (SELECT currency_id FROM dim_currency WHERE currency_code='INR'), 680000, '2024-01-01', TRUE),
-- MTR-200KW-PMSM
((SELECT component_id FROM dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM dim_country WHERE country_code='CN'), (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), 20000, '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM dim_country WHERE country_code='DE'), (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 2600, '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM dim_country WHERE country_code='US'), (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 2750, '2024-01-01', TRUE),
-- INV-200KW-SIC
((SELECT component_id FROM dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM dim_country WHERE country_code='CN'), (SELECT currency_id FROM dim_currency WHERE currency_code='CNY'), 9500, '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM dim_country WHERE country_code='DE'), (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 1300, '2024-01-01', TRUE),
((SELECT component_id FROM dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM dim_country WHERE country_code='US'), (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 1380, '2024-01-01', TRUE);

-- =============================================================================
-- ESG: 碳排放范围数据
-- =============================================================================
-- dim_emission_scope 已在前面插入

-- =============================================================================
-- HELPER: 生成日期序列的函数（用于事实表批量插入）
-- =============================================================================

-- 我们将使用 generate_series + 固定系数插入事实表
-- 以下是各类事实表的批量种子数据

