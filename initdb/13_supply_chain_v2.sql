-- =============================================================================
-- EV OEM Lakehouse - Incremental Migration V2: 补全复杂生产图支撑
-- 依赖: 12_supply_chain_map.sql 已执行完成
-- 本文件解决5个缺口: 设备商-产线桥接 / FSD零件拆细 / 电子件落库 /
--                    多级备选 / 供应商能力字段
-- PostgreSQL 16
-- =============================================================================

BEGIN;

SET client_encoding = 'UTF8';
SET search_path TO procurement, product, production, geo, public;

-- =============================================================================
-- STEP 1: 新建设备商-产线/工序桥表
-- =============================================================================

CREATE TABLE procurement.bridge_supplier_process_equipment (
    bridge_id                   SERIAL PRIMARY KEY,
    supplier_id                 INT NOT NULL REFERENCES procurement.dim_supplier(supplier_id),
    line_id                     INT REFERENCES production.dim_production_line(line_id),
    step_id                     INT REFERENCES production.dim_process_step(step_id),
    equipment_role              VARCHAR(200) NOT NULL,
    capacity_risk_level         VARCHAR(10) CHECK (capacity_risk_level IN ('LOW','MEDIUM','HIGH','CRITICAL')),
    replacement_lead_time_days  INT,
    is_active                   BOOLEAN NOT NULL DEFAULT TRUE,
    notes                       TEXT,
    created_at                  TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT chk_equip_target CHECK (line_id IS NOT NULL OR step_id IS NOT NULL)
);

COMMENT ON TABLE procurement.bridge_supplier_process_equipment IS
    '设备供应商-产线/工序桥表; 落地图上Giga Press/卷绕设备这类资本设备与产线的绑定关系,区别于按件采购的物料桥表';
COMMENT ON COLUMN procurement.bridge_supplier_process_equipment.equipment_role IS
    '设备在该产线/工序中的角色描述,如"Giga Press 6000T压铸机"';
COMMENT ON COLUMN procurement.bridge_supplier_process_equipment.capacity_risk_level IS
    '该设备对产能的风险等级; CRITICAL=单点设备一旦停机整条产线停摆';
COMMENT ON COLUMN procurement.bridge_supplier_process_equipment.replacement_lead_time_days IS
    '设备损坏/需更换时的采购+安装+调试周期(天); Giga Press这类通常12-18个月';

CREATE INDEX idx_bspe_supplier ON procurement.bridge_supplier_process_equipment(supplier_id);
CREATE INDEX idx_bspe_line ON procurement.bridge_supplier_process_equipment(line_id);

-- 灌数据: Idra -> Giga Press压铸线; 先导智能 -> 电池卷绕线
INSERT INTO procurement.bridge_supplier_process_equipment
    (supplier_id, line_id, equipment_role, capacity_risk_level, replacement_lead_time_days, notes)
SELECT s.supplier_id, l.line_id,
       'Giga Press 6000T压铸机', 'CRITICAL', 540,
       '单台设备决定前/后车身压铸产能上限; 全球仅Idra/力劲少数厂商能造此吨位压铸机'
FROM procurement.dim_supplier s, production.dim_production_line l
WHERE s.supplier_code = 'SUP-IDRA' AND l.line_code = 'BDY-PRESS';

INSERT INTO procurement.bridge_supplier_process_equipment
    (supplier_id, line_id, equipment_role, capacity_risk_level, replacement_lead_time_days, notes)
SELECT s.supplier_id, l.line_id,
       '电池卷绕/涂布设备', 'MEDIUM', 270,
       '决定4680电芯卷绕产能; 先导智能/Manz为主要供应商,交期约9个月'
FROM procurement.dim_supplier s, production.dim_production_line l
WHERE s.supplier_code = 'SUP-LEADCHINA' AND l.line_code = 'BAT-WIND';

-- =============================================================================
-- STEP 2: FSD 零件拆细 (FSD-HW4 -> FSD-PCBA + FSD-HOUSING -> FSD-SOC/DRAM/PMIC/CONNECTOR)
-- =============================================================================

INSERT INTO product.dim_component
    (component_code, component_name, category_id, uom, weight_kg, standard_cost_usd,
     is_finished_good, lifecycle_stage, manufacturing_strategy)
VALUES
('FSD-SOC', 'FSD SoC芯片(晶圆代工产出)',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD_COMP'),
    'PCS', 0.02, 380, FALSE, 'MASS', 'CONTRACT'),

('FSD-PCBA', 'FSD PCBA(SMT贴片总成)',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD_COMP'),
    'PCS', 0.35, 480, FALSE, 'MASS', 'SELF'),

('FSD-HOUSING', 'FSD散热壳体',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD_COMP'),
    'PCS', 0.9, 60, FALSE, 'MASS', 'BUY'),

('DRAM-CHIP', 'DRAM内存芯片',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    'PCS', 0.005, 40, FALSE, 'MASS', 'BUY'),

('PMIC-CHIP', 'PMIC电源管理芯片',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    'PCS', 0.005, 15, FALSE, 'MASS', 'BUY'),

('CONNECTOR-SET', '连接器/线束组件',
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    'PCS', 0.15, 8, FALSE, 'MASS', 'BUY');

COMMENT ON TABLE product.dim_component IS
    '零部件/整车产品主数据；is_finished_good=TRUE 表示整车。FSD-HW4 下已拆分至 FSD-SOC/FSD-PCBA/FSD-HOUSING 三级颗粒度';

-- BOM: FSD-HW4 <- FSD-PCBA + FSD-HOUSING
INSERT INTO product.bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current)
VALUES ('BOM-FSDHW4-V1', (SELECT component_id FROM product.dim_component WHERE component_code='FSD-HW4'), '1.0', '2023-01-01', TRUE);

INSERT INTO product.bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDHW4-V1'),
       c.component_id, 1, 10, 0.005
FROM product.dim_component c WHERE c.component_code = 'FSD-PCBA'
UNION ALL
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDHW4-V1'),
       c.component_id, 1, 20, 0.002
FROM product.dim_component c WHERE c.component_code = 'FSD-HOUSING';

-- BOM: FSD-PCBA <- FSD-SOC + DRAM + PMIC + CONNECTOR (PCB裸板暂缺供应商,先不建component,留作已知缺口)
INSERT INTO product.bom_header (bom_code, parent_component_id, bom_version, effective_from, is_current)
VALUES ('BOM-FSDPCBA-V1', (SELECT component_id FROM product.dim_component WHERE component_code='FSD-PCBA'), '1.0', '2023-01-01', TRUE);

INSERT INTO product.bom_item (bom_id, child_component_id, qty_per_parent, item_seq, scrap_rate)
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDPCBA-V1'),
       c.component_id, 1, 10, 0.01
FROM product.dim_component c WHERE c.component_code = 'FSD-SOC'
UNION ALL
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDPCBA-V1'),
       c.component_id, 2, 20, 0.003
FROM product.dim_component c WHERE c.component_code = 'DRAM-CHIP'
UNION ALL
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDPCBA-V1'),
       c.component_id, 1, 30, 0.003
FROM product.dim_component c WHERE c.component_code = 'PMIC-CHIP'
UNION ALL
SELECT (SELECT bom_id FROM product.bom_header WHERE bom_code='BOM-FSDPCBA-V1'),
       c.component_id, 1, 40, 0.005
FROM product.dim_component c WHERE c.component_code = 'CONNECTOR-SET';

-- =============================================================================
-- STEP 3: 补充供应商 (DRAM/PMIC 主供, 之前漏加)
-- =============================================================================

INSERT INTO procurement.dim_supplier
    (supplier_code, supplier_name, country_id, tier, category_id, payment_terms_days,
     currency_id, is_strategic, risk_rating, supplier_type)
VALUES
('SUP-SKHYNIX', '三星/SK Hynix(DRAM主供)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'COMPONENT'),

('SUP-TI', 'Texas Instruments(PMIC主供)',
    (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2,
    (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'),
    45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE, 'LOW', 'COMPONENT');

-- =============================================================================
-- STEP 4: bridge_supplier_component 结构升级
--   4a. supplier_rank 从"只能1/2" 改为 "1=主供, >=2=备选(数字越大优先级越低)"
--   4b. 加供应商能力字段
-- =============================================================================

ALTER TABLE procurement.bridge_supplier_component
    DROP CONSTRAINT IF EXISTS bridge_supplier_component_supplier_rank_check;

ALTER TABLE procurement.bridge_supplier_component
    ADD CONSTRAINT chk_supplier_rank_positive CHECK (supplier_rank >= 1);

COMMENT ON COLUMN procurement.bridge_supplier_component.supplier_rank IS
    '1=主供(图上实线), 2=备选一优先, 3=备选二, 依次类推(数字越大切换优先级越低)';

ALTER TABLE procurement.bridge_supplier_component
    ADD COLUMN max_monthly_capacity   NUMERIC(14,2),
    ADD COLUMN lead_time_days         INT,
    ADD COLUMN switch_over_days       INT,
    ADD COLUMN qualification_status   VARCHAR(20)
        CHECK (qualification_status IN ('QUALIFIED','IN_QUALIFICATION','NOT_QUALIFIED'))
        NOT NULL DEFAULT 'QUALIFIED';

COMMENT ON COLUMN procurement.bridge_supplier_component.max_monthly_capacity IS
    '该供应商对此物料/零件的月度最大供货能力(单位与dim_raw_material.uom或dim_component.uom一致)';
COMMENT ON COLUMN procurement.bridge_supplier_component.lead_time_days IS
    '常规下单交货周期(天)';
COMMENT ON COLUMN procurement.bridge_supplier_component.switch_over_days IS
    '从0出货量爬升到可用产能所需天数; 备选供应商此值通常远高于主供,体现"临时救急能力有限"';
COMMENT ON COLUMN procurement.bridge_supplier_component.qualification_status IS
    '认证状态: QUALIFIED=已通过认证可随时供货, IN_QUALIFICATION=认证中/产能爬坡未完成, NOT_QUALIFIED=未认证';

-- =============================================================================
-- STEP 5: 修正 FSD 供应关系 (从挂在 FSD-HW4 改为挂在 FSD-SOC)
-- =============================================================================

DELETE FROM procurement.bridge_supplier_component
WHERE component_id = (SELECT component_id FROM product.dim_component WHERE component_code = 'FSD-HW4')
  AND supplier_id IN (
      SELECT supplier_id FROM procurement.dim_supplier
      WHERE supplier_code IN ('SUP-TSMC', 'SUP-SAMSUNGF')
  );

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 1, 0.85,
       2000000, 90, 0, 'QUALIFIED',
       'TSMC主供FSD SoC晶圆代工(先进制程)'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-TSMC' AND c.component_code = 'FSD-SOC';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 2, 0.15,
       300000, 120, 270, 'IN_QUALIFICATION',
       'Samsung Foundry备选,成熟制程降级方案,认证尚未完成产能爬坡'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-SAMSUNGF' AND c.component_code = 'FSD-SOC';

-- =============================================================================
-- STEP 6: DRAM / PMIC / 连接器 供应关系落库
-- =============================================================================

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 1, 1.00,
       5000000, 45, 0, 'QUALIFIED', '三星/SK Hynix主供DRAM,暂无认证备选'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-SKHYNIX' AND c.component_code = 'DRAM-CHIP';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 2, 0.01,
       50000, 90, 180, 'IN_QUALIFICATION', 'Micron备选,认证中,仅保留小额试产份额'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-MICRON' AND c.component_code = 'DRAM-CHIP';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 1, 0.80,
       3000000, 45, 0, 'QUALIFIED', 'TI主供PMIC'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-TI' AND c.component_code = 'PMIC-CHIP';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 2, 0.20,
       800000, 60, 60, 'QUALIFIED', 'NXP备选,已通过认证'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-NXP' AND c.component_code = 'PMIC-CHIP';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 1, 0.90,
       4000000, 45, 0, 'QUALIFIED', 'Aptiv主供连接器/线束'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-APTIV' AND c.component_code = 'CONNECTOR-SET';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 1, 0.70,
       800000, 45, 0, 'QUALIFIED', 'Novelis主供FSD散热铝壳体'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-NOVELIS' AND c.component_code = 'FSD-HOUSING';

INSERT INTO procurement.bridge_supplier_component
    (supplier_id, component_id, supplier_rank, allocation_pct,
     max_monthly_capacity, lead_time_days, switch_over_days, qualification_status, notes)
SELECT s.supplier_id, c.component_id, 2, 0.30,
       250000, 75, 120, 'QUALIFIED', 'Norsk Hydro备选FSD散热铝壳体'
FROM procurement.dim_supplier s, product.dim_component c
WHERE s.supplier_code = 'SUP-NORSKHYDRO' AND c.component_code = 'FSD-HOUSING';

-- =============================================================================
-- STEP 7: 更新 SiC 供应关系的 rank (Infineon=2优先, ON Semi=3次优先) 并补能力字段
-- =============================================================================

UPDATE procurement.bridge_supplier_component b
SET supplier_rank = 2,
    max_monthly_capacity = 400000, lead_time_days = 60, switch_over_days = 90,
    qualification_status = 'QUALIFIED'
FROM procurement.dim_supplier s
WHERE b.supplier_id = s.supplier_id AND s.supplier_code = 'SUP-INFINEON'
  AND b.material_id = (SELECT material_id FROM product.dim_raw_material WHERE material_code = 'SIC-WAFER');

UPDATE procurement.bridge_supplier_component b
SET supplier_rank = 3,
    max_monthly_capacity = 150000, lead_time_days = 75, switch_over_days = 150,
    qualification_status = 'IN_QUALIFICATION'
FROM procurement.dim_supplier s
WHERE b.supplier_id = s.supplier_id AND s.supplier_code = 'SUP-ONSEMI'
  AND b.material_id = (SELECT material_id FROM product.dim_raw_material WHERE material_code = 'SIC-WAFER');

-- 主供STMicro补能力字段
UPDATE procurement.bridge_supplier_component b
SET max_monthly_capacity = 900000, lead_time_days = 45, switch_over_days = 0,
    qualification_status = 'QUALIFIED'
FROM procurement.dim_supplier s
WHERE b.supplier_id = s.supplier_id AND s.supplier_code = 'SUP-STMICRO'
  AND b.material_id = (SELECT material_id FROM product.dim_raw_material WHERE material_code = 'SIC-WAFER');

-- =============================================================================
-- STEP 8: 为其余已有桥表行批量回填能力字段 (按主供/备选给合理默认值)
--   主供: 交期短、切换成本0、已认证
--   备选: 交期长、切换爬坡久、部分尚在认证
-- =============================================================================

UPDATE procurement.bridge_supplier_component
SET lead_time_days = 45, switch_over_days = 0, qualification_status = 'QUALIFIED'
WHERE supplier_rank = 1 AND lead_time_days IS NULL;

UPDATE procurement.bridge_supplier_component
SET lead_time_days = 75, switch_over_days = 120,
    qualification_status = CASE
        WHEN EXISTS (
            SELECT 1 FROM procurement.dim_supplier s
            WHERE s.supplier_id = bridge_supplier_component.supplier_id
              AND s.supplier_code = 'SUP-MPMAT'
        ) THEN 'IN_QUALIFICATION'
        ELSE 'QUALIFIED'
    END
WHERE supplier_rank >= 2 AND lead_time_days IS NULL;

-- max_monthly_capacity 按主供/备选给量级默认值 (缺具体数字的先用行业量级估算,后续可精修)
UPDATE procurement.bridge_supplier_component
SET max_monthly_capacity = CASE WHEN supplier_rank = 1 THEN 500000 ELSE 100000 END
WHERE max_monthly_capacity IS NULL;

COMMIT;

-- =============================================================================
-- 验证查询
-- =============================================================================
-- 1. 设备商-产线绑定
-- SELECT s.supplier_name, l.line_name, e.equipment_role, e.capacity_risk_level, e.replacement_lead_time_days
-- FROM procurement.bridge_supplier_process_equipment e
-- JOIN procurement.dim_supplier s ON s.supplier_id = e.supplier_id
-- LEFT JOIN production.dim_production_line l ON l.line_id = e.line_id;
--
-- 2. FSD拆细后的供应链
-- SELECT c.component_code, s.supplier_name, b.supplier_rank, b.allocation_pct,
--        b.lead_time_days, b.switch_over_days, b.qualification_status
-- FROM procurement.bridge_supplier_component b
-- JOIN product.dim_component c ON c.component_id = b.component_id
-- JOIN procurement.dim_supplier s ON s.supplier_id = b.supplier_id
-- WHERE c.component_code IN ('FSD-SOC','DRAM-CHIP','PMIC-CHIP','CONNECTOR-SET')
-- ORDER BY c.component_code, b.supplier_rank;
--
-- 3. 多级备选优先级检查 (SiC应有rank 1/2/3三条)
-- SELECT s.supplier_name, b.supplier_rank, b.allocation_pct, b.qualification_status
-- FROM procurement.bridge_supplier_component b
-- JOIN procurement.dim_supplier s ON s.supplier_id = b.supplier_id
-- WHERE b.material_id = (SELECT material_id FROM product.dim_raw_material WHERE material_code='SIC-WAFER')
-- ORDER BY b.supplier_rank;
