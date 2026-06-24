-- =============================================================================
-- EV Parts Lakehouse - Extensions & Schemas
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

COMMENT ON SCHEMA geo         IS '国家/币种/地区 — 基础地理维度';
COMMENT ON SCHEMA product     IS '产品/BOM/原材料 — 零部件主数据与物料清单';
COMMENT ON SCHEMA production  IS '工厂/生产线/生产订单/质量 — 制造执行域';
COMMENT ON SCHEMA procurement IS '供应商/采购订单/来料质量 — 采购域';
COMMENT ON SCHEMA sales       IS '客户/渠道/价格/销售订单 — 销售域';
COMMENT ON SCHEMA inventory   IS '仓库/库存快照/库存移动 — 库存域';
COMMENT ON SCHEMA finance     IS '汇率/利率/应收/库存持有成本 — 财务域';
COMMENT ON SCHEMA logistics   IS '关税/航线/运费/装运 — 跨境物流域';
COMMENT ON SCHEMA esg         IS '碳排放/能源/碳价/碳税 — ESG 域';
COMMENT ON SCHEMA aftersales  IS '故障模式/保修索赔/现场失效 — 售后域';
