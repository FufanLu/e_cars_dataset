-- =============================================================================
-- Tesla OEM Lakehouse - sales schema: 直销 / 消费者 / 订单
-- Tesla直销模式: 无经销商、无返利、无大客户协议价、全球统一定价(仅按国家微调)
-- 删除的B2B表: fact_country_price_list, fact_price_agreement, fact_rebate, fact_volume_discount
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
    customer_type   VARCHAR(30)  CHECK (customer_type IN ('CONSUMER','FLEET','LEASE','GOVT')),
    credit_limit_usd NUMERIC(18,4),
    payment_terms_days INT       NOT NULL DEFAULT 0,
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    is_strategic    BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_customer IS 'Tesla终端客户；CONSUMER=个人直销, FLEET=企业车队, LEASE=租赁公司, GOVT=政府采购';
COMMENT ON COLUMN dim_customer.customer_code IS '客户代码，个人消费者使用CUST-NNNNN格式';
COMMENT ON COLUMN dim_customer.customer_type IS '客户类型: CONSUMER(个人)/FLEET(企业车队)/LEASE(租赁)/GOVT(政府)';
COMMENT ON COLUMN dim_customer.credit_limit_usd IS '信用额度（USD），个人消费者为0';
COMMENT ON COLUMN dim_customer.payment_terms_days IS '付款条件(天)，Tesla直销通常为0(全款预付)';
COMMENT ON COLUMN dim_customer.is_strategic IS '是否战略客户（大企业车队/政府采购）';

CREATE TABLE dim_sales_channel (
    channel_id      SERIAL PRIMARY KEY,
    channel_code    VARCHAR(20)  NOT NULL UNIQUE,
    channel_name    VARCHAR(100) NOT NULL,
    channel_type    VARCHAR(30)  CHECK (channel_type IN ('DIRECT','ONLINE','FLEET','GOVT_TENDER')),
    commission_rate NUMERIC(6,4) NOT NULL DEFAULT 0,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_sales_channel IS 'Tesla销售渠道；DIRECT=官网直销, FLEET=企业批量, GOVT_TENDER=政府采购, ONLINE=线上';
COMMENT ON COLUMN dim_sales_channel.channel_code IS '渠道代码：DIRECT/FLEET/GOVT_SALE/REFERRAL';
COMMENT ON COLUMN dim_sales_channel.channel_type IS '渠道类型：DIRECT/ONLINE/FLEET/GOVT_TENDER';
COMMENT ON COLUMN dim_sales_channel.commission_rate IS '渠道佣金率，Tesla直销为0，推荐计划0.5%';

CREATE TABLE fact_sales_order (
    so_id           BIGSERIAL PRIMARY KEY,
    so_number       VARCHAR(30)  NOT NULL UNIQUE,
    customer_id     INT          NOT NULL REFERENCES dim_customer(customer_id),
    channel_id      INT          NOT NULL REFERENCES dim_sales_channel(channel_id),
    order_date      DATE         NOT NULL,
    requested_delivery_date DATE,
    actual_delivery_date    DATE,
    ship_from_factory_id INT  NOT NULL REFERENCES production.dim_factory(factory_id),
    ship_to_country_id   INT  NOT NULL REFERENCES geo.dim_country(country_id),
    currency_id     INT          NOT NULL REFERENCES geo.dim_currency(currency_id),
    total_gross_revenue NUMERIC(18,4) NOT NULL,
    total_discount       NUMERIC(18,4) NOT NULL DEFAULT 0,
    total_net_revenue    NUMERIC(18,4) NOT NULL,
    total_std_material_cost NUMERIC(18,4),
    total_freight_cost  NUMERIC(16,4) NOT NULL DEFAULT 0,
    total_tariff_cost   NUMERIC(16,4) NOT NULL DEFAULT 0,
    vin             VARCHAR(17),
    status          VARCHAR(20)  NOT NULL CHECK (status IN ('RESERVED','CONFIRMED','IN_PRODUCTION','IN_TRANSIT','DELIVERED','CANCELLED')),
    incoterm        VARCHAR(10),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_sales_order IS 'Tesla车辆销售订单；每订单=1辆整车(唯一VIN)，直销无中间商';
COMMENT ON COLUMN fact_sales_order.so_number IS '销售订单号，格式SO-YYYYMMDD-NNNNN';
COMMENT ON COLUMN fact_sales_order.order_date IS '客户下单日期（官网订购）';
COMMENT ON COLUMN fact_sales_order.requested_delivery_date IS '客户期望交付日期';
COMMENT ON COLUMN fact_sales_order.actual_delivery_date IS '实际交付日期';
COMMENT ON COLUMN fact_sales_order.ship_from_factory_id IS '发货工厂（Gigafactory）';
COMMENT ON COLUMN fact_sales_order.ship_to_country_id IS '目的国';
COMMENT ON COLUMN fact_sales_order.total_gross_revenue IS '车辆总售价（USD）= 车价+选装';
COMMENT ON COLUMN fact_sales_order.total_discount IS '折扣总额（USD），Tesla直销通常为0';
COMMENT ON COLUMN fact_sales_order.total_net_revenue IS '净收入= 总售价-折扣';
COMMENT ON COLUMN fact_sales_order.total_std_material_cost IS '标准材料成本（USD）';
COMMENT ON COLUMN fact_sales_order.total_freight_cost IS '运费（USD）：滚装船/板车/Tesla自有物流';
COMMENT ON COLUMN fact_sales_order.total_tariff_cost IS '关税（USD）：CN→US 25%, CN→EU 17%等';
COMMENT ON COLUMN fact_sales_order.vin IS '17位VIN码，唯一标识一辆整车';
COMMENT ON COLUMN fact_sales_order.status IS '订单状态: RESERVED(预订)/CONFIRMED(确认)/IN_PRODUCTION(排产)/IN_TRANSIT(在途)/DELIVERED(已交付)/CANCELLED(取消)';
COMMENT ON COLUMN fact_sales_order.incoterm IS '贸易术语：FOB/CIF/DDP';
CREATE INDEX idx_so_customer ON fact_sales_order(customer_id);
CREATE INDEX idx_so_date     ON fact_sales_order(order_date);
CREATE INDEX idx_so_vin      ON fact_sales_order(vin);

CREATE TABLE fact_sales_order_item (
    so_item_id      BIGSERIAL PRIMARY KEY,
    so_id           BIGINT        NOT NULL REFERENCES fact_sales_order(so_id),
    item_seq        SMALLINT      NOT NULL DEFAULT 10,
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    qty             NUMERIC(12,2) NOT NULL DEFAULT 1,
    list_price      NUMERIC(14,4),
    discount_pct    NUMERIC(6,4)  NOT NULL DEFAULT 0,
    net_unit_price  NUMERIC(14,4),
    gross_line_amount NUMERIC(18,4),
    net_line_amount   NUMERIC(18,4),
    std_material_cost  NUMERIC(16,4),
    manufacturing_cost NUMERIC(16,4),
    UNIQUE (so_id, item_seq)
);
COMMENT ON TABLE  fact_sales_order_item IS '销售订单行项目；行10=车辆本身, 行20+=选装(FSD等)';
COMMENT ON COLUMN fact_sales_order_item.so_id IS '关联销售订单头';
COMMENT ON COLUMN fact_sales_order_item.item_seq IS '行号: 10=车辆本身, 20+=选装(FSD/颜色/轮毂等)';
COMMENT ON COLUMN fact_sales_order_item.component_id IS '产品ID（整车或FSD计算机等选装件）';
COMMENT ON COLUMN fact_sales_order_item.qty IS '数量，整车行=1';
COMMENT ON COLUMN fact_sales_order_item.list_price IS '目录价（USD）';
COMMENT ON COLUMN fact_sales_order_item.net_unit_price IS '折后净单价（USD）';
COMMENT ON COLUMN fact_sales_order_item.gross_line_amount IS '行毛收入（USD）';
COMMENT ON COLUMN fact_sales_order_item.net_line_amount IS '行净收入（USD）= 毛收入-折扣';
COMMENT ON COLUMN fact_sales_order_item.std_material_cost IS '标准材料成本（USD），BOM材料成本';
COMMENT ON COLUMN fact_sales_order_item.manufacturing_cost IS '制造成本（USD），人工+制造费用';
CREATE INDEX idx_soi_so        ON fact_sales_order_item(so_id);
CREATE INDEX idx_soi_component ON fact_sales_order_item(component_id);

-- =============================================================================
-- SEED DATA — 销售渠道
-- =============================================================================

INSERT INTO dim_sales_channel (channel_code, channel_name, channel_type, commission_rate) VALUES
('DIRECT',  'Tesla.com 官网直销',     'DIRECT',      0),
('FLEET',   '企业/租车公司批量采购',  'FLEET',       0),
('GOVT_SALE','政府采购',              'GOVT_TENDER', 0),
('REFERRAL', '车主推荐',              'ONLINE',      0.005);

-- =============================================================================
-- SEED DATA — 客户 (500终端消费者)
-- =============================================================================

INSERT INTO dim_customer (customer_code, customer_name, country_id, customer_type, credit_limit_usd, payment_terms_days, currency_id, is_strategic)
SELECT
    'CUST-' || LPAD(ROW_NUMBER() OVER (ORDER BY n.n, c.country_id)::TEXT, 5, '0'),
    (ARRAY['James','Mary','Robert','Patricia','John','Jennifer','Michael','Linda','David','Elizabeth',
           'William','Barbara','Richard','Susan','Joseph','Jessica','Thomas','Sarah','Charles','Karen',
           'Christopher','Lisa','Daniel','Nancy','Matthew','Betty','Anthony','Margaret','Mark','Sandra',
           'Donald','Ashley','Steven','Kimberly','Paul','Emily','Andrew','Donna','Joshua','Michelle',
           'Kenneth','Carol','Kevin','Amanda','Brian','Dorothy','George','Melissa','Timothy','Deborah',
           'Ronald','Stephanie','Edward','Rebecca','Jason','Sharon','Jeffrey','Laura','Ryan','Cynthia',
           'Jacob','Kathleen','Gary','Amy','Nicholas','Angela','Eric','Anna','Jonathan','Brenda',
           'Stephen','Pamela','Larry','Nicole','Justin','Samantha','Brandon','Katherine','Frank','Emma',
           'Scott','Rachel','Benjamin','Carolyn','Gregory','Janet','Samuel','Christine','Raymond','Maria',
           'Patrick','Heather','Alexander','Diane','Jack','Julie','Dennis','Joyce','Jerry','Victoria'])[((n.n-1) % 100) + 1]
        || ' ' ||
        (ARRAY['Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez',
               'Martinez','Hernandez','Lopez','Gonzalez','Wilson','Anderson','Thomas','Taylor',
               'Moore','Jackson','Martin','Lee','Perez','Thompson','White','Harris','Sanchez',
               'Clark','Ramirez','Lewis','Robinson','Walker','Young','Allen','King','Wright',
               'Scott','Torres','Nguyen','Hill','Flores','Green','Adams','Nelson','Baker',
               'Hall','Rivera','Campbell','Mitchell','Carter','Roberts'])[((n.n-1) % 50) + 1],
    c.country_id,
    CASE WHEN n.n % 100 < 75 THEN 'CONSUMER'
         WHEN n.n % 100 < 88 THEN 'FLEET'
         WHEN n.n % 100 < 95 THEN 'LEASE'
         ELSE 'GOVT' END,
    CASE WHEN n.n % 100 < 75 THEN 0 ELSE 500000 END,
    CASE WHEN n.n % 100 < 75 THEN 0 ELSE 30 END,
    c.currency_id,
    FALSE
FROM generate_series(1, 500) AS n(n)
CROSS JOIN LATERAL (
    SELECT country_id, currency_id FROM geo.dim_country
    WHERE country_code IN ('US','DE','CN','NL','GB','FR','CA','AU','KR','JP','NO','SE')
    ORDER BY random() LIMIT 1
) c;
