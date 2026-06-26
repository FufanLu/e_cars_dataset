-- =============================================================================
-- EV OEM Lakehouse - production schema: 工厂 / 产线 / 工艺路线 / 生产订单 / 质量
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
    renewable_energy_pct NUMERIC(5,2),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_factory IS 'EV全球工厂主数据，含产能、认证、可再生能源比例';
COMMENT ON COLUMN dim_factory.factory_code IS '工厂代码，如FAC-SHA(Giga上海)、FAC-TXS(Giga Texas)';
COMMENT ON COLUMN dim_factory.annual_capacity IS '年产能，整车工厂单位为辆/年，电池工厂为GWh/年';
COMMENT ON COLUMN dim_factory.headcount IS '员工总数，含直接+间接人工';
COMMENT ON COLUMN dim_factory.iso_certified IS '是否通过ISO 9001质量管理体系认证';
COMMENT ON COLUMN dim_factory.iatf_certified IS '是否通过IATF 16949汽车行业质量体系认证';
COMMENT ON COLUMN dim_factory.renewable_energy_pct IS '工厂可再生能源使用比例(%)';

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
COMMENT ON COLUMN dim_production_line.line_code IS '产线代码，如GA-TX(总装)、BAT-ELEC(电极涂布)';
COMMENT ON COLUMN dim_production_line.factory_id IS '所属工厂，关联dim_factory';
COMMENT ON COLUMN dim_production_line.primary_category_id IS '主要生产品类，关联dim_component_category';
COMMENT ON COLUMN dim_production_line.designed_takt_sec IS '设计节拍（秒），EV追求极端节拍如Giga Press 90秒';
COMMENT ON COLUMN dim_production_line.current_takt_sec IS '当前实际节拍（秒），用于OEE计算';
COMMENT ON COLUMN dim_production_line.shift_count IS '每日班次数（2或3班）';

-- ★ NEW: 工艺步骤定义
CREATE TABLE dim_process_step (
    step_id         SERIAL PRIMARY KEY,
    step_code       VARCHAR(20)  NOT NULL UNIQUE,
    step_name       VARCHAR(200) NOT NULL,
    category_id     INT          REFERENCES product.dim_component_category(category_id),
    step_seq        SMALLINT     NOT NULL DEFAULT 1,
    is_bottleneck   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_process_step IS '工艺步骤主数据，定义制造流程的工序序列';
COMMENT ON COLUMN dim_process_step.step_code IS '工序代码，如BAT-01(电极涂布)、BODY-01(Giga Press压铸)';
COMMENT ON COLUMN dim_process_step.category_id IS '所属品类，关联dim_component_category';
COMMENT ON COLUMN dim_process_step.step_seq IS '工序序号，同一品类内按此排序';
COMMENT ON COLUMN dim_process_step.is_bottleneck IS '是否为瓶颈工序，用于OEE分析';

-- ★ NEW: 工艺路线关联
CREATE TABLE fact_process_routing (
    routing_id      SERIAL PRIMARY KEY,
    component_id    INT          NOT NULL REFERENCES product.dim_component(component_id),
    step_id         INT          NOT NULL REFERENCES dim_process_step(step_id),
    line_id         INT          NOT NULL REFERENCES dim_production_line(line_id),
    std_cycle_time_sec NUMERIC(8,2),
    std_labor_hours_per_unit NUMERIC(6,4),
    UNIQUE (component_id, step_id)
);
COMMENT ON TABLE  fact_process_routing IS '工艺路线表，定义每个零部件经过的工序序列及其产线';
COMMENT ON COLUMN fact_process_routing.component_id IS '零部件ID，关联dim_component';
COMMENT ON COLUMN fact_process_routing.step_id IS '工序ID，关联dim_process_step';
COMMENT ON COLUMN fact_process_routing.line_id IS '执行产线ID，关联dim_production_line';
COMMENT ON COLUMN fact_process_routing.std_cycle_time_sec IS '标准加工周期（秒/件）';
COMMENT ON COLUMN fact_process_routing.std_labor_hours_per_unit IS '单位标准工时（人时/件）';

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
COMMENT ON TABLE  fact_production_order IS '生产订单事实表，含计划/实际数量、标准/实际成本三科目（材料/人工/制造费用）';
COMMENT ON COLUMN fact_production_order.prod_order_no IS '生产单号，格式PRD-YYYYMMDD-NNN';
COMMENT ON COLUMN fact_production_order.component_id IS '生产的零部件ID，关联dim_component';
COMMENT ON COLUMN fact_production_order.line_id IS '执行产线ID';
COMMENT ON COLUMN fact_production_order.factory_id IS '执行工厂ID';
COMMENT ON COLUMN fact_production_order.planned_qty IS '计划产量';
COMMENT ON COLUMN fact_production_order.actual_qty IS '实际产出量（合格品）';
COMMENT ON COLUMN fact_production_order.scrap_qty IS '报废量（不可返工）';
COMMENT ON COLUMN fact_production_order.planned_start IS '计划开工时间';
COMMENT ON COLUMN fact_production_order.actual_start IS '实际开工时间';
COMMENT ON COLUMN fact_production_order.status IS '生产状态：PLANNED/RELEASED/IN_PROGRESS/COMPLETED/CANCELLED';
COMMENT ON COLUMN fact_production_order.std_material_cost_usd IS '标准材料成本（USD），BOM标准用量×标准单价';
COMMENT ON COLUMN fact_production_order.actual_material_cost_usd IS '实际材料成本（USD），含采购价差+用量差';
COMMENT ON COLUMN fact_production_order.std_labor_cost_usd IS '标准人工成本（USD），标准工时×标准工资率';
COMMENT ON COLUMN fact_production_order.std_overhead_cost_usd IS '标准制造费用（USD），按预设费率分摊';
COMMENT ON COLUMN fact_production_order.actual_overhead_cost_usd IS '实际制造费用（USD），含能源/折旧/辅料等';
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
COMMENT ON COLUMN fact_quality_inspection.prod_order_id IS '关联生产订单';
COMMENT ON COLUMN fact_quality_inspection.inspected_qty IS '检验数量（抽样+全检）';
COMMENT ON COLUMN fact_quality_inspection.passed_qty IS '一次合格数量（直接放行）';
COMMENT ON COLUMN fact_quality_inspection.failed_qty IS '不合格数量（含返修+报废）';
COMMENT ON COLUMN fact_quality_inspection.rework_qty IS '返修后合格数量';
COMMENT ON COLUMN fact_quality_inspection.scrap_qty IS '最终报废数量';
COMMENT ON COLUMN fact_quality_inspection.defect_code IS '缺陷代码：WELD_POROSITY/PAINT_RUN/DIMENSION_OOT等';
COMMENT ON COLUMN fact_quality_inspection.inspector_id IS '检验员工号';
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
COMMENT ON COLUMN fact_scrap_event.prod_order_id IS '关联生产订单';
COMMENT ON COLUMN fact_scrap_event.component_id IS '报废零部件ID';
COMMENT ON COLUMN fact_scrap_event.scrap_qty IS '本次报废数量';
COMMENT ON COLUMN fact_scrap_event.scrap_reason IS '报废原因：来料不良/工艺失控/设备故障/操作失误等';
COMMENT ON COLUMN fact_scrap_event.scrap_cost_usd IS '废品损失金额（USD），= 报废数量×标准成本';
CREATE INDEX idx_scrap_date ON fact_scrap_event(scrap_date);

-- =============================================================================
-- SEED DATA — EV全球工厂 (5座整车+电池)
-- =============================================================================

INSERT INTO dim_factory (factory_code, factory_name, country_id, city, annual_capacity, headcount, iso_certified, iatf_certified, opened_date, renewable_energy_pct) VALUES
('FAC-FMT',  'Fremont Factory',        (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'Fremont, CA',    650000, 22000, TRUE, TRUE, '2010-04-01', 35.0),
('FAC-TXS',  'Giga Texas',             (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'Austin, TX',     250000, 12000, TRUE, TRUE, '2022-04-07', 65.0),
('FAC-SHA',  'Giga Shanghai',          (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'Shanghai',       950000, 19000, TRUE, TRUE, '2019-01-07', 45.0),
('FAC-BER',  'Giga Berlin',            (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'Grünheide',      250000, 11000, TRUE, TRUE, '2022-03-22', 100.0),
('FAC-NEV',  'Giga Nevada (Sparks)',   (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'Sparks, NV',     NULL,    8000, TRUE, TRUE, '2016-07-29', 60.0);

-- =============================================================================
-- SEED DATA — 产线 (匹配Mermaid制造流程图)
-- =============================================================================

INSERT INTO dim_production_line (line_code, line_name, factory_id, primary_category_id, designed_takt_sec, current_takt_sec, shift_count)
-- 电池包生产 (Giga Nevada: 4680 电极→卷绕→化成→CTC)
SELECT 'BAT-ELEC','干法/湿法电极涂布线',    f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'), 3.0, 3.2, 3 FROM dim_factory f WHERE f.factory_code='FAC-NEV'
UNION ALL
SELECT 'BAT-WIND','卷绕/组装线(4680)',      f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'), 2.5, 2.6, 3 FROM dim_factory f WHERE f.factory_code='FAC-NEV'
UNION ALL
SELECT 'BAT-FORM','化成/分容线',             f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'), 4.0, 4.1, 3 FROM dim_factory f WHERE f.factory_code='FAC-NEV'
UNION ALL
SELECT 'BAT-CTC','4680结构电池CTC成包线',    f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='BAT_PACK'), 6.0, 6.5, 2 FROM dim_factory f WHERE f.factory_code='FAC-TXS'

-- 车身制造 (Giga Texas: Giga Press→焊接→涂装   Fremont: 冲压→焊接→涂装)
UNION ALL
SELECT 'BDY-PRESS','Giga Press 6000T压铸线', f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='CASTING'), 90.0, 95.0, 2 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'BDY-STAMP','冲压线(钢/铝车身)',      f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='STAMPING'), 8.0, 8.5, 2 FROM dim_factory f WHERE f.factory_code='FAC-FMT'
UNION ALL
SELECT 'BDY-WELD','激光焊接/连接线',           f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='BODY'), 5.0, 5.2, 2 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'BDY-PAINT','涂装与表面处理线',         f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='BODY'), 8.0, 8.3, 2 FROM dim_factory f WHERE f.factory_code='FAC-FMT'

-- 电驱生产 (Giga Nevada: 定子/转子→SiC逆变器→齿轮箱→总成)
UNION ALL
SELECT 'DU-STAT','定子/转子制造线',           f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'), 5.0, 5.1, 3 FROM dim_factory f WHERE f.factory_code='FAC-NEV'
UNION ALL
SELECT 'DU-INV','SiC逆变器组装线',            f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 6.0, 6.2, 2 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'DU-GEAR','齿轮箱加工线',              f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='GEARBOX'), 5.0, 5.3, 2 FROM dim_factory f WHERE f.factory_code='FAC-FMT'
UNION ALL
SELECT 'DU-FINAL','电驱总成装配线',           f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'), 4.0, 4.2, 2 FROM dim_factory f WHERE f.factory_code='FAC-NEV'

-- FSD计算机 (Giga Texas: SMT贴片→组装灌胶→老化测试) — CONTRACT制造策略
UNION ALL
SELECT 'FSD-SMT','SMT高速贴片线',             f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD'), 3.0, 3.1, 1 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'FSD-ASM','FSD成品组装/灌胶线',         f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD'), 4.0, 4.2, 1 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'FSD-TEST','老化测试(Burn-in)线',      f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='FSD'), 8.0, 8.5, 1 FROM dim_factory f WHERE f.factory_code='FAC-TXS'

-- ★ 总装线 (Giga Texas + 上海)
UNION ALL
SELECT 'GA-TX','总装线(Texas)',              f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='VEHICLE'), 50.0, 52.0, 2 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
UNION ALL
SELECT 'GA-SHA','总装线(上海)',              f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='VEHICLE'), 38.0, 39.0, 3 FROM dim_factory f WHERE f.factory_code='FAC-SHA'
UNION ALL
SELECT 'GA-FMT','总装线(Fremont)',           f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='VEHICLE'), 60.0, 62.0, 2 FROM dim_factory f WHERE f.factory_code='FAC-FMT'
UNION ALL
SELECT 'GA-BER','总装线(Berlin)',            f.factory_id, (SELECT category_id FROM product.dim_component_category WHERE category_code='VEHICLE'), 55.0, 57.0, 2 FROM dim_factory f WHERE f.factory_code='FAC-BER';

-- =============================================================================
-- SEED DATA — 工艺步骤 (匹配Mermaid: 电池4步/车身4步/电驱4步/FSD4步)
-- =============================================================================

INSERT INTO dim_process_step (step_code, step_name, category_id, step_seq, is_bottleneck)
-- 电池包4步
SELECT 'BAT-01','干法/湿法电极涂布',cat.category_id,1,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BATTERY'
UNION ALL
SELECT 'BAT-02','卷绕/组装(4680圆柱)',cat.category_id,2,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BATTERY'
UNION ALL
SELECT 'BAT-03','化成/分容',cat.category_id,3,TRUE FROM product.dim_component_category cat WHERE cat.category_code='BATTERY'
UNION ALL
SELECT 'BAT-04','4680 CTC结构成包',cat.category_id,4,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BATTERY'

-- 车身制造4步
UNION ALL
SELECT 'BODY-01','铝液熔炼/压铸(Giga Press)',cat.category_id,1,TRUE FROM product.dim_component_category cat WHERE cat.category_code='BODY'
UNION ALL
SELECT 'BODY-02','冲压成型/压铸成型',cat.category_id,2,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BODY'
UNION ALL
SELECT 'BODY-03','激光焊接/结构连接',cat.category_id,3,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BODY'
UNION ALL
SELECT 'BODY-04','涂装与表面处理',cat.category_id,4,FALSE FROM product.dim_component_category cat WHERE cat.category_code='BODY'

-- 电驱生产4步
UNION ALL
SELECT 'DU-01','定子/转子制造',cat.category_id,1,FALSE FROM product.dim_component_category cat WHERE cat.category_code='DRIVE'
UNION ALL
SELECT 'DU-02','SiC逆变器组装',cat.category_id,2,FALSE FROM product.dim_component_category cat WHERE cat.category_code='DRIVE'
UNION ALL
SELECT 'DU-03','齿轮箱加工',cat.category_id,3,FALSE FROM product.dim_component_category cat WHERE cat.category_code='DRIVE'
UNION ALL
SELECT 'DU-04','电驱总成装配',cat.category_id,4,FALSE FROM product.dim_component_category cat WHERE cat.category_code='DRIVE'

-- FSD计算机4步 (CONTRACT: 芯片由TSMC代工，回厂后SMT+组装+老化)
UNION ALL
SELECT 'FSD-01','FSD芯片流片(TSMC代工)→回厂',cat.category_id,1,FALSE FROM product.dim_component_category cat WHERE cat.category_code='FSD'
UNION ALL
SELECT 'FSD-02','SMT高速贴片(自研PCB)',cat.category_id,2,FALSE FROM product.dim_component_category cat WHERE cat.category_code='FSD'
UNION ALL
SELECT 'FSD-03','成品组装与灌胶密封',cat.category_id,3,FALSE FROM product.dim_component_category cat WHERE cat.category_code='FSD'
UNION ALL
SELECT 'FSD-04','老化测试(Burn-in 168h)',cat.category_id,4,TRUE FROM product.dim_component_category cat WHERE cat.category_code='FSD'

-- 总装4步
UNION ALL
SELECT 'GA-01','各模块运至总装线边(齐套)',cat.category_id,1,FALSE FROM product.dim_component_category cat WHERE cat.category_code='VEHICLE'
UNION ALL
SELECT 'GA-02','总装(底盘/车身/电池合装)',cat.category_id,2,FALSE FROM product.dim_component_category cat WHERE cat.category_code='VEHICLE'
UNION ALL
SELECT 'GA-03','检测与标定(四轮定位/ADAS/淋雨)',cat.category_id,3,FALSE FROM product.dim_component_category cat WHERE cat.category_code='VEHICLE'
UNION ALL
SELECT 'GA-04','物流与交付(板车/滚装船)',cat.category_id,4,FALSE FROM product.dim_component_category cat WHERE cat.category_code='VEHICLE';

-- =============================================================================
-- SEED DATA — 工艺路线 (零部件→工序→产线)
-- =============================================================================

INSERT INTO fact_process_routing (component_id, step_id, line_id, std_cycle_time_sec, std_labor_hours_per_unit)
-- 4680电芯→电池包
SELECT c.component_id, s.step_id, l.line_id, 3.0, 0.02
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='4680-CELL' AND s.step_code='BAT-01' AND l.line_code='BAT-ELEC'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 2.5, 0.015
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='4680-CELL' AND s.step_code='BAT-02' AND l.line_code='BAT-WIND'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 4.0, 0.03
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='4680-CELL' AND s.step_code='BAT-03' AND l.line_code='BAT-FORM'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 6.0, 0.05
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='4680-PACK' AND s.step_code='BAT-04' AND l.line_code='BAT-CTC'

-- 前后压铸件→车身
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 90.0, 0.08
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='MEGACAST-R' AND s.step_code='BODY-01' AND l.line_code='BDY-PRESS'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 5.0, 0.04
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='MEGACAST-R' AND s.step_code='BODY-03' AND l.line_code='BDY-WELD'

-- 电驱总成路线
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 5.0, 0.06
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='DU-3D7' AND s.step_code='DU-01' AND l.line_code='DU-STAT'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 6.0, 0.04
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='DU-3D7' AND s.step_code='DU-02' AND l.line_code='DU-INV'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 5.0, 0.05
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='DU-3D7' AND s.step_code='DU-03' AND l.line_code='DU-GEAR'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 4.0, 0.07
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='DU-3D7' AND s.step_code='DU-04' AND l.line_code='DU-FINAL'

-- FSD计算机路线
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 3.0, 0.02
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='FSD-HW4' AND s.step_code='FSD-02' AND l.line_code='FSD-SMT'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 4.0, 0.03
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='FSD-HW4' AND s.step_code='FSD-03' AND l.line_code='FSD-ASM'
UNION ALL
SELECT c.component_id, s.step_id, l.line_id, 8.0, 0.06
FROM dim_component c, dim_process_step s, dim_production_line l
WHERE c.component_code='FSD-HW4' AND s.step_code='FSD-04' AND l.line_code='FSD-TEST';
