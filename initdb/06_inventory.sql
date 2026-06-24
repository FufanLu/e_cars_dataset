-- =============================================================================
-- EV Parts Lakehouse - inventory schema: 仓库 / 库存快照 / 库存移动 / 断货
-- PostgreSQL 16
-- =============================================================================

SET search_path TO inventory, production, product, geo, public;

-- =============================================================================
-- DDL
-- =============================================================================

CREATE TABLE dim_warehouse (
    warehouse_id    SERIAL PRIMARY KEY,
    warehouse_code  VARCHAR(20)  NOT NULL UNIQUE,
    warehouse_name  VARCHAR(200) NOT NULL,
    factory_id      INT          REFERENCES production.dim_factory(factory_id),
    country_id      INT          NOT NULL REFERENCES geo.dim_country(country_id),
    warehouse_type  VARCHAR(20)  CHECK (warehouse_type IN ('RAW','WIP','FG','TRANSIT','3PL')),
    capacity_sqm    NUMERIC(10,2),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_warehouse IS '仓库主数据；含原料/在制/成品/在途/三方仓';

CREATE TABLE fact_inventory_snapshot (
    snapshot_id     BIGSERIAL PRIMARY KEY,
    snapshot_date   DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    qty_on_hand     NUMERIC(14,2) NOT NULL,
    qty_reserved    NUMERIC(14,2) NOT NULL DEFAULT 0,
    qty_available   NUMERIC(14,2) GENERATED ALWAYS AS (qty_on_hand - qty_reserved) STORED,
    avg_cost_usd    NUMERIC(14,4),
    inventory_value_usd NUMERIC(18,4),
    UNIQUE (snapshot_date, warehouse_id, component_id)
);
COMMENT ON TABLE  fact_inventory_snapshot IS '月末/日末库存快照；inventory_value = qty * avg_cost';
CREATE INDEX idx_inv_snap_date      ON fact_inventory_snapshot(snapshot_date DESC);
CREATE INDEX idx_inv_snap_component ON fact_inventory_snapshot(component_id);
CREATE INDEX idx_inv_snap_warehouse ON fact_inventory_snapshot(warehouse_id);

CREATE TABLE fact_inventory_movement (
    movement_id     BIGSERIAL PRIMARY KEY,
    movement_date   TIMESTAMPTZ   NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    movement_type   VARCHAR(20)   NOT NULL CHECK (movement_type IN ('GR','GI','TRANSFER_IN','TRANSFER_OUT','ADJUSTMENT','RETURN')),
    qty             NUMERIC(14,2) NOT NULL,
    reference_doc   VARCHAR(30),
    unit_cost_usd   NUMERIC(14,4),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_inventory_movement IS '库存移动明细；GR=收货，GI=发货，TRANSFER=调拨';
CREATE INDEX idx_im_date      ON fact_inventory_movement(movement_date DESC);
CREATE INDEX idx_im_component ON fact_inventory_movement(component_id);

CREATE TABLE fact_stockout_event (
    stockout_id     BIGSERIAL PRIMARY KEY,
    event_date      DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    stockout_days   INT           NOT NULL DEFAULT 1,
    lost_demand_qty NUMERIC(14,2),
    lost_revenue_est_usd NUMERIC(16,4),
    root_cause      VARCHAR(100),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_stockout_event IS '断货事件记录；用于计算 Stockout Rate 和潜在损失';

-- =============================================================================
-- SEED DATA
-- =============================================================================

INSERT INTO dim_warehouse (warehouse_code, warehouse_name, factory_id, country_id, warehouse_type, capacity_sqm) VALUES
('WH-SH-RM', 'Shanghai Raw Material Store',     (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'RAW',     8000),
('WH-SH-FG', 'Shanghai Finished Goods DC',      (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-CN-SH'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'FG',     15000),
('WH-WH-RM', 'Wuhan Raw Material Store',        (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'RAW',     5000),
('WH-WH-FG', 'Wuhan FG Warehouse',              (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-CN-WH'), (SELECT country_id FROM geo.dim_country WHERE country_code='CN'), 'FG',      6000),
('WH-DE-LZ', 'Leipzig Finished Goods',          (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-DE-LZ'), (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), 'FG',      9000),
('WH-US-TX', 'Texas Distribution Center',       (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-US-TX'), (SELECT country_id FROM geo.dim_country WHERE country_code='US'), 'FG',     12000),
('WH-HU-BP', 'Debrecen FG Warehouse',           (SELECT factory_id FROM production.dim_factory WHERE factory_code='FAC-HU-DE'), (SELECT country_id FROM geo.dim_country WHERE country_code='HU'), 'FG',      7000),
('WH-SG-3PL','Singapore 3PL Hub',               NULL,                                                                 (SELECT country_id FROM geo.dim_country WHERE country_code='SG'), '3PL',     4000),
('WH-US-NJ', 'New Jersey East Coast DC',        NULL,                                                                 (SELECT country_id FROM geo.dim_country WHERE country_code='US'), '3PL',     6000),
('WH-DE-FR', 'Frankfurt Regional DC',           NULL,                                                                 (SELECT country_id FROM geo.dim_country WHERE country_code='DE'), '3PL',     5000);
