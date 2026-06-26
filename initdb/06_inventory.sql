-- =============================================================================
-- Tesla OEM Lakehouse - inventory schema: 仓库 / 在途 / 线边仓
-- 特斯拉直销模式: 零成品库存(build-to-order), 最小化原材料库存(JIT), 无经销商库存
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
    warehouse_type  VARCHAR(20)  CHECK (warehouse_type IN ('RAW','WIP','LINE_SIDE','TRANSIT','SERVICE','RETURN')),
    capacity_sqm    NUMERIC(10,2),
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT now()
);
COMMENT ON TABLE  dim_warehouse IS '仓库主数据；Tesla无FG仓(成品即发运)，含原料/在制/线边/在途/售后/退货';
COMMENT ON COLUMN dim_warehouse.warehouse_code IS '仓库代码，如FMT-RAW(Fremont原料仓)、TXS-LINE(德州线边)';
COMMENT ON COLUMN dim_warehouse.factory_id IS '所属工厂，售后仓可为NULL';
COMMENT ON COLUMN dim_warehouse.warehouse_type IS '仓库类型: RAW=原料, WIP=在制, LINE_SIDE=总装线边, TRANSIT=在途, SERVICE=售后件, RETURN=退货';
COMMENT ON COLUMN dim_warehouse.capacity_sqm IS '仓库面积（平方米）';

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
COMMENT ON TABLE  fact_inventory_snapshot IS '月末库存快照；Tesla成品库存极低(通常<7天), 主要是原料和WIP';
COMMENT ON COLUMN fact_inventory_snapshot.snapshot_date IS '快照日期（月末）';
COMMENT ON COLUMN fact_inventory_snapshot.warehouse_id IS '仓库ID';
COMMENT ON COLUMN fact_inventory_snapshot.component_id IS '零部件/整车ID';
COMMENT ON COLUMN fact_inventory_snapshot.qty_on_hand IS '在库数量；成品通常为0或个位数';
COMMENT ON COLUMN fact_inventory_snapshot.qty_reserved IS '已预留量（已分配给销售订单但未发货）';
COMMENT ON COLUMN fact_inventory_snapshot.qty_available IS '可用量（生成列=qty_on_hand-qty_reserved）';
COMMENT ON COLUMN fact_inventory_snapshot.avg_cost_usd IS '移动平均成本（USD/件）';
COMMENT ON COLUMN fact_inventory_snapshot.inventory_value_usd IS '库存价值（USD）= qty_on_hand × avg_cost_usd';
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
COMMENT ON TABLE  fact_inventory_movement IS '库存移动明细: GR=收货, GI=发货, TRANSFER=调拨, ADJUSTMENT=盘点调整, RETURN=退货';
COMMENT ON COLUMN fact_inventory_movement.movement_date IS '移动时间戳';
COMMENT ON COLUMN fact_inventory_movement.movement_type IS '移动类型：GR(收货)/GI(发货)/TRANSFER_IN/TRANSFER_OUT/ADJUSTMENT(盘点)/RETURN(退货)';
COMMENT ON COLUMN fact_inventory_movement.qty IS '移动数量（正=入、负=出）';
COMMENT ON COLUMN fact_inventory_movement.reference_doc IS '参考单据号（采购单/销售单/生产单）';
COMMENT ON COLUMN fact_inventory_movement.unit_cost_usd IS '单位成本（USD），用于成本追溯';
CREATE INDEX idx_im_date      ON fact_inventory_movement(movement_date DESC);
CREATE INDEX idx_im_component ON fact_inventory_movement(component_id);

CREATE TABLE fact_stockout_event (
    stockout_id     BIGSERIAL PRIMARY KEY,
    event_date      DATE          NOT NULL,
    warehouse_id    INT           NOT NULL REFERENCES dim_warehouse(warehouse_id),
    component_id    INT           NOT NULL REFERENCES product.dim_component(component_id),
    stockout_days   INT           NOT NULL,
    lost_demand_qty NUMERIC(12,2),
    lost_revenue_est_usd NUMERIC(16,4),
    root_cause      VARCHAR(50),
    created_at      TIMESTAMPTZ   NOT NULL DEFAULT now()
);
COMMENT ON TABLE  fact_stockout_event IS '断货事件；Tesla因JIT模式对断货极其敏感，直接影响产线停线';
COMMENT ON COLUMN fact_stockout_event.stockout_days IS '断货持续天数';
COMMENT ON COLUMN fact_stockout_event.lost_demand_qty IS '因断货损失的交付数量';
COMMENT ON COLUMN fact_stockout_event.lost_revenue_est_usd IS '因断货损失的预估收入（USD）';
COMMENT ON COLUMN fact_stockout_event.root_cause IS '根因：SUPPLIER_DELAY/DEMAND_SPIKE/TRANSPORT_DISRUPTION/FORECAST_ERROR/QUALITY_HOLD';
CREATE INDEX idx_so_date      ON fact_stockout_event(event_date);
CREATE INDEX idx_so_component ON fact_stockout_event(component_id);

-- =============================================================================
-- SEED DATA — 仓库 (每工厂: 原料+WIP+线边+在途, 无FG)
-- =============================================================================

INSERT INTO dim_warehouse (warehouse_code, warehouse_name, factory_id, country_id, warehouse_type, capacity_sqm)
-- Fremont
SELECT 'FMT-RAW', 'Fremont原料仓', f.factory_id, f.country_id, 'RAW',  30000 FROM dim_factory f WHERE f.factory_code='FAC-FMT' UNION ALL
SELECT 'FMT-WIP', 'Fremont在制仓', f.factory_id, f.country_id, 'WIP',  15000 FROM dim_factory f WHERE f.factory_code='FAC-FMT' UNION ALL
SELECT 'FMT-LINE','Fremont总装线边',f.factory_id,f.country_id,'LINE_SIDE',5000 FROM dim_factory f WHERE f.factory_code='FAC-FMT' UNION ALL
SELECT 'FMT-TRAN','Fremont在途仓', f.factory_id, f.country_id, 'TRANSIT',3000 FROM dim_factory f WHERE f.factory_code='FAC-FMT'
-- Giga Texas
UNION ALL SELECT 'TXS-RAW', 'Giga Texas原料仓',f.factory_id,f.country_id,'RAW',  40000 FROM dim_factory f WHERE f.factory_code='FAC-TXS' UNION ALL
SELECT 'TXS-WIP', 'Giga Texas在制仓',f.factory_id,f.country_id,'WIP',  20000 FROM dim_factory f WHERE f.factory_code='FAC-TXS' UNION ALL
SELECT 'TXS-LINE','Giga Texas总装线边',f.factory_id,f.country_id,'LINE_SIDE',8000 FROM dim_factory f WHERE f.factory_code='FAC-TXS' UNION ALL
SELECT 'TXS-TRAN','Giga Texas在途仓',f.factory_id,f.country_id,'TRANSIT',4000 FROM dim_factory f WHERE f.factory_code='FAC-TXS'
-- Giga Shanghai
UNION ALL SELECT 'SHA-RAW', '上海原料仓',    f.factory_id,f.country_id,'RAW',  35000 FROM dim_factory f WHERE f.factory_code='FAC-SHA' UNION ALL
SELECT 'SHA-WIP', '上海在制仓',    f.factory_id,f.country_id,'WIP',  18000 FROM dim_factory f WHERE f.factory_code='FAC-SHA' UNION ALL
SELECT 'SHA-LINE','上海总装线边',  f.factory_id,f.country_id,'LINE_SIDE',7000 FROM dim_factory f WHERE f.factory_code='FAC-SHA' UNION ALL
SELECT 'SHA-TRAN','上海在途仓',    f.factory_id,f.country_id,'TRANSIT',3000 FROM dim_factory f WHERE f.factory_code='FAC-SHA'
-- Giga Berlin
UNION ALL SELECT 'BER-RAW', 'Berlin原料仓',  f.factory_id,f.country_id,'RAW',  25000 FROM dim_factory f WHERE f.factory_code='FAC-BER' UNION ALL
SELECT 'BER-WIP', 'Berlin在制仓',  f.factory_id,f.country_id,'WIP',  12000 FROM dim_factory f WHERE f.factory_code='FAC-BER' UNION ALL
SELECT 'BER-LINE','Berlin总装线边',f.factory_id,f.country_id,'LINE_SIDE',5000 FROM dim_factory f WHERE f.factory_code='FAC-BER' UNION ALL
SELECT 'BER-TRAN','Berlin在途仓',  f.factory_id,f.country_id,'TRANSIT',3000 FROM dim_factory f WHERE f.factory_code='FAC-BER'
-- Giga Nevada (仅电池原料/WIP)
UNION ALL SELECT 'NEV-RAW','Nevada原料仓',   f.factory_id,f.country_id,'RAW',  20000 FROM dim_factory f WHERE f.factory_code='FAC-NEV' UNION ALL
SELECT 'NEV-WIP','Nevada在制仓',   f.factory_id,f.country_id,'WIP',  10000 FROM dim_factory f WHERE f.factory_code='FAC-NEV'
-- 售后服务仓
UNION ALL SELECT 'SVC-US','美国售后件中心仓', NULL,(SELECT country_id FROM geo.dim_country WHERE country_code='US'),'SERVICE',15000
UNION ALL SELECT 'SVC-EU','欧洲售后件中心仓', NULL,(SELECT country_id FROM geo.dim_country WHERE country_code='DE'),'SERVICE',12000
UNION ALL SELECT 'SVC-CN','中国售后件中心仓', NULL,(SELECT country_id FROM geo.dim_country WHERE country_code='CN'),'SERVICE',10000;
