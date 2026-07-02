-- =============================================================================
BEGIN;
-- EV OEM Lakehouse - Incremental Migration: 供应链图结构落库
-- 依赖: 00~11 已执行完成 (product / procurement schema 已存在)
-- 本文件只做"图上那些"结构改动: 不涉及ESG、不涉及告警/动态表、不涉及数据对齐重造
-- PostgreSQL 16
-- =============================================================================

SET client_encoding = 'UTF8';
SET search_path TO procurement, product, geo, public;

-- =============================================================================
-- STEP 1: dim_supplier 加 supplier_type 字段 (区分物料商/设备商)
-- =============================================================================

ALTER TABLE procurement.dim_supplier
    ADD COLUMN supplier_type VARCHAR(15) NOT NULL DEFAULT 'MATERIAL'
        CHECK (supplier_type IN ('MATERIAL', 'COMPONENT', 'EQUIPMENT'));

COMMENT ON COLUMN procurement.dim_supplier.supplier_type IS
    '供应商类型: MATERIAL=大宗原材料供应商, COMPONENT=零部件/整机供应商(如电芯/芯片代工), EQUIPMENT=产线设备供应商(一次性资本支出,非按件耗材)';

-- 回填现有12家供应商的 supplier_type (按其 category_id 所属大类判断)
UPDATE procurement.dim_supplier s
SET supplier_type = 'MATERIAL'
FROM product.dim_component_category cat
WHERE s.category_id = cat.category_id
  AND cat.category_code = 'RAW_MAT';

UPDATE procurement.dim_supplier s
SET supplier_type = 'COMPONENT'
FROM product.dim_component_category cat
WHERE s.category_id = cat.category_id
  AND cat.category_code IN ('CELL', 'FSD', 'GLASS', 'INVERTER', 'ELECTRIC', 'CHASSIS');

-- =============================================================================
-- STEP 2: dim_raw_material 加风险标记字段
-- =============================================================================

ALTER TABLE product.dim_raw_material
    ADD COLUMN supply_risk_level VARCHAR(10)
        CHECK (supply_risk_level IN ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL')),
    ADD COLUMN is_single_source BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN product.dim_raw_material.supply_risk_level IS
    '供应风险等级: 对应供应链图上的红色高风险物料标注';
COMMENT ON COLUMN product.dim_raw_material.is_single_source IS
    '是否单点供应(仅一家主供且无备选), TRUE=图上标"Alternative needed"的物料';

-- 按图上标注的9类高风险物料回填风险等级 (先设为TRUE,STEP 5填完备选后统一修正)
UPDATE product.dim_raw_material SET supply_risk_level = 'HIGH', is_single_source = TRUE
WHERE material_code IN ('AL-INGOT', 'SS-30X', 'SIC-WAFER', 'NDFEB-MAG', 'GLASS-AU');

UPDATE product.dim_raw_material SET supply_risk_level = 'CRITICAL', is_single_source = TRUE
WHERE material_code IN ('LIOH', 'NISULF', 'COSULF');

UPDATE product.dim_raw_material SET supply_risk_level = 'LOW', is_single_source = FALSE
WHERE material_code IN ('COPPER', 'HS-STEEL', 'GRAPHITE', 'EPDM-RUB', 'PU-FOAM', 'PP-PLAST');

-- =============================================================================
-- STEP 3: 新建供应商-物料/零件关系桥表 (核心: 落地图上主供/备选/份额)
-- =============================================================================

CREATE TABLE procurement.bridge_supplier_component (
    bridge_id       SERIAL PRIMARY KEY,
    supplier_id     INT NOT NULL REFERENCES procurement.dim_supplier(supplier_id),
    component_id    INT REFERENCES product.dim_component(component_id),
    material_id     INT REFERENCES product.dim_raw_material(material_id),
    supplier_rank   SMALLINT NOT NULL CHECK (supplier_rank IN (1, 2)),
    allocation_pct  NUMERIC(5,4) NOT NULL CHECK (allocation_pct > 0 AND allocation_pct <= 1),
    qualified_date  DATE,
    is_active       BOOLEAN NOT NULL DEFAULT TRUE,
    notes           TEXT,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- 必须且只能指向 component 或 material 中的一个 (二选一)
    CONSTRAINT chk_target_exactly_one CHECK (
        (component_id IS NOT NULL AND material_id IS NULL) OR
        (component_id IS NULL AND material_id IS NOT NULL)
    )
);

COMMENT ON TABLE procurement.bridge_supplier_component IS
    '供应商-物料/零件供应关系桥表; 落地供应链图上的主供/备选/份额结构。component_id用于零件级供应(如CATL供LFP电芯), material_id用于原材料级供应(如Ganfeng供锂)';
COMMENT ON COLUMN procurement.bridge_supplier_component.supplier_rank IS
    '1=主供(图上实线), 2=备选(图上虚线)';
COMMENT ON COLUMN procurement.bridge_supplier_component.allocation_pct IS
    '该供应商承担的采购份额比例(0-1), 同一component/material下同rank的份额之和不应超过1';

-- 同一供应商对同一零件/物料只能出现一次
CREATE UNIQUE INDEX uq_bridge_supplier_component
    ON procurement.bridge_supplier_component (supplier_id, component_id)
    WHERE component_id IS NOT NULL;

CREATE UNIQUE INDEX uq_bridge_supplier_material
    ON procurement.bridge_supplier_component (supplier_id, material_id)
    WHERE material_id IS NOT NULL;

CREATE INDEX idx_bridge_component ON procurement.bridge_supplier_component(component_id);
CREATE INDEX idx_bridge_material ON procurement.bridge_supplier_component(material_id);
CREATE INDEX idx_bridge_supplier ON procurement.bridge_supplier_component(supplier_id);

-- =============================================================================
-- STEP 4: 补充供应商 (图上有、库里没有的备选商 + 设备商)
-- =============================================================================

INSERT INTO procurement.dim_supplier
    (supplier_code, supplier_name, country_id, tier, category_id, payment_terms_days,
     currency_id, is_strategic, risk_rating, supplier_type)
VALUES
-- 备选物料/零件供应商 (9家)
('SUP-INFINEON', 'Infineon(SiC备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'MEDIUM', 'COMPONENT'),

('SUP-ONSEMI', 'ON Semi(SiC备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'MEDIUM', 'COMPONENT'),

('SUP-SAMSUNGF', 'Samsung Foundry(FSD代工备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 1,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD'),
    30, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE, 'MEDIUM', 'COMPONENT'),

('SUP-POSCO', 'POSCO(不锈钢备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'MATERIAL'),

('SUP-NORSKHYDRO', 'Norsk Hydro(铝卷备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='NO'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),
    30, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'MATERIAL'),

('SUP-FUYAO', '福耀玻璃(玻璃备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='GLASS'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'COMPONENT'),

('SUP-MICRON', 'Micron(DRAM备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'COMPONENT'),

('SUP-NXP', 'NXP(PMIC备选)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='NL'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'COMPONENT'),

('SUP-MPMAT', 'MP Materials(稀土磁体备选,产能有限)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'HIGH', 'MATERIAL'),

-- 稀土磁体主供 (原库缺失,补上)
('SUP-ZHENGHAI', '正海磁材(稀土磁体主供)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='RAW_MAT'),
    60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE, 'MEDIUM', 'MATERIAL'),

-- 设备供应商 (2家, 一次性资本支出, 非按件耗材)
('SUP-IDRA', 'Idra(Giga Press压铸机)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='CH'), 2,
    NULL, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE, 'HIGH', 'EQUIPMENT'),

('SUP-LEADCHINA', '先导智能(电池卷绕/涂布设备)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 2,
    NULL, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE, 'MEDIUM', 'EQUIPMENT');

-- =============================================================================
-- STEP 5: 桥表灌数据 (按图上主供/备选/份额关系)
-- =============================================================================

-- ---- 原材料级供应关系 ----

-- 锂 (LIOH): Ganfeng 主供, 暂无备选 (图上标注 Alternative needed 的缺口之一, 保留)
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.75, '赣锋锂业主供氢氧化锂'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-GANFENG' AND m.material_code = 'LIOH';

-- 镍/钴 (NISULF, COSULF): Glencore 主供
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.65, 'Glencore主供硫酸镍'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-GLENCORE' AND m.material_code = 'NISULF';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.60, 'Glencore主供硫酸钴'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-GLENCORE' AND m.material_code = 'COSULF';

-- 铝卷 (AL-INGOT): Novelis 主供 + Norsk Hydro 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.70, 'Novelis主供铝锭/铝合金'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-NOVELIS' AND m.material_code = 'AL-INGOT';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.30, 'Norsk Hydro备选'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-NORSKHYDRO' AND m.material_code = 'AL-INGOT';

-- 不锈钢 (SS-30X): Outokumpu 主供 + POSCO 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.70, 'Outokumpu主供不锈钢'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-OUTOKUMPU' AND m.material_code = 'SS-30X';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.30, 'POSCO备选'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-POSCO' AND m.material_code = 'SS-30X';

-- SiC晶圆 (SIC-WAFER): STMicro 主供 + Infineon/ON Semi 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.70, 'STMicro主供SiC晶圆'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-STMICRO' AND m.material_code = 'SIC-WAFER';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.20, 'Infineon备选'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-INFINEON' AND m.material_code = 'SIC-WAFER';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.10, 'ON Semi备选'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-ONSEMI' AND m.material_code = 'SIC-WAFER';

-- 稀土磁体 (NDFEB-MAG): 正海磁材 主供 + MP Materials 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.80, '正海磁材主供钕铁硼'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-ZHENGHAI' AND m.material_code = 'NDFEB-MAG';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.20, 'MP Materials备选,产能有限'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-MPMAT' AND m.material_code = 'NDFEB-MAG';

-- 玻璃原片 (GLASS-AU): Saint-Gobain 主供 + 福耀 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 1, 0.70, 'Saint-Gobain主供汽车玻璃'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-SGOBAIN' AND m.material_code = 'GLASS-AU';

INSERT INTO procurement.bridge_supplier_component (supplier_id, material_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, m.material_id, 2, 0.30, '福耀玻璃备选'
FROM procurement.dim_supplier s, product.dim_raw_material m
WHERE s.supplier_code = 'SUP-FUYAO' AND m.material_code = 'GLASS-AU';

-- ---- 零件级供应关系 ----

-- 4680电芯: Panasonic 主供(外购部分) + LGES 备选; 其余为自制(SELF,不进桥表)
INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 1, 0.50, 'Panasonic主供4680电芯(外购部分,其余自产)'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-PANASONIC' AND c.component_code = '4680-CELL';

INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 2, 0.20, 'LGES备选'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-LGES' AND c.component_code = '4680-CELL';

-- LFP电芯: CATL 主供 + LGES 备选 (LFP-CELL manufacturing_strategy=BUY, 全部外购)
INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 1, 0.80, 'CATL主供LFP电芯'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-CATL' AND c.component_code = 'LFP-CELL';

INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 2, 0.20, 'LGES备选'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-LGES' AND c.component_code = 'LFP-CELL';

-- FSD芯片代工 (FSD-HW4, manufacturing_strategy=CONTRACT): TSMC 主供 + Samsung Foundry 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 1, 0.85, 'TSMC主供FSD芯片代工'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-TSMC' AND c.component_code = 'FSD-HW4';

INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 2, 0.15, 'Samsung Foundry备选'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-SAMSUNGF' AND c.component_code = 'FSD-HW4';

-- 玻璃车顶 (GLASS-ROOF, manufacturing_strategy=BUY): Saint-Gobain 主供 + 福耀 备选
INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 1, 0.70, 'Saint-Gobain主供玻璃车顶'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-SGOBAIN' AND c.component_code = 'GLASS-ROOF';

INSERT INTO procurement.bridge_supplier_component (supplier_id, component_id, supplier_rank, allocation_pct, notes)
SELECT s.supplier_id, c.component_id, 2, 0.30, '福耀玻璃备选'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-FUYAO' AND c.component_code = 'GLASS-ROOF';

-- =============================================================================
-- STEP 6: 用桥表数据修正 dim_raw_material.is_single_source (有备选的物料改为FALSE)
-- =============================================================================

UPDATE product.dim_raw_material m
SET is_single_source = FALSE
WHERE EXISTS (
    SELECT 1 FROM procurement.bridge_supplier_component b
    WHERE b.material_id = m.material_id AND b.supplier_rank = 2
);

-- 锂(LIOH)仍无备选,保持 is_single_source = TRUE (图上真实缺口,不是bug)

-- =============================================================================
-- 验证查询 (执行后可用来检查结果)
-- =============================================================================
-- SELECT m.material_name, m.supply_risk_level, m.is_single_source,
--        s.supplier_name, b.supplier_rank, b.allocation_pct
-- FROM product.dim_raw_material m
-- LEFT JOIN procurement.bridge_supplier_component b ON b.material_id = m.material_id
-- LEFT JOIN procurement.dim_supplier s ON s.supplier_id = b.supplier_id
-- WHERE m.supply_risk_level IS NOT NULL
-- ORDER BY m.material_code, b.supplier_rank;
--
-- SELECT c.component_name, s.supplier_name, b.supplier_rank, b.allocation_pct
-- FROM procurement.bridge_supplier_component b
-- JOIN product.dim_component c ON c.component_id = b.component_id
-- JOIN procurement.dim_supplier s ON s.supplier_id = b.supplier_id
-- ORDER BY c.component_code, b.supplier_rank;
COMMIT;