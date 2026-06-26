-- =============================================================================
-- EV OEM Lakehouse - Extensions & Schemas
-- PostgreSQL 16
-- =============================================================================

SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;

-- -----------------------------------------------------------------------------
-- EXTENSIONS
-- -----------------------------------------------------------------------------
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- -----------------------------------------------------------------------------
-- SCHEMAS — one per business domain (for text2ontology namespace isolation)
-- -----------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS geo;
CREATE SCHEMA IF NOT EXISTS product;
CREATE SCHEMA IF NOT EXISTS production;
CREATE SCHEMA IF NOT EXISTS procurement;
CREATE SCHEMA IF NOT EXISTS sales;
CREATE SCHEMA IF NOT EXISTS inventory;
CREATE SCHEMA IF NOT EXISTS finance;
CREATE SCHEMA IF NOT EXISTS logistics;
CREATE SCHEMA IF NOT EXISTS esg;
CREATE SCHEMA IF NOT EXISTS aftersales;

COMMENT ON SCHEMA geo         IS '国家/币种/地区 — 基础地理维度，覆盖EV主要市场';
COMMENT ON SCHEMA product     IS '整车/BOM/电芯/电驱/FSD/车身/原材料 — 产品主数据与物料清单';
COMMENT ON SCHEMA production  IS 'Gigafactory/产线/工艺路线/生产订单/质量 — EV垂直整合制造域';
COMMENT ON SCHEMA procurement IS '供应商/采购订单/来料质量 — EV全球供应链(Tier1+Tier2)';
COMMENT ON SCHEMA sales       IS '消费者/直销渠道/车辆订单 — EV直销模式(DTC)';
COMMENT ON SCHEMA inventory   IS '原料仓/WIP/线边仓/在途 — EV零成品库存JIT模式';
COMMENT ON SCHEMA finance     IS '汇率/利率/应收/库存持有成本 — 财务域';
COMMENT ON SCHEMA logistics   IS '关税/航线/运费/滚装船 — EV全球整车物流';
COMMENT ON SCHEMA esg         IS '碳排放/能源/碳价/碳税/供应商ESG — EV可持续制造';
COMMENT ON SCHEMA aftersales  IS '故障模式/保修索赔/现场失效 — 售后质量闭环';
