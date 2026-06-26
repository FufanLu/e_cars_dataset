-- =============================================================================
-- EV Parts Lakehouse - aftersales schema: 故障模式 / 保修索赔 / 现场失效
-- PostgreSQL 16
-- =============================================================================

SET search_path TO aftersales, sales, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_failure_mode (
    failure_id      SERIAL PRIMARY KEY,
    failure_code    VARCHAR(20)  NOT NULL UNIQUE,
    failure_name    VARCHAR(200) NOT NULL,
    component_category_id INT   REFERENCES product.dim_component_category(category_id),
    severity        VARCHAR(10)  CHECK (severity IN ('CRITICAL','MAJOR','MINOR')),
    avg_repair_cost_usd NUMERIC(12,4),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_failure_mode IS '故障模式主数据（FMEA导出）；severity分级';
COMMENT ON COLUMN dim_failure_mode.failure_code IS '故障代码，如FM-CELL-THERMAL(热失控)';
COMMENT ON COLUMN dim_failure_mode.component_category_id IS '关联零部件品类';
COMMENT ON COLUMN dim_failure_mode.severity IS '严重度：CRITICAL(安全相关)/MAJOR(功能失效)/MINOR(非关键)';
COMMENT ON COLUMN dim_failure_mode.avg_repair_cost_usd IS '平均修复成本（USD）';

CREATE TABLE fact_warranty_claim (
    claim_id        BIGSERIAL PRIMARY KEY,
    claim_no        VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES sales.dim_customer(customer_id),
    component_id    INT          NOT NULL REFERENCES product.dim_component(component_id),
    failure_id      INT          REFERENCES dim_failure_mode(failure_id),
    so_item_id      BIGINT       REFERENCES sales.fact_sales_order_item(so_item_id),
    claim_date      DATE         NOT NULL,
    failure_date    DATE,
    mileage_km      NUMERIC(10,2),
    claim_qty       NUMERIC(10,2) NOT NULL DEFAULT 1,
    claim_amount_usd NUMERIC(16,4) NOT NULL,
    approved_amount_usd NUMERIC(16,4),
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('OPEN','UNDER_REVIEW','APPROVED','REJECTED','PAID')),
    root_cause_analysis TEXT,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_warranty_claim IS '保修索赔事实表；关联销售行项目追溯源头批次';
COMMENT ON COLUMN fact_warranty_claim.claim_no IS '索赔号，格式WC-NNNNNNNNNN';
COMMENT ON COLUMN fact_warranty_claim.failure_id IS '故障模式ID，关联dim_failure_mode';
COMMENT ON COLUMN fact_warranty_claim.so_item_id IS '关联销售行项目，追溯生产批次';
COMMENT ON COLUMN fact_warranty_claim.mileage_km IS '故障发生里程（km）';
COMMENT ON COLUMN fact_warranty_claim.claim_amount_usd IS '索赔金额（USD）';
COMMENT ON COLUMN fact_warranty_claim.approved_amount_usd IS '核准赔付金额（USD）';
COMMENT ON COLUMN fact_warranty_claim.status IS '索赔状态：OPEN/UNDER_REVIEW/APPROVED/REJECTED/PAID';
COMMENT ON COLUMN fact_warranty_claim.root_cause_analysis IS '根因分析报告（文本）';
CREATE INDEX idx_wc_customer  ON fact_warranty_claim(customer_id);
CREATE INDEX idx_wc_component ON fact_warranty_claim(component_id);
CREATE INDEX idx_wc_date      ON fact_warranty_claim(claim_date);

CREATE TABLE fact_field_failure (
    ff_id           BIGSERIAL PRIMARY KEY,
    component_id    INT          NOT NULL REFERENCES product.dim_component(component_id),
    failure_id      INT          NOT NULL REFERENCES dim_failure_mode(failure_id),
    country_id      INT          NOT NULL REFERENCES geo.dim_country(country_id),
    failure_month   DATE         NOT NULL,
    units_in_field  NUMERIC(14,2) NOT NULL,
    failure_count   INT           NOT NULL,
    failure_rate_ppm NUMERIC(10,2) GENERATED ALWAYS AS (
        CASE WHEN units_in_field > 0 THEN failure_count::NUMERIC / units_in_field * 1000000 ELSE 0 END
    ) STORED,
    campaign_cost_usd NUMERIC(16,4),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_field_failure IS '现场失效率统计（按月/国家/零件）；PPM自动计算';
COMMENT ON COLUMN fact_field_failure.component_id IS '零部件ID';
COMMENT ON COLUMN fact_field_failure.failure_id IS '故障模式ID';
COMMENT ON COLUMN fact_field_failure.country_id IS '故障发生国家';
COMMENT ON COLUMN fact_field_failure.failure_month IS '统计月份';
COMMENT ON COLUMN fact_field_failure.units_in_field IS '该区域在保车辆数';
COMMENT ON COLUMN fact_field_failure.failure_count IS '本月失效次数';
COMMENT ON COLUMN fact_field_failure.failure_rate_ppm IS '失效率（生成列=failure_count/units_in_field*1M）';
COMMENT ON COLUMN fact_field_failure.campaign_cost_usd IS '召回/服务活动预算（USD）';
CREATE INDEX idx_ff_component ON fact_field_failure(component_id);
CREATE INDEX idx_ff_month     ON fact_field_failure(failure_month);

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_failure_mode (failure_code, failure_name, component_category_id, severity, avg_repair_cost_usd) VALUES
('FM-CELL-DENDRITE', 'Lithium Dendrite Penetration / Internal Short',     (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     'CRITICAL', 8500),
('FM-CELL-CAPACITY',  'Abnormal Capacity Fade (>20% in 3y)',              (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     'MAJOR',    3200),
('FM-CELL-THERMAL',   'Thermal Runaway Event',                             (SELECT category_id FROM product.dim_component_category WHERE category_code='CELL'),     'CRITICAL', 15000),
('FM-BMS-SOC-ERR',    'BMS State-of-Charge Estimation Error >5%',         (SELECT category_id FROM product.dim_component_category WHERE category_code='BMS'),      'MAJOR',    1200),
('FM-BMS-BALANCING',  'BMS Cell Balancing Circuit Failure',                (SELECT category_id FROM product.dim_component_category WHERE category_code='BMS'),      'MAJOR',    1800),
('FM-MTR-DEMAGNET',   'PMSM Permanent Magnet Demagnetization',             (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'),    'CRITICAL', 3800),
('FM-MTR-BEARING',    'Motor Bearing Premature Failure',                    (SELECT category_id FROM product.dim_component_category WHERE category_code='MOTOR'),    'MAJOR',    950),
('FM-INV-IGBT-FAIL',  'IGBT Module Open/Short Circuit Failure',            (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 'CRITICAL', 2200),
('FM-INV-OVERHEAT',   'Inverter Overtemperature Shutdown',                  (SELECT category_id FROM product.dim_component_category WHERE category_code='INVERTER'), 'MAJOR',    480),
('FM-CHARGE-FAIL',   'On-Board Charger Failure / Contactor Weld',          (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'), 'MAJOR',    750),
('FM-COOL-LEAK',      'Coolant Leak at Octovalve / Fitting',               (SELECT category_id FROM product.dim_component_category WHERE category_code='COOLING'),  'MAJOR',    620),
('FM-ECU-CAN-FAIL',   'CAN Bus Communication Loss / MCU Reset',            (SELECT category_id FROM product.dim_component_category WHERE category_code='ELECTRIC'), 'MINOR',    380);
