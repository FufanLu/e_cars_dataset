-- =============================================================================
-- EV Parts Lakehouse - geo schema: 国家 / 币种 / 地区
-- PostgreSQL 16
-- =============================================================================

SET search_path TO geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_region (
    region_id     SERIAL PRIMARY KEY,
    region_code   VARCHAR(10)  NOT NULL UNIQUE,
    region_name   VARCHAR(100) NOT NULL,
    created_at    TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_region IS '销售/生产大区：APAC、EMEA、AMER 等';
COMMENT ON COLUMN dim_region.region_code IS '内部大区代码，如 APAC';

CREATE TABLE dim_currency (
    currency_id     SERIAL PRIMARY KEY,
    currency_code   CHAR(3)      NOT NULL UNIQUE,  -- ISO 4217
    currency_name   VARCHAR(80)  NOT NULL,
    symbol          VARCHAR(5),
    decimal_places  SMALLINT     NOT NULL DEFAULT 2,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_currency IS 'ISO 4217 货币主数据';
COMMENT ON COLUMN dim_currency.currency_code IS 'ISO 4217 三字母代码，如 CNY';

CREATE TABLE dim_country (
    country_id      SERIAL PRIMARY KEY,
    country_code    CHAR(2)       NOT NULL UNIQUE,  -- ISO 3166-1 alpha-2
    country_name    VARCHAR(100)  NOT NULL,
    region_id       INT           NOT NULL REFERENCES dim_region(region_id),
    currency_id     INT           NOT NULL REFERENCES dim_currency(currency_id),
    vat_rate        NUMERIC(6,4),   -- 增值税率 e.g. 0.2000 = 20%
    corporate_tax_rate NUMERIC(6,4),
    is_eu_member    BOOLEAN       NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_country IS 'ISO 3166-1 国家主数据，含税率、大区、本币';
COMMENT ON COLUMN dim_country.vat_rate IS '当地增值税 / GST 税率（小数形式）';

-- =============================================================================
-- SEED DATA
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
('SGD', 'Singapore Dollar',   'S$', 2),
('TWD', 'New Taiwan Dollar',  'NT$',2),
('CHF', 'Swiss Franc',        'Fr', 2),
('AUD', 'Australian Dollar',  'A$', 2),
('CAD', 'Canadian Dollar',    'C$', 2),
('NOK', 'Norwegian Krone',    'kr', 2),
('SEK', 'Swedish Krona',      'kr', 2);

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
('SG', 'Singapore',      (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='SGD'), 0.0900, 0.1700, FALSE),

-- 扩展国家 (Tesla主要市场 + 供应链来源国)
('TW', 'Taiwan',         (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='TWD'), 0.0500, 0.2000, FALSE),
('CH', 'Switzerland',    (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='CHF'), 0.0770, 0.1450, FALSE),
('FI', 'Finland',        (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 0.2400, 0.2000, TRUE),
('NL', 'Netherlands',    (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='EUR'), 0.2100, 0.2580, TRUE),
('CL', 'Chile',          (SELECT region_id FROM dim_region WHERE region_code='AMER'),  (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 0.1900, 0.2700, FALSE),
('ID', 'Indonesia',      (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 0.1100, 0.2200, FALSE),
('CD', 'DR Congo',       (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 0.1600, 0.3000, FALSE),
('SA', 'Saudi Arabia',   (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='USD'), 0.1500, 0.2000, FALSE),
('AU', 'Australia',      (SELECT region_id FROM dim_region WHERE region_code='APAC'),  (SELECT currency_id FROM dim_currency WHERE currency_code='AUD'), 0.1000, 0.3000, FALSE),
('NO', 'Norway',         (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='NOK'), 0.2500, 0.2200, FALSE),
('SE', 'Sweden',         (SELECT region_id FROM dim_region WHERE region_code='EMEA'),  (SELECT currency_id FROM dim_currency WHERE currency_code='SEK'), 0.2500, 0.2060, TRUE),
('CA', 'Canada',         (SELECT region_id FROM dim_region WHERE region_code='AMER'),  (SELECT currency_id FROM dim_currency WHERE currency_code='CAD'), 0.0500, 0.2679, FALSE);
