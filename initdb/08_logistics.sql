-- =============================================================================
-- EV Parts Lakehouse - logistics schema: 关税 / 航线 / 运费 / 装运
-- PostgreSQL 16
-- =============================================================================

SET search_path TO logistics, sales, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE fact_tariff_rate (
    tariff_id       BIGSERIAL PRIMARY KEY,
    hs_code         VARCHAR(20)   NOT NULL,
    from_country_id INT           NOT NULL REFERENCES geo.dim_country(country_id),
    to_country_id   INT           NOT NULL REFERENCES geo.dim_country(country_id),
    tariff_rate_pct NUMERIC(8,4)  NOT NULL,
    effective_from  DATE          NOT NULL,
    effective_to    DATE,
    tariff_type     VARCHAR(30)   CHECK (tariff_type IN ('MFN','FTA','ANTI_DUMPING','PREFERENTIAL','RETALIATORY')),
    notes           TEXT,
    UNIQUE (hs_code, from_country_id, to_country_id, effective_from)
);
COMMENT ON TABLE  fact_tariff_rate IS '关税税率表，按HS Code+贸易路线+时间段；整车HS8703800000';
COMMENT ON COLUMN fact_tariff_rate.hs_code IS 'HS海关编码，整车8703800000，电池8507600090';
COMMENT ON COLUMN fact_tariff_rate.from_country_id IS '出口国';
COMMENT ON COLUMN fact_tariff_rate.to_country_id IS '进口国';
COMMENT ON COLUMN fact_tariff_rate.tariff_rate_pct IS '关税税率（%）：CN→US 25%, CN→EU 17%';
COMMENT ON COLUMN fact_tariff_rate.tariff_type IS '关税类型：MFN(最惠国)/FTA(自贸协定)/ANTI_DUMPING(反补贴)/PREFERENTIAL(优惠)/RETALIATORY(报复性)';
CREATE INDEX idx_tariff_hs      ON fact_tariff_rate(hs_code);
CREATE INDEX idx_tariff_route   ON fact_tariff_rate(from_country_id, to_country_id);

CREATE TABLE fact_trade_lane (
    lane_id         BIGSERIAL PRIMARY KEY,
    lane_code       VARCHAR(30)   NOT NULL UNIQUE,
    from_country_id INT           NOT NULL REFERENCES geo.dim_country(country_id),
    to_country_id   INT           NOT NULL REFERENCES geo.dim_country(country_id),
    transport_mode  VARCHAR(20)   NOT NULL CHECK (transport_mode IN ('SEA','AIR','RAIL','ROAD','MULTIMODAL')),
    transit_days    INT           NOT NULL,
    base_rate_usd_per_cbm NUMERIC(10,4),
    base_rate_usd_per_kg  NUMERIC(10,4),
    carrier         VARCHAR(100),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_trade_lane IS '贸易航线/运输路线主数据；Tesla上海→欧洲滚装船航线';
COMMENT ON COLUMN fact_trade_lane.transport_mode IS '运输方式：SEA(海运)/AIR(空运)/RAIL(铁路)/ROAD(公路)/MULTIMODAL(多式联运)';
COMMENT ON COLUMN fact_trade_lane.transit_days IS '运输天数';
COMMENT ON COLUMN fact_trade_lane.base_rate_usd_per_kg IS '基准运费率（USD/kg）';
COMMENT ON COLUMN fact_trade_lane.base_rate_usd_per_cbm IS '基准运费率（USD/m³）';
CREATE INDEX idx_tl_route ON fact_trade_lane(from_country_id, to_country_id);

CREATE TABLE fact_freight_cost (
    freight_id      BIGSERIAL PRIMARY KEY,
    so_id           BIGINT        REFERENCES sales.fact_sales_order(so_id),
    lane_id         BIGINT        NOT NULL REFERENCES fact_trade_lane(lane_id),
    shipment_date   DATE          NOT NULL,
    weight_kg       NUMERIC(12,4),
    volume_cbm      NUMERIC(10,4),
    chargeable_weight_kg NUMERIC(12,4),
    freight_amount_usd   NUMERIC(16,4) NOT NULL,
    insurance_amount_usd NUMERIC(14,4) NOT NULL DEFAULT 0,
    handling_fee_usd     NUMERIC(14,4) NOT NULL DEFAULT 0,
    total_logistics_cost_usd NUMERIC(16,4) NOT NULL,
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_freight_cost IS '运费事实表，含运费+保险+装卸费';
COMMENT ON COLUMN fact_freight_cost.so_id IS '关联销售订单';
COMMENT ON COLUMN fact_freight_cost.weight_kg IS '货物重量（kg），整车约2000-3000kg';
COMMENT ON COLUMN fact_freight_cost.volume_cbm IS '货物体积（m³）';
COMMENT ON COLUMN fact_freight_cost.freight_amount_usd IS '海运费/陆运费（USD）';
COMMENT ON COLUMN fact_freight_cost.insurance_amount_usd IS '运输保险（USD）';
COMMENT ON COLUMN fact_freight_cost.handling_fee_usd IS '码头/装卸操作费（USD）';
COMMENT ON COLUMN fact_freight_cost.total_logistics_cost_usd IS '物流总成本（USD）= 运费+保险+装卸';
CREATE INDEX idx_fc_so   ON fact_freight_cost(so_id);
CREATE INDEX idx_fc_date ON fact_freight_cost(shipment_date);

CREATE TABLE fact_shipping_order (
    shipping_id     BIGSERIAL PRIMARY KEY,
    shipping_no     VARCHAR(30)   NOT NULL UNIQUE,
    so_id           BIGINT        REFERENCES sales.fact_sales_order(so_id),
    lane_id         BIGINT        NOT NULL REFERENCES fact_trade_lane(lane_id),
    ship_date       DATE          NOT NULL,
    eta_date        DATE,
    actual_arrival_date DATE,
    status          VARCHAR(20)   NOT NULL CHECK (status IN ('BOOKED','IN_TRANSIT','ARRIVED','CLEARED','DELIVERED')),
    container_no    VARCHAR(30),
    bl_no           VARCHAR(30),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_shipping_order IS '装运单/提单主数据，关联运费和销售订单';
COMMENT ON COLUMN fact_shipping_order.shipping_no IS '装运号，格式SHP-YYYYMMDD-NNNNN';
COMMENT ON COLUMN fact_shipping_order.so_id IS '关联销售订单';
COMMENT ON COLUMN fact_shipping_order.lane_id IS '航线ID，关联fact_trade_lane';
COMMENT ON COLUMN fact_shipping_order.ship_date IS '发运日期';
COMMENT ON COLUMN fact_shipping_order.eta_date IS '预计到港日期';
COMMENT ON COLUMN fact_shipping_order.actual_arrival_date IS '实际到港日期';
COMMENT ON COLUMN fact_shipping_order.status IS '装运状态：BOOKED(已订舱)/IN_TRANSIT(在途)/ARRIVED(到港)/CLEARED(已清关)/DELIVERED(已交付)';
COMMENT ON COLUMN fact_shipping_order.container_no IS '集装箱号';

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO fact_tariff_rate (hs_code, from_country_id, to_country_id, tariff_rate_pct, effective_from, tariff_type, notes) VALUES
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 27.50, '2023-01-01', 'RETALIATORY',  'Section 301 tariff on CN battery packs'),
('8501532090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 25.00, '2023-01-01', 'RETALIATORY',  'Section 301 tariff on CN EV motors'),
('8504401990', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 25.00, '2023-01-01', 'RETALIATORY',  'Section 301 tariff on inverters/OBC'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 17.80, '2024-10-31', 'ANTI_DUMPING', 'EU countervailing duty on CN EV batteries'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='FR'), 17.80, '2024-10-31', 'ANTI_DUMPING', 'EU countervailing duty on CN EV batteries'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='HU'), 17.80, '2024-10-31', 'ANTI_DUMPING', 'EU countervailing duty on CN EV batteries'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 3.70, '2023-01-01', 'MFN', 'EU MFN duty on battery packs pre-2024'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 3.70, '2023-01-01', 'MFN', 'US MFN tariff on EU battery imports'),
('8501532090', (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 2.50, '2023-01-01', 'MFN', 'US MFN tariff on EU motors'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='US'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 5.00, '2023-01-01', 'MFN', 'CN MFN tariff on imported battery packs'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 0.00, '2023-01-01', 'FTA',  'KORUS FTA 0% tariff'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 0.00, '2023-01-01', 'FTA',  'USMCA 0% tariff'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='TH'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 2.00, '2023-01-01', 'PREFERENTIAL', 'EU GSP for Thailand'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), 15.00, '2023-01-01', 'MFN', 'India MFN + BCD on battery packs'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 0.00, '2023-01-01', 'MFN', 'Japan 0% MFN on EV batteries'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), 12.00,'2023-01-01', 'MFN', 'Mexico MFN tariff'),
('8507600090', (SELECT country_id FROM geo.dim_country WHERE country_code='HU'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 3.70, '2023-01-01', 'MFN', 'US MFN tariff on EU battery imports');

INSERT INTO fact_trade_lane (lane_code, from_country_id, to_country_id, transport_mode, transit_days, base_rate_usd_per_cbm, base_rate_usd_per_kg, carrier) VALUES
('CN-SH-US-LA-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'SEA', 18, 42.0, 0.048, 'COSCO / MSC'),
('CN-SH-DE-HH-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'SEA', 28, 38.5, 0.042, 'COSCO / Hapag-Lloyd'),
('CN-SH-JP-TK-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='JP'), 'SEA',  4, 18.0, 0.022, 'COSCO / NYK'),
('CN-SH-KR-BU-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), 'SEA',  3, 16.0, 0.019, 'SITC'),
('CN-SH-IN-MU-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='IN'), 'SEA', 12, 25.0, 0.030, 'MSC'),
('CN-SH-MX-MZ-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), 'SEA', 22, 45.0, 0.052, 'COSCO'),
('CN-SH-VN-HCM-SEA', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='VN'), 'SEA',  4, 15.0, 0.018, 'SITC'),
('CN-SH-TH-LCB-SEA', (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='TH'), 'SEA',  7, 20.0, 0.024, 'MSC'),
('DE-HH-US-NY-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'SEA', 14, 35.0, 0.040, 'Hapag-Lloyd'),
('HU-BU-DE-MU-ROAD', (SELECT country_id FROM geo.dim_country WHERE country_code='HU'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'ROAD', 2, 8.0,  0.012, 'DB Schenker'),
('DE-MU-FR-PA-ROAD', (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), (SELECT country_id FROM geo.dim_country WHERE country_code='FR'), 'ROAD', 1, 7.0,  0.010, 'DHL Freight'),
('CN-SH-SG-SG-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='SG'), 'SEA',  5, 16.5, 0.020, 'PIL'),
('MX-MT-US-TX-ROAD', (SELECT country_id FROM geo.dim_country WHERE country_code='MX'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'ROAD', 1, 6.0,  0.009, 'JB Hunt'),
('KR-BU-US-LA-SEA',  (SELECT country_id FROM geo.dim_country WHERE country_code='KR'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'SEA', 14, 30.0, 0.035, 'HMM'),
('CN-SH-US-LA-AIR',  (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'AIR',  2, 0.0,  4.800, 'Air China Cargo');
