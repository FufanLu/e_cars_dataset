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
    renewable_pct   NUMERIC(6,4)  NOT NULL DEFAULT 0,
    UNIQUE (factory_id, period_month, scope_id, energy_type)
);
COMMENT ON TABLE  fact_factory_energy_consumption IS '工厂能耗碳排放（月度）；tCO2e = 吨二氧化碳当量';
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
COMMENT ON TABLE  fact_component_carbon_footprint IS '单位产品碳足迹（PCF），按工厂+年度';
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
COMMENT ON TABLE  fact_supplier_esg_score IS '供应商 ESG 评分（年度）；与供应商质量联合分析供应链风险';

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
COMMENT ON TABLE  fact_shipping_emission IS '运输碳排放；scope3 物流碳排 = 重量(t) * 距离(km) * 排放因子';

CREATE TABLE fact_carbon_price (
    cp_id           BIGSERIAL PRIMARY KEY,
    price_date      DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    scheme          VARCHAR(50)   NOT NULL,
    price_usd_per_tco2e NUMERIC(12,4) NOT NULL,
    UNIQUE (price_date, country_id, scheme)
);
COMMENT ON TABLE  fact_carbon_price IS '碳价格（每日，按国家/碳市场）；EU ETS 约 60-90 USD/tCO2e';
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
COMMENT ON TABLE  fact_carbon_tax IS '工厂碳税月度汇总；taxable = total - free_allowance';
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
COMMENT ON TABLE  fact_carbon_credit IS '碳信用购买与注销记录';

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_emission_scope (scope_code, scope_name, description) VALUES
('S1', 'Scope 1', 'Direct GHG emissions from owned/controlled sources (fuel combustion, process emissions)'),
('S2', 'Scope 2', 'Indirect GHG from purchased electricity, steam, heat, and cooling'),
('S3', 'Scope 3', 'All other indirect emissions in value chain (upstream materials, logistics, use-phase, EoL)');
