-- =============================================================================
-- EV Parts Lakehouse - finance schema: 汇率 / 利率 / 应收 / 库存持有成本
-- PostgreSQL 16
-- =============================================================================

SET search_path TO finance, inventory, sales, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE fact_exchange_rate_daily (
    fx_id           BIGSERIAL PRIMARY KEY,
    rate_date       DATE          NOT NULL,
    from_currency_id INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    to_currency_id  INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    rate            NUMERIC(18,8) NOT NULL,
    rate_source     VARCHAR(30)  DEFAULT 'ECB',
    UNIQUE (rate_date, from_currency_id, to_currency_id)
);
COMMENT ON TABLE  fact_exchange_rate_daily IS '每日汇率，支持任意货币对；用于FX Impact计算';
COMMENT ON COLUMN fact_exchange_rate_daily.from_currency_id IS '来源币种';
COMMENT ON COLUMN fact_exchange_rate_daily.to_currency_id IS '目标币种';
COMMENT ON COLUMN fact_exchange_rate_daily.rate IS '汇率（1单位来源币种=多少目标币种）';
COMMENT ON COLUMN fact_exchange_rate_daily.rate_source IS '汇率来源：ECB/XE/OANDA';
CREATE INDEX idx_fx_date ON fact_exchange_rate_daily(rate_date DESC);

CREATE TABLE fact_interest_rate_daily (
    ir_id           BIGSERIAL PRIMARY KEY,
    rate_date       DATE          NOT NULL,
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    rate_type       VARCHAR(30)   NOT NULL CHECK (rate_type IN ('CENTRAL_BANK','LIBOR_3M','SOFR','EURIBOR_3M','SHIBOR_3M','LPR_1Y')),
    rate_pct        NUMERIC(8,4)  NOT NULL,
    UNIQUE (rate_date, country_id, rate_type)
);
COMMENT ON TABLE  fact_interest_rate_daily IS '各国基准利率日表；用于库存资金占用成本和应收融资成本计算';
COMMENT ON COLUMN fact_interest_rate_daily.rate_type IS '利率类型：SOFR(美国)/EURIBOR_3M(欧元区)/LPR_1Y(中国)/CENTRAL_BANK';
COMMENT ON COLUMN fact_interest_rate_daily.rate_pct IS '年化利率（%），用于折现和融资成本计算';

CREATE TABLE fact_receivable_aging (
    aging_id        BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE          NOT NULL,
    customer_id     INT           NOT NULL REFERENCES sales.dim_customer(customer_id),
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    currency_id     INT           NOT NULL REFERENCES geo.dim_currency(currency_id),
    bucket_0_30     NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_31_60    NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_61_90    NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_91_180   NUMERIC(18,4) NOT NULL DEFAULT 0,
    bucket_over_180 NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_outstanding NUMERIC(18,4) GENERATED ALWAYS AS (
        bucket_0_30 + bucket_31_60 + bucket_61_90 + bucket_91_180 + bucket_over_180
    ) STORED,
    financing_cost_usd NUMERIC(16,4),
    UNIQUE (snapshot_date, customer_id)
);
COMMENT ON TABLE  fact_receivable_aging IS '应收账款账龄快照；financing_cost = outstanding * ir * days/360';
COMMENT ON COLUMN fact_receivable_aging.bucket_0_30 IS '0-30天应收账款（USD）';
COMMENT ON COLUMN fact_receivable_aging.bucket_31_60 IS '31-60天应收账款（USD）';
COMMENT ON COLUMN fact_receivable_aging.bucket_61_90 IS '61-90天应收账款（USD）';
COMMENT ON COLUMN fact_receivable_aging.bucket_91_180 IS '91-180天应收账款（USD）';
COMMENT ON COLUMN fact_receivable_aging.bucket_over_180 IS '>180天应收账款（USD）';
COMMENT ON COLUMN fact_receivable_aging.total_outstanding IS '应收总额（USD，生成列=各账龄段之和）';
COMMENT ON COLUMN fact_receivable_aging.financing_cost_usd IS '融资成本（USD）= 应收总额 × 利率 × 天数/360';
CREATE INDEX idx_recv_date     ON fact_receivable_aging(snapshot_date DESC);
CREATE INDEX idx_recv_customer ON fact_receivable_aging(customer_id);

CREATE TABLE fact_inventory_carrying_cost (
    icc_id          BIGSERIAL PRIMARY KEY,
    period_date     DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES inventory.dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    avg_inventory_value_usd NUMERIC(18,4) NOT NULL,
    interest_rate_pct       NUMERIC(8,4)  NOT NULL,
    storage_cost_rate_pct   NUMERIC(8,4)  NOT NULL DEFAULT 2.0,
    obsolescence_rate_pct   NUMERIC(8,4)  NOT NULL DEFAULT 1.5,
    carrying_cost_usd       NUMERIC(16,4) NOT NULL,
    UNIQUE (period_date, warehouse_id, component_id)
);
COMMENT ON TABLE  fact_inventory_carrying_cost IS '库存持有成本 = 库存价值 * (利率+仓储率+过时率) * 天数/365';
COMMENT ON COLUMN fact_inventory_carrying_cost.avg_inventory_value_usd IS '平均库存价值（USD）';
COMMENT ON COLUMN fact_inventory_carrying_cost.interest_rate_pct IS '资金成本利率（%）';
COMMENT ON COLUMN fact_inventory_carrying_cost.storage_cost_rate_pct IS '仓储费率（%/年）';
COMMENT ON COLUMN fact_inventory_carrying_cost.obsolescence_rate_pct IS '过时风险费率（%/年）';
COMMENT ON COLUMN fact_inventory_carrying_cost.carrying_cost_usd IS '持有成本总额（USD）';
CREATE INDEX idx_icc_date ON fact_inventory_carrying_cost(period_date DESC);
