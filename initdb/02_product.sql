-- =============================================================================
-- Tesla OEM Lakehouse - product schema: 整车 / 核心零部件 / BOM / 原材料
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
COMMENT ON TABLE  dim_component_category IS '零部件品类层级，支持多级（整车 > 电池系统 > 电芯）';
COMMENT ON COLUMN dim_component_category.level IS '层级深度，1=顶层大类';
COMMENT ON COLUMN dim_component_category.parent_id IS '父品类ID，支持自引用树形结构';
COMMENT ON COLUMN dim_component_category.category_code IS '品类代码，唯一标识';

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
    manufacturing_strategy VARCHAR(10) CHECK (manufacturing_strategy IN ('SELF','CONTRACT','BUY')),
    created_at          TIMESTAMPTZ   NOT NULL DEFAULT now(),
    updated_at          TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_component IS '零部件/整车产品主数据；is_finished_good=TRUE 表示整车';
COMMENT ON COLUMN dim_component.standard_cost_usd IS '标准成本（USD），用于成本核算基准，整车为工厂出厂成本';
COMMENT ON COLUMN dim_component.hs_code IS 'HS 关税编码，整车8703800000，电池8507600090';
COMMENT ON COLUMN dim_component.list_price_usd IS 'MSRP或出厂价（USD），仅整车有终端售价';
COMMENT ON COLUMN dim_component.manufacturing_strategy IS '制造策略：SELF=自制, CONTRACT=外包代工, BUY=外购';

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
COMMENT ON TABLE  bom_header IS 'BOM 版本头；支持多版本（版本变更时新建记录）。整车BOM含电池包/电驱/车身/FSD';
COMMENT ON COLUMN bom_header.is_current IS '是否当前有效版本';
COMMENT ON COLUMN bom_header.parent_component_id IS '父件ID，整车级BOM的父件为整车component_id';

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
COMMENT ON COLUMN bom_item.scrap_rate IS '计划废品率，用于MRP投料量计算';
COMMENT ON COLUMN bom_item.child_component_id IS '子件ID，指向dim_component';
COMMENT ON COLUMN bom_item.substitutable IS '是否可替代，TRUE=允许用替代件';

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
COMMENT ON TABLE  dim_raw_material IS '原材料主数据（大宗商品级别，如碳酸锂、铝锭、碳化硅晶圆）';
COMMENT ON COLUMN dim_raw_material.category IS '原材料大类：金属/化工/半导体/稀土/玻璃/塑料/橡胶';
COMMENT ON COLUMN dim_raw_material.commodity_ticker IS '大宗商品代码，用于追踪期货/现货价格';

CREATE TABLE component_material_usage (
    usage_id        SERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES dim_component(component_id),
    material_id     INT           NOT NULL REFERENCES dim_raw_material(material_id),
    usage_kg_per_unit NUMERIC(10,4) NOT NULL,
    notes           TEXT,
    UNIQUE (component_id, material_id)
);
COMMENT ON TABLE  component_material_usage IS '零部件原材料消耗折算（每个零件含多少kg原材料）';
COMMENT ON COLUMN component_material_usage.usage_kg_per_unit IS '每单位零部件消耗的原材料kg数';

CREATE TABLE fact_raw_material_price_daily (
    price_id        BIGSERIAL PRIMARY KEY,
    material_id     INT           NOT NULL REFERENCES dim_raw_material(material_id),
    price_date      DATE          NOT NULL,
    price_usd_per_mt NUMERIC(14,4) NOT NULL,
    price_source    VARCHAR(50),
    UNIQUE (material_id, price_date)
);
COMMENT ON TABLE  fact_raw_material_price_daily IS '原材料每日现货价格（USD/公吨或USD/单位）';
CREATE INDEX idx_rmp_material_date ON fact_raw_material_price_daily(material_id, price_date DESC);

-- =============================================================================
-- SEED DATA — 品类
-- =============================================================================

INSERT INTO dim_component_category (category_code, category_name, parent_id, level) VALUES
-- 顶层
('VEHICLE',  '整车',               NULL, 1),
('BATTERY',  '电池系统',            NULL, 1),
('DRIVE',    '电驱系统',            NULL, 1),
('BODY',     '车身与结构',          NULL, 1),
('FSD',      '自动驾驶FSD',        NULL, 1),
('THERMAL',  '热管理系统',          NULL, 1),
('ELECTRIC', '低压电子与线束',      NULL, 1),
('CHASSIS',  '底盘与悬架',          NULL, 1),
('INTERIOR', '内饰与外饰',          NULL, 1),
('RAW_MAT',  '原材料',              NULL, 1),

-- 电池子类
('BAT_PACK', '电池包总成',          (SELECT category_id FROM dim_component_category WHERE category_code='BATTERY'), 2),
('CELL',     '电芯',                (SELECT category_id FROM dim_component_category WHERE category_code='BATTERY'), 2),
('BMS',      'BMS电池管理',         (SELECT category_id FROM dim_component_category WHERE category_code='BATTERY'), 2),

-- 电驱子类
('MOTOR',    '驱动电机',            (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE'), 2),
('INVERTER', '逆变器',              (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE'), 2),
('GEARBOX',  '减速器/齿轮箱',       (SELECT category_id FROM dim_component_category WHERE category_code='DRIVE'), 2),

-- 车身子类
('CASTING',  '一体化压铸件',        (SELECT category_id FROM dim_component_category WHERE category_code='BODY'), 2),
('STAMPING', '冲压件',              (SELECT category_id FROM dim_component_category WHERE category_code='BODY'), 2),
('GLASS',    '玻璃',                (SELECT category_id FROM dim_component_category WHERE category_code='BODY'), 2),

-- FSD子类
('FSD_COMP', 'FSD计算机',           (SELECT category_id FROM dim_component_category WHERE category_code='FSD'), 2),
('CAMERA',   '摄像头/传感器',       (SELECT category_id FROM dim_component_category WHERE category_code='FSD'), 2),

-- 热管理
('HEATPUMP', '热泵系统',            (SELECT category_id FROM dim_component_category WHERE category_code='THERMAL'), 2),
('COOLING',  '液冷系统',            (SELECT category_id FROM dim_component_category WHERE category_code='THERMAL'), 2);

-- =============================================================================
-- SEED DATA — 整车
-- =============================================================================

INSERT INTO dim_component (component_code, component_name, category_id, uom, weight_kg, standard_cost_usd, list_price_usd, is_finished_good, lifecycle_stage, hs_code, manufacturing_strategy) VALUES
-- 整车 (is_finished_good=TRUE, 终端消费品)
('M3-SR',    'Model 3 后驱标准续航',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 1760, 26000, 38990, TRUE,  'MASS', '8703800000', 'SELF'),
('M3-LR',    'Model 3 长续航双电机',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 1850, 31000, 45990, TRUE,  'MASS', '8703800000', 'SELF'),
('MY-SR',    'Model Y 后驱标准续航',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 2000, 32000, 44990, TRUE,  'MASS', '8703800000', 'SELF'),
('MY-LR',    'Model Y 长续航双电机',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 2100, 36000, 49990, TRUE,  'MASS', '8703800000', 'SELF'),
('MY-PERF',  'Model Y Performance',    (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 2150, 39000, 52490, TRUE,  'MASS', '8703800000', 'SELF'),
('CT-AWD',   'Cybertruck 双电机',      (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 3100, 58000, 79990, TRUE,  'RAMP', '8703800000', 'SELF'),
('MS-PLAID', 'Model S Plaid 三电机',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 2200, 68000, 89990, TRUE,  'MASS', '8703800000', 'SELF'),
('MX-PLAID', 'Model X Plaid 三电机',   (SELECT category_id FROM dim_component_category WHERE category_code='VEHICLE'), 'PCS', 2450, 72000, 94990, TRUE,  'MASS', '8703800000', 'SELF'),

-- 电池系统 (自制)
('4680-PACK', '4680 结构电池包 (~82kWh)', (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 490, 8500, NULL, FALSE, 'MASS', '8507600090', 'SELF'),
('2170-PACK', '2170 电池包 (~100kWh)',    (SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 530, 7800, NULL, FALSE, 'MASS', '8507600090', 'SELF'),
('LFP-PACK',  'LFP 磷酸铁锂电池包 (~60kWh)',(SELECT category_id FROM dim_component_category WHERE category_code='BAT_PACK'), 'PCS', 420, 4500, NULL, FALSE, 'MASS', '8507600090', 'SELF'),
('4680-CELL', '4680 电芯 (23Ah)',          (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),     'PCS', 0.355, 8.5, NULL, FALSE, 'RAMP', '8507600010', 'SELF'),
('LFP-CELL',  'LFP 方壳电芯 (280Ah)',      (SELECT category_id FROM dim_component_category WHERE category_code='CELL'),     'PCS', 0.63, 8.8, NULL, FALSE, 'MASS', '8507600010', 'BUY'),
('BMS-V3',    'BMS 电池管理系统 V3',       (SELECT category_id FROM dim_component_category WHERE category_code='BMS'),      'PCS', 2.8, 280, NULL, FALSE, 'MASS', '8537109900', 'SELF'),

-- 电驱系统 (自制)
('DU-3D6',    '驱动单元 3D6 (PMSM, 前轴)', (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),    'PCS', 78, 1900, NULL, FALSE, 'MASS', '8501532090', 'SELF'),
('DU-3D7',    '驱动单元 3D7 (PMSM, 后轴)', (SELECT category_id FROM dim_component_category WHERE category_code='MOTOR'),    'PCS', 85, 2100, NULL, FALSE, 'MASS', '8501532090', 'SELF'),
('SIC-INV',   'SiC MOSFET 逆变器',        (SELECT category_id FROM dim_component_category WHERE category_code='INVERTER'), 'PCS', 4.5, 800, NULL, FALSE, 'MASS', '8504401990', 'SELF'),
('GBX-1SPD',  '单速减速器/齿轮箱',        (SELECT category_id FROM dim_component_category WHERE category_code='GEARBOX'),  'PCS', 16, 350, NULL, FALSE, 'MASS', '8483409000', 'SELF'),

-- 车身结构 (自制)
('MEGACAST-F', '前车身一体化压铸件',      (SELECT category_id FROM dim_component_category WHERE category_code='CASTING'),  'PCS', 62, 380, NULL, FALSE, 'MASS', '7616999000', 'SELF'),
('MEGACAST-R', '后车身一体化压铸件',      (SELECT category_id FROM dim_component_category WHERE category_code='CASTING'),  'PCS', 78, 450, NULL, FALSE, 'MASS', '7616999000', 'SELF'),
('CT-BODY',    'Cybertruck 不锈钢车身',   (SELECT category_id FROM dim_component_category WHERE category_code='CASTING'),  'PCS', 275, 3200, NULL, FALSE, 'RAMP', '8708999990', 'SELF'),
('GLASS-ROOF', '全景玻璃车顶',            (SELECT category_id FROM dim_component_category WHERE category_code='GLASS'),    'PCS', 18, 220, NULL, FALSE, 'MASS', '7007212000', 'BUY'),

-- FSD (芯片代工+自研组装)
('FSD-HW4',    'FSD 计算机 HW4.0',        (SELECT category_id FROM dim_component_category WHERE category_code='FSD_COMP'), 'PCS', 2.5, 1800, NULL, FALSE, 'MASS', '8542319000', 'CONTRACT'),
('CAM-5MP',    '500万像素自动驾驶摄像头',   (SELECT category_id FROM dim_component_category WHERE category_code='CAMERA'),   'PCS', 0.15, 45, NULL, FALSE, 'MASS', '8525893000', 'BUY'),

-- 热管理
('HEATPUMP-V2','Tesla 热泵系统 V2',       (SELECT category_id FROM dim_component_category WHERE category_code='HEATPUMP'), 'PCS', 14, 520, NULL, FALSE, 'MASS', '8415819000', 'SELF'),
('OCTOVALVE',  '八通阀超级歧管',          (SELECT category_id FROM dim_component_category WHERE category_code='COOLING'),  'PCS', 2.1, 85, NULL, FALSE, 'MASS', '8481809000', 'SELF'),

-- 低压电子
('MCU-V3',     'Media Control Unit V3',   (SELECT category_id FROM dim_component_category WHERE category_code='ELECTRIC'), 'PCS', 0.8, 420, NULL, FALSE, 'MASS', '8537109900', 'SELF');

-- =============================================================================
-- SEED DATA — 整车BOM
-- =============================================================================

DO $$
DECLARE
    v RECORD;
    bid INTEGER;
BEGIN
    FOR v IN SELECT component_id, component_code FROM dim_component WHERE is_finished_good = TRUE
    LOOP
        INSERT INTO bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current)
        VALUES ('BOM-' || v.component_code || '-V1', v.component_id, '1.0', '2023-01-01', TRUE)
        RETURNING bom_id INTO bid;

        -- Model Y (含 Performance)
        IF v.component_code LIKE 'MY-%' THEN
            INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
            SELECT bid, c.component_id, t.qty, t.seq, 0.002
            FROM (VALUES
                ('4680-PACK',1,10), ('DU-3D6',1,20), ('DU-3D7',1,30),
                ('MEGACAST-F',1,40), ('MEGACAST-R',1,50), ('FSD-HW4',1,60),
                ('GLASS-ROOF',1,70), ('HEATPUMP-V2',1,80), ('CAM-5MP',8,90),
                ('MCU-V3',1,100), ('OCTOVALVE',1,110)
            ) AS t(code, qty, seq)
            JOIN dim_component c ON c.component_code = t.code;

        -- Model 3
        ELSIF v.component_code LIKE 'M3-%' THEN
            INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
            SELECT bid, c.component_id, t.qty, t.seq, 0.002
            FROM (VALUES
                ('LFP-PACK',1,10), ('DU-3D7',2,20),
                ('FSD-HW4',1,30), ('GLASS-ROOF',1,40), ('HEATPUMP-V2',1,50),
                ('CAM-5MP',8,60), ('MCU-V3',1,70), ('OCTOVALVE',1,80)
            ) AS t(code, qty, seq)
            JOIN dim_component c ON c.component_code = t.code;

        -- Cybertruck
        ELSIF v.component_code = 'CT-AWD' THEN
            INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
            SELECT bid, c.component_id, t.qty, t.seq, 0.003
            FROM (VALUES
                ('4680-PACK',1,10), ('DU-3D7',2,20), ('CT-BODY',1,30),
                ('FSD-HW4',1,40), ('CAM-5MP',8,50),
                ('MCU-V3',1,60), ('OCTOVALVE',1,70), ('HEATPUMP-V2',1,80)
            ) AS t(code, qty, seq)
            JOIN dim_component c ON c.component_code = t.code;

        -- Model S/X Plaid
        ELSIF v.component_code IN ('MS-PLAID','MX-PLAID') THEN
            INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
            SELECT bid, c.component_id, t.qty, t.seq, 0.001
            FROM (VALUES
                ('2170-PACK',1,10), ('DU-3D6',1,20), ('DU-3D7',2,30),
                ('FSD-HW4',1,40), ('GLASS-ROOF',1,50), ('HEATPUMP-V2',1,60),
                ('CAM-5MP',8,70), ('MCU-V3',1,80), ('OCTOVALVE',1,90)
            ) AS t(code, qty, seq)
            JOIN dim_component c ON c.component_code = t.code;
        END IF;
    END LOOP;
END;
$$;

-- 非整车BOM (电池包 → 电芯/BMS)
INSERT INTO bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current) VALUES
('BOM-4680PACK-V1', (SELECT component_id FROM dim_component WHERE component_code='4680-PACK'), '1.0', '2023-01-01', TRUE),
('BOM-LFPPACK-V1',  (SELECT component_id FROM dim_component WHERE component_code='LFP-PACK'),  '1.0', '2023-01-01', TRUE),
('BOM-2170PACK-V1', (SELECT component_id FROM dim_component WHERE component_code='2170-PACK'), '1.0', '2023-01-01', TRUE),
('BOM-DU3D6-V1',    (SELECT component_id FROM dim_component WHERE component_code='DU-3D6'),    '1.0', '2023-01-01', TRUE);

INSERT INTO bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate) VALUES
-- 4680电池包: 828颗电芯 + BMS
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-4680PACK-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='4680-CELL'), 828, 10, 0.003),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-4680PACK-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='BMS-V3'),    1,   20, 0.001),
-- LFP电池包: 192颗电芯 + BMS
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-LFPPACK-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='LFP-CELL'),  192, 10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-LFPPACK-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='BMS-V3'),    1,   20, 0.001),
-- 2170电池包
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-2170PACK-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='BMS-V3'),    1,   10, 0.001),
-- 驱动单元3D6
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-DU3D6-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='SIC-INV'),   1,   10, 0.002),
((SELECT bom_id FROM bom_header WHERE bom_code='BOM-DU3D6-V1'),
 (SELECT component_id FROM dim_component WHERE component_code='GBX-1SPD'),  1,   20, 0.002);

-- =============================================================================
-- SEED DATA — 原材料 (14种, 覆盖金属/化工/半导体/稀土/玻璃/塑料/橡胶)
-- =============================================================================

INSERT INTO dim_raw_material (material_code, material_name, category, uom, commodity_ticker, primary_source_country_id) VALUES
('AL-INGOT',  '铝锭(免热处理合金)',     '金属',   'MT',  'AL-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='AU')),
('SS-30X',    '30X冷轧不锈钢卷',         '金属',   'MT',  'SS-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='FI')),
('HS-STEEL',  '热成型钢卷(硼钢)',        '金属',   'MT',  'HRS-CME',(SELECT country_id FROM geo.dim_country WHERE country_code='KR')),
('LIOH',      '氢氧化锂',               '化工',   'MT',  'LI-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='CL')),
('NISULF',    '硫酸镍',                 '化工',   'MT',  'NI-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='ID')),
('COSULF',    '硫酸钴',                 '化工',   'MT',  'CO-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CD')),
('GRAPHITE',  '球形石墨(负极)',          '化工',   'MT',  'GR-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('SIC-WAFER', '碳化硅晶圆(6英寸)',       '半导体', 'PCS', 'SIC-MTL',(SELECT country_id FROM geo.dim_country WHERE country_code='NL')),
('NDFEB-MAG', '钕铁硼永磁体',            '稀土',   'MT',  'NDPR-MTL',(SELECT country_id FROM geo.dim_country WHERE country_code='CN')),
('COPPER',    '电解铜',                  '金属',   'MT',  'CU-LME', (SELECT country_id FROM geo.dim_country WHERE country_code='CL')),
('GLASS-AU',  '汽车级浮法玻璃',          '玻璃',   'SQM', 'GL-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='FR')),
('EPDM-RUB',  'EPDM橡胶密封条',          '橡胶',   'MT',  'EPDM-MTL',(SELECT country_id FROM geo.dim_country WHERE country_code='DE')),
('PU-FOAM',   '聚氨酯发泡(座椅)',        '塑料',   'MT',  'PU-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='DE')),
('PP-PLAST',  'PP改性塑料(内饰)',        '塑料',   'MT',  'PP-CME', (SELECT country_id FROM geo.dim_country WHERE country_code='SA'));

-- =============================================================================
-- SEED DATA — 关键零部件原材料消耗
-- =============================================================================

INSERT INTO component_material_usage (component_id, material_id, usage_kg_per_unit) VALUES
-- 4680电芯
((SELECT component_id FROM dim_component WHERE component_code='4680-CELL'), (SELECT material_id FROM dim_raw_material WHERE material_code='LIOH'),   0.012),
((SELECT component_id FROM dim_component WHERE component_code='4680-CELL'), (SELECT material_id FROM dim_raw_material WHERE material_code='NISULF'),  0.078),
((SELECT component_id FROM dim_component WHERE component_code='4680-CELL'), (SELECT material_id FROM dim_raw_material WHERE material_code='GLASS-AU'),0.002),
-- LFP电芯 (外购，但记录材料含量用于碳足迹)
((SELECT component_id FROM dim_component WHERE component_code='LFP-CELL'),  (SELECT material_id FROM dim_raw_material WHERE material_code='LIOH'),   0.004),
((SELECT component_id FROM dim_component WHERE component_code='LFP-CELL'),  (SELECT material_id FROM dim_raw_material WHERE material_code='GRAPHITE'),0.085),
-- 压铸件
((SELECT component_id FROM dim_component WHERE component_code='MEGACAST-R'),(SELECT material_id FROM dim_raw_material WHERE material_code='AL-INGOT'),78),
((SELECT component_id FROM dim_component WHERE component_code='MEGACAST-F'),(SELECT material_id FROM dim_raw_material WHERE material_code='AL-INGOT'),62),
-- Cybertruck车身
((SELECT component_id FROM dim_component WHERE component_code='CT-BODY'),   (SELECT material_id FROM dim_raw_material WHERE material_code='SS-30X'),  275),
-- 驱动单元（铜 + 永磁体）
((SELECT component_id FROM dim_component WHERE component_code='DU-3D7'),   (SELECT material_id FROM dim_raw_material WHERE material_code='NDFEB-MAG'),1.2),
((SELECT component_id FROM dim_component WHERE component_CODE='DU-3D7'),   (SELECT material_id FROM dim_raw_material WHERE material_code='COPPER'),  8.5),
-- 逆变器（SiC晶圆）
((SELECT component_id FROM dim_component WHERE component_code='SIC-INV'),   (SELECT material_id FROM dim_raw_material WHERE material_code='SIC-WAFER'),0.15);
