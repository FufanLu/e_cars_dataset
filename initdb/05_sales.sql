-- =============================================================================
-- EV Parts Lakehouse - sales schema: 客户 / 渠道 / 价格 / 销售订单
-- PostgreSQL 16
-- =============================================================================

SET search_path TO sales, production, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_customer (
    customer_id     SERIAL PRIMARY KEY,
    customer_code   VARCHAR(20)  NOT NULL UNIQUE,
    customer_name   VARCHAR(200) NOT NULL,
    country_id      INT          NOT NULL REFERENCES geo.dim_country(country_id),
    customer_type   VARCHAR(30)  CHECK (customer_type IN ('OEM','TIER1','DISTRIBUTOR','AFTERMARKET','GOVT')),
    credit_limit_usd NUMERIC(18,4),
    payment_terms_days INT       NOT NULL DEFAULT 45,
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    is_strategic    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_customer IS '客户主数据；customer_type 区分 OEM/经销商/售后等';

CREATE TABLE dim_sales_channel (
    channel_id      SERIAL PRIMARY KEY,
    channel_code    VARCHAR(20)  NOT NULL UNIQUE,
    channel_name    VARCHAR(100) NOT NULL,
    channel_type    VARCHAR(30)  CHECK (channel_type IN ('DIRECT','DISTRIBUTION','ONLINE','GOVT_TENDER')),
    commission_rate NUMERIC(6,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_sales_channel IS '销售渠道主数据，含佣金率';

CREATE TABLE fact_country_price_list (
    price_list_id   BIGSERIAL PRIMARY KEY,
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    country_id      INT           NOT NULL REFERENCES geo.dim_country(country_id),
    currency_id     INT           NOT NULL REFERENCES geo.dim_currency(currency_id),
    list_price      NUMERIC(14,4) NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    is_current      BOOLEAN       NOT NULL DEFAULT TRUE,
    UNIQUE (component_id, country_id, effective_from)
);
COMMENT ON TABLE  fact_country_price_list IS '分国家标准价格表；支持多币种、多时间段版本';
CREATE INDEX idx_cpl_component ON fact_country_price_list(component_id);
CREATE INDEX idx_cpl_country   ON fact_country_price_list(country_id);

CREATE TABLE fact_price_agreement (
    agreement_id    BIGSERIAL PRIMARY KEY,
    agreement_no    VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT          NOT NULL REFERENCES product.dim_component(component_id),
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    agreed_price    NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    min_qty_per_year NUMERIC(14,2),
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    is_active       BOOLEAN       NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_price_agreement IS '客户专项价格协议，优先级高于国家价格表';
CREATE INDEX idx_pa_customer  ON fact_price_agreement(customer_id);
CREATE INDEX idx_pa_component ON fact_price_agreement(component_id);

CREATE TABLE fact_sales_order (
    so_id           BIGSERIAL PRIMARY KEY,
    so_number       VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    channel_id      INT          NOT NULL REFERENCES dim_sales_channel(channel_id),
    order_date      DATE         NOT NULL,
    requested_delivery_date DATE,
    actual_delivery_date DATE,
    ship_from_factory_id INT     REFERENCES production.dim_factory(factory_id),
    ship_to_country_id   INT     NOT NULL REFERENCES geo.dim_country(country_id),
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    total_gross_revenue    NUMERIC(18,4) NOT NULL,
    total_discount         NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_net_revenue      NUMERIC(18,4) NOT NULL,
    total_std_material_cost NUMERIC(18,4),
    total_freight_cost     NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_tariff_cost      NUMERIC(18,4) NOT NULL DEFAULT 0,
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('DRAFT','CONFIRMED','SHIPPED','DELIVERED','INVOICED','CLOSED','CANCELLED')),
    incoterm        VARCHAR(10),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_sales_order IS '销售订单头表，聚合毛收入/净收入/成本/运费/关税';
CREATE INDEX idx_so_customer ON fact_sales_order(customer_id);
CREATE INDEX idx_so_date     ON fact_sales_order(order_date);
CREATE INDEX idx_so_country  ON fact_sales_order(ship_to_country_id);

CREATE TABLE fact_sales_order_item (
    so_item_id      BIGSERIAL PRIMARY KEY,
    so_id           BIGINT        NOT NULL REFERENCES fact_sales_order(so_id),
    item_seq        SMALLINT      NOT NULL DEFAULT 10,
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    qty             NUMERIC(12,2) NOT NULL,
    list_price      NUMERIC(14,4) NOT NULL,
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    net_unit_price  NUMERIC(14,4) NOT NULL,
    gross_line_amount NUMERIC(18,4) NOT NULL,
    net_line_amount   NUMERIC(18,4) NOT NULL,
    std_material_cost NUMERIC(14,4),
    manufacturing_cost NUMERIC(14,4),
    UNIQUE (so_id, item_seq)
);
COMMENT ON TABLE  fact_sales_order_item IS '销售订单行项目，含标准成本、制造成本分摊';
CREATE INDEX idx_soi_so        ON fact_sales_order_item(so_id);
CREATE INDEX idx_soi_component ON fact_sales_order_item(component_id);

CREATE TABLE fact_rebate (
    rebate_id       BIGSERIAL PRIMARY KEY,
    customer_id     INT           NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT           REFERENCES product.dim_component(component_id),
    period_year     SMALLINT      NOT NULL,
    period_quarter  SMALLINT,
    rebate_type     VARCHAR(30)   CHECK (rebate_type IN ('VOLUME','ANNUAL','PROMO','LOYALTY')),
    rebate_amount_usd NUMERIC(16,4) NOT NULL,
    basis_revenue_usd NUMERIC(16,4),
    rebate_rate     NUMERIC(6,4),
    paid_date       DATE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_rebate IS '返利事实表；影响净收入口径（从 Net Revenue 中扣除）';

CREATE TABLE fact_volume_discount (
    vd_id           BIGSERIAL PRIMARY KEY,
    customer_id     INT           NOT NULL REFERENCES dim_customer(customer_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    tier_from_qty   NUMERIC(14,2) NOT NULL,
    tier_to_qty     NUMERIC(14,2),
    discount_pct    NUMERIC(6,4)  NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_volume_discount IS '阶梯数量折扣协议';

-- =============================================================================
-- SEED DATA
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
('CUST-VW-DE',    'Volkswagen Group',            (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'OEM',         50000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-BMW-DE',   'BMW Group',                   (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'OEM',         40000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-STELLANT', 'Stellantis EV Procurement',   (SELECT country_id FROM geo.dim_country WHERE country_code='FR'), 'OEM',         35000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), TRUE),
('CUST-FORD-US',  'Ford Motor Company',           (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'OEM',         30000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE),
('CUST-GM-US',    'General Motors EV',            (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'OEM',         30000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), TRUE),
('CUST-HONDA-JP', 'Honda Motor Co.',              (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 'OEM',         25000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), TRUE),
('CUST-HYUNDAI',  'Hyundai Motor Group',          (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 'OEM',         28000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='KRW'), TRUE),
('CUST-TATA-IN',  'Tata Motors EV',               (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), 'OEM',         10000000, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='INR'), FALSE),
('CUST-RENAULT',  'Renault EV Division',          (SELECT country_id FROM geo.dim_country WHERE country_code='FR'), 'OEM',         15000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-LEAPMOTOR','Leapmotor Technology',          (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'OEM',         12000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), FALSE),
('CUST-ZEEKR-CN', 'Zeekr Intelligent Tech',       (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'OEM',         20000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), TRUE),
('CUST-MAGNA-CA', 'Magna International',           (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'TIER1',       8000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE),
('CUST-DENSO-JP', 'Denso Corporation',             (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 'TIER1',       9000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), FALSE),
('CUST-DIST-SG',  'EV Parts Asia Distribution',   (SELECT country_id FROM geo.dim_country WHERE country_code='SG'), 'DISTRIBUTOR', 5000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE),
('CUST-DIST-GB',  'European EV Components Ltd',   (SELECT country_id FROM geo.dim_country WHERE country_code='GB'), 'DISTRIBUTOR', 4000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='GBP'), FALSE),
('CUST-GOVT-DE',  'German Federal Procurement',   (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'GOVT',        6000000, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-GOVT-US',  'US DOE / Federal Fleet',        (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'GOVT',        8000000, 90, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE),
('CUST-TOYOTA-JP','Toyota Motor Corporation',      (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 'OEM',         35000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), TRUE),
('CUST-VOLVO-SE', 'Volvo Cars EV',                 (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'OEM',         18000000, 60, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), FALSE),
('CUST-RIVIAN-US','Rivian Automotive',             (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'OEM',         15000000, 45, (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), FALSE);

INSERT INTO fact_country_price_list (component_id, country_id, currency_id, list_price, effective_from, is_current) VALUES
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), 80000,  '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), 11200,  '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), 11800,  '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='JPY'), 1650000,'2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='GB'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='GBP'), 9500,   '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-100-NMC'), (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='INR'), 990000, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), 57000,  '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), 7800,   '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), 8200,   '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='BP-075-LFP'), (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='INR'), 680000, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), 20000, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), 2600, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='MTR-200KW-PMSM'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), 2750, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='CNY'), 9500, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='EUR'), 1300, '2024-01-01', TRUE),
((SELECT component_id FROM product.dim_component WHERE component_code='INV-200KW-SIC'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), (SELECT currency_id FROM geo.dim_currency WHERE currency_code='USD'), 1380, '2024-01-01', TRUE);
