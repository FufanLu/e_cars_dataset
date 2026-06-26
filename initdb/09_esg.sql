-- =============================================================================
-- EV Parts Lakehouse - esg schema: 碳排放 / 能源 / 碳价 / 碳税 / 碳信用
-- PostgreSQL 16
-- =============================================================================

SET search_path TO esg, logistics, procurement, production, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_emission_scope (
    scope_id        SERIAL PRIMARY KEY,
    scope_code      VARCHAR(10)  NOT NULL UNIQUE,
    scope_name      VARCHAR(100) NOT NULL,
    description     TEXT
);
COMMENT ON TABLE  dim_emission_scope IS 'GHG Protocol Scope 1/2/3 分类';
COMMENT ON COLUMN dim_emission_scope.scope_code IS '范围代码：S1(直接排放)/S2(电力间接)/S3(价值链)';
COMMENT ON COLUMN dim_emission_scope.description IS '定义说明，参考GHG Protocol Corporate Standard';

CREATE TABLE fact_factory_energy_consumption (
    energy_id       BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES production.dim_factory(factory_id),
    period_month    DATE          NOT NULL,
    scope_id        INT           NOT NULL REFERENCES dim_emission_scope(scope_id),
    energy_type     VARCHAR(30)   CHECK (energy_type IN ('GRID_ELEC','NATURAL_GAS','DIESEL','RENEWABLE','COAL','STEAM')),
    consumption_kwh NUMERIC(16,4),
    consumption_mj  NUMERIC(16,4),
    emission_factor_kgco2e_per_kwh NUMERIC(10,6),
    total_emission_tco2e   NUMERIC(14,4) NOT NULL,
    renewable_pct   NUMERIC(5,2)  NOT NULL DEFAULT 0,
    UNIQUE (factory_id, period_month, scope_id, energy_type)
);
COMMENT ON TABLE  fact_factory_energy_consumption IS '工厂能耗碳排放（月度）；tCO2e = 吨二氧化碳当量';
COMMENT ON COLUMN fact_factory_energy_consumption.period_month IS '统计月份';
COMMENT ON COLUMN fact_factory_energy_consumption.scope_id IS '排放Scope：S1=直接(天然气)/S2=间接(购电)';
COMMENT ON COLUMN fact_factory_energy_consumption.energy_type IS '能源类型：GRID_ELEC(市电)/NATURAL_GAS(天然气)/RENEWABLE(可再生能源)';
COMMENT ON COLUMN fact_factory_energy_consumption.consumption_kwh IS '用电量（kWh）';
COMMENT ON COLUMN fact_factory_energy_consumption.consumption_mj IS '能耗（MJ），用于非电力能源';
COMMENT ON COLUMN fact_factory_energy_consumption.emission_factor_kgco2e_per_kwh IS '排放因子（kgCO2e/kWh），中国电网~0.581, 德国~0.366';
COMMENT ON COLUMN fact_factory_energy_consumption.total_emission_tco2e IS '总排放（吨CO2当量）';
COMMENT ON COLUMN fact_factory_energy_consumption.renewable_pct IS '可再生能源占比（%），Berlin~100%, Texas~65%';
CREATE INDEX idx_fec_factory ON fact_factory_energy_consumption(factory_id);
CREATE INDEX idx_fec_month   ON fact_factory_energy_consumption(period_month);

CREATE TABLE fact_component_carbon_footprint (
    footprint_id    BIGSERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    factory_id      INT           NOT NULL REFERENCES production.dim_factory(factory_id),
    calc_year       SMALLINT      NOT NULL,
    scope1_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    scope2_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    scope3_kgco2e_per_unit NUMERIC(12,6) NOT NULL DEFAULT 0,
    total_kgco2e_per_unit  NUMERIC(12,6) GENERATED ALWAYS AS (
        scope1_kgco2e_per_unit + scope2_kgco2e_per_unit + scope3_kgco2e_per_unit
    ) STORED,
    cert_standard   VARCHAR(30),
    UNIQUE (component_id, factory_id, calc_year)
);
COMMENT ON TABLE  fact_component_carbon_footprint IS '单位产品碳足迹（PCF），按工厂+年度，ISO 14067标准';
COMMENT ON COLUMN fact_component_carbon_footprint.calc_year IS '计算年度';
COMMENT ON COLUMN fact_component_carbon_footprint.scope1_kgco2e_per_unit IS 'Scope1 直接碳排（kgCO2e/件）';
COMMENT ON COLUMN fact_component_carbon_footprint.scope2_kgco2e_per_unit IS 'Scope2 电力间接碳排（kgCO2e/件）';
COMMENT ON COLUMN fact_component_carbon_footprint.scope3_kgco2e_per_unit IS 'Scope3 价值链碳排（kgCO2e/件），含原材料+运输';
COMMENT ON COLUMN fact_component_carbon_footprint.total_kgco2e_per_unit IS '总碳足迹（生成列=S1+S2+S3）';
COMMENT ON COLUMN fact_component_carbon_footprint.cert_standard IS '认证标准：ISO 14067/PAS 2050';
CREATE INDEX idx_ccf_component ON fact_component_carbon_footprint(component_id);
CREATE INDEX idx_ccf_factory   ON fact_component_carbon_footprint(factory_id);

CREATE TABLE fact_supplier_esg_score (
    esg_id          BIGSERIAL PRIMARY KEY,
    supplier_id     INT           NOT NULL REFERENCES procurement.dim_supplier(supplier_id),
    assess_year     SMALLINT      NOT NULL,
    env_score       NUMERIC(5,2),
    social_score    NUMERIC(5,2),
    governance_score NUMERIC(5,2),
    overall_score   NUMERIC(5,2),
    carbon_intensity_tco2e_per_mrevenue NUMERIC(10,4),
    water_usage_m3_per_unit NUMERIC(10,4),
    assessor        VARCHAR(100),
    UNIQUE (supplier_id, assess_year)
);
COMMENT ON TABLE  fact_supplier_esg_score IS '供应商ESG评分（年度）；与供应商质量联合分析供应链风险';
COMMENT ON COLUMN fact_supplier_esg_score.assess_year IS '评估年度';
COMMENT ON COLUMN fact_supplier_esg_score.env_score IS '环境评分（0-100），含碳排/水耗/废物管理';
COMMENT ON COLUMN fact_supplier_esg_score.social_score IS '社会评分（0-100），含劳工/安全/社区';
COMMENT ON COLUMN fact_supplier_esg_score.governance_score IS '治理评分（0-100），含合规/反腐败/供应链透明';
COMMENT ON COLUMN fact_supplier_esg_score.overall_score IS 'ESG综合评分 = (E+S+G)/3';
COMMENT ON COLUMN fact_supplier_esg_score.carbon_intensity_tco2e_per_mrevenue IS '碳强度（tCO2e/百万USD营收）';

CREATE TABLE fact_shipping_emission (
    se_id           BIGSERIAL PRIMARY KEY,
    shipping_id     BIGINT        NOT NULL REFERENCES logistics.fact_shipping_order(shipping_id),
    transport_mode  VARCHAR(20)   NOT NULL,
    distance_km     NUMERIC(10,2),
    weight_mt       NUMERIC(12,4),
    emission_factor_kgco2e_per_tkm NUMERIC(10,6),
    total_emission_kgco2e NUMERIC(14,4) NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_shipping_emission IS '运输碳排放（Scope3）；碳排 = 重量(t) × 距离(km) × 排放因子(kgCO2e/tkm)';
COMMENT ON COLUMN fact_shipping_emission.transport_mode IS '运输方式：SEA(0.011)/AIR(0.602)/ROAD(0.095) 排放因子各不相同';
COMMENT ON COLUMN fact_shipping_emission.distance_km IS '运输距离（km）';
COMMENT ON COLUMN fact_shipping_emission.weight_mt IS '货物重量（公吨）';
COMMENT ON COLUMN fact_shipping_emission.emission_factor_kgco2e_per_tkm IS '排放因子（kgCO2e/吨公里），海运最低0.011，空运最高0.602';

CREATE TABLE fact_carbon_price (
    cp_id           BIGSERIAL PRIMARY KEY,
    price_date      DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    scheme          VARCHAR(50)   NOT NULL,
    price_usd_per_tco2e NUMERIC(12,4) NOT NULL,
    UNIQUE (price_date, country_id, scheme)
);
COMMENT ON TABLE  fact_carbon_price IS '碳价格（每周，按国家/碳市场）；EU ETS约70-80 EUR/tCO2e';
COMMENT ON COLUMN fact_carbon_price.scheme IS '碳市场名称：EU ETS/UK ETS/California CAP/CCER/K-ETS';
COMMENT ON COLUMN fact_carbon_price.price_usd_per_tco2e IS '碳价（USD/tCO2e）';
CREATE INDEX idx_cp_date ON fact_carbon_price(price_date DESC);

CREATE TABLE fact_carbon_tax (
    ct_id           BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES production.dim_factory(factory_id),
    period_month    DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    total_emission_tco2e   NUMERIC(14,4) NOT NULL,
    free_allowance_tco2e   NUMERIC(14,4) NOT NULL DEFAULT 0,
    taxable_emission_tco2e NUMERIC(14,4) NOT NULL,
    carbon_price_usd_per_tco2e NUMERIC(12,4) NOT NULL,
    carbon_tax_usd  NUMERIC(16,4) NOT NULL,
    UNIQUE (factory_id, period_month)
);
COMMENT ON TABLE  fact_carbon_tax IS '工厂碳税月度汇总（EU ETS）；taxable = total - free_allowance';
COMMENT ON COLUMN fact_carbon_tax.total_emission_tco2e IS '总排放（tCO2e）';
COMMENT ON COLUMN fact_carbon_tax.free_allowance_tco2e IS '免费配额（tCO2e），EU ETS当前约30%免费';
COMMENT ON COLUMN fact_carbon_tax.taxable_emission_tco2e IS '应税排放 = 总排放-免费配额';
COMMENT ON COLUMN fact_carbon_tax.carbon_price_usd_per_tco2e IS '当期碳价（USD/tCO2e），取自fact_carbon_price';
COMMENT ON COLUMN fact_carbon_tax.carbon_tax_usd IS '碳税金额（USD）= 应税排放 × 碳价';
CREATE INDEX idx_ct_factory ON fact_carbon_tax(factory_id);

CREATE TABLE fact_carbon_credit (
    credit_id       BIGSERIAL PRIMARY KEY,
    factory_id      INT           NOT NULL REFERENCES production.dim_factory(factory_id),
    credit_date     DATE          NOT NULL,
    credit_type     VARCHAR(30)   CHECK (credit_type IN ('VCS','GOLD_STANDARD','CDM','CCER','I_REC')),
    qty_tco2e       NUMERIC(14,4) NOT NULL,
    purchase_price_usd NUMERIC(12,4),
    total_cost_usd  NUMERIC(16,4),
    retired_qty     NUMERIC(14,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_carbon_credit IS '碳信用购买与注销记录；用于抵消Scope1排放';
COMMENT ON COLUMN fact_carbon_credit.credit_type IS '碳信用类型：VCS(自愿碳标准)/GOLD_STANDARD/CDM(清洁发展)/CCER(中国核证)/I_REC(可再生能源证书)';
COMMENT ON COLUMN fact_carbon_credit.qty_tco2e IS '购买数量（tCO2e）';
COMMENT ON COLUMN fact_carbon_credit.purchase_price_usd IS '购买单价（USD/tCO2e）';
COMMENT ON COLUMN fact_carbon_credit.total_cost_usd IS '总成本（USD）';
COMMENT ON COLUMN fact_carbon_credit.retired_qty IS '已注销数量（tCO2e），注销后不可再交易';

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_emission_scope (scope_code, scope_name, description) VALUES
('S1', 'Scope 1', 'Direct GHG emissions from owned/controlled sources (fuel combustion, process emissions)'),
('S2', 'Scope 2', 'Indirect GHG from purchased electricity, steam, heat, and cooling'),
('S3', 'Scope 3', 'All other indirect emissions in value chain (upstream materials, logistics, use-phase, EoL)');
