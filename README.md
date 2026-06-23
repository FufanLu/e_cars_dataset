# EV Parts Lakehouse — 全球电动车零部件制造商经营分析数据库

一个用于 **text2ontology / NL2SQL / 数据分析** 场景的 PostgreSQL 16 数据库，模拟真实跨国电动车零部件制造企业的全链路业务数据（BOM、生产、供应商、销售、库存、财务、ESG、售后）。

---

## 快速启动

```bash
# 1. 克隆 / 解压项目
cd ev-parts-lakehouse

# 2. 首次启动（自动建表 + 插入种子数据，约需 3-5 分钟）
docker compose up -d

# 3. 查看启动日志
docker compose logs -f

# 4. 等待 healthy 后连接验证
docker exec -it ev_parts_db psql -U ev_user -d ev_parts -c "\dt"
```

> **首次启动注意**：`initdb/` 中的三个 SQL 文件会按字母顺序执行（01→02→03），总计约 5-15 万行，在普通笔记本上约 3-5 分钟完成。

---

## 连接信息

| 参数 | 值 |
|------|-----|
| Host | `localhost` |
| Port | `5432` |
| Database | `ev_parts` |
| User | `ev_user` |
| Password | `ev_password` |

**连接字符串**：
```
postgresql://ev_user:ev_password@localhost:5432/ev_parts
```

---

## 连接 text2ontology

```bash
# text2ontology 标准 PostgreSQL 连接（根据实际工具文档调整）
python text2ontology.py \
  --db-url "postgresql://ev_user:ev_password@localhost:5432/ev_parts" \
  --schema public \
  --output ev_parts_ontology.ttl
```

text2ontology 会自动读取：
- 所有表的 `COMMENT ON TABLE` / `COMMENT ON COLUMN`
- 主键、外键、唯一约束（用于推断关系）
- 索引（用于推断重要查询路径）
- 计算列（`GENERATED ALWAYS AS`，用于推断业务指标）

---

## 数据库结构概览

### 业务域 & 表清单

| 域 | 表 | 说明 |
|----|----|----|
| **地理/货币** | `dim_region`, `dim_country`, `dim_currency` | 16国、15币种、4大区 |
| **产品/BOM** | `dim_component_category`, `dim_component`, `bom_header`, `bom_item`, `dim_raw_material`, `component_material_usage`, `fact_raw_material_price_daily` | 25个零部件、多层BOM、原材料日价 |
| **生产** | `dim_factory`, `dim_production_line`, `fact_production_order`, `fact_quality_inspection`, `fact_scrap_event` | 10厂、14生产线、~4800生产订单 |
| **供应商/采购** | `dim_supplier`, `fact_purchase_order`, `fact_purchase_order_item`, `fact_supplier_delivery`, `fact_supplier_quality` | 20供应商、采购订单、来料质量 |
| **客户/销售** | `dim_customer`, `dim_sales_channel`, `fact_country_price_list`, `fact_price_agreement`, `fact_sales_order`, `fact_sales_order_item`, `fact_rebate`, `fact_volume_discount` | 20客户、多国定价、~4000销售订单 |
| **库存** | `dim_warehouse`, `fact_inventory_snapshot`, `fact_inventory_movement`, `fact_stockout_event` | 10仓、月末快照、断货事件 |
| **财务** | `fact_exchange_rate_daily`, `fact_interest_rate_daily`, `fact_receivable_aging`, `fact_inventory_carrying_cost` | ~12000汇率行、利率、应收账龄 |
| **物流/关税** | `fact_tariff_rate`, `fact_trade_lane`, `fact_freight_cost`, `fact_shipping_order` | 17关税规则、15航线 |
| **ESG/碳** | `dim_emission_scope`, `fact_factory_energy_consumption`, `fact_component_carbon_footprint`, `fact_supplier_esg_score`, `fact_shipping_emission`, `fact_carbon_price`, `fact_carbon_tax`, `fact_carbon_credit` | 月度碳排、EU ETS碳价、碳税 |
| **售后** | `dim_failure_mode`, `fact_warranty_claim`, `fact_field_failure` | 12故障模式、~800索赔、现场失效率 |

---

## 核心指标口径

以下指标口径用于校验 NL2SQL / text2ontology 生成的查询是否正确：

### 收入类

| 指标 | 口径 |
|------|------|
| **Gross Revenue** | `fact_sales_order.total_gross_revenue` = `SUM(qty × list_price)` |
| **Net Revenue** | `total_gross_revenue - total_discount - rebate` = `fact_sales_order.total_net_revenue - fact_rebate.rebate_amount_usd` |
| **FX Impact** | `Net Revenue (local CCY) × (current_rate - budget_rate) / budget_rate` |

### 成本类

| 指标 | 口径 |
|------|------|
| **Standard Material Cost** | `fact_sales_order_item.std_material_cost × qty` |
| **Manufacturing Cost** | `fact_sales_order_item.manufacturing_cost × qty` |
| **Freight Cost** | `fact_sales_order.total_freight_cost`（按净收入比例分摊到行项目） |
| **Tariff Cost** | `fact_sales_order.total_tariff_cost`（= 货值 × `fact_tariff_rate.tariff_rate_pct`） |
| **Carbon Tax Cost** | `fact_carbon_tax.carbon_tax_usd`（工厂月度，需按产量比例分摊到产品） |
| **Carbon Cost per Unit** | `fact_component_carbon_footprint.total_kgco2e_per_unit × carbon_price_usd_per_tco2e / 1000` |

### 库存财务类

| 指标 | 口径 |
|------|------|
| **Inventory Carrying Cost** | `fact_inventory_carrying_cost.carrying_cost_usd` = `avg_inventory_value × (interest_rate + storage_rate + obsolescence_rate) × days/365` |
| **Receivable Financing Cost** | `fact_receivable_aging.financing_cost_usd` = `total_outstanding × interest_rate × days/360` |
| **Interest Cost Impact (+1%)** | `Δ = SUM(avg_inventory_value) × 0.01 / 12`（月度影响） |

### 毛利类

| 指标 | 口径 |
|------|------|
| **Gross Margin** | `Net Revenue - Std Material Cost - Manufacturing Cost` |
| **Adjusted Gross Margin** | `Gross Margin - Freight Cost - Tariff Cost - Carbon Tax Cost` |
| **Adjusted Gross Margin Rate** | `Adjusted Gross Margin / Net Revenue` |

### 供应链质量类

| 指标 | 口径 |
|------|------|
| **Supplier On-Time Delivery Rate** | `COUNT(is_on_time=TRUE) / COUNT(*) FROM fact_supplier_delivery GROUP BY supplier_id` |
| **Supplier Defect Rate (PPM)** | `AVG(defect_ppm) FROM fact_supplier_quality GROUP BY supplier_id` |
| **First Pass Yield (FPY)** | `SUM(passed_qty) / SUM(inspected_qty) FROM fact_quality_inspection GROUP BY prod_order_id` |
| **Scrap Rate** | `SUM(scrap_qty) / SUM(actual_qty) FROM fact_production_order GROUP BY factory_id, component_id` |
| **Stockout Rate** | `COUNT(DISTINCT stockout_event) / COUNT(DISTINCT component_id) FROM fact_stockout_event GROUP BY warehouse_id` |

### ESG类

| 指标 | 口径 |
|------|------|
| **Carbon Emission per Unit** | `fact_component_carbon_footprint.total_kgco2e_per_unit`（Scope1+2+3合计） |
| **Carbon Cost per Unit** | `total_kgco2e_per_unit / 1000 × carbon_price_usd_per_tco2e` |

---

## 分析示例查询

详见 `docs/sample_questions.md`。

---

## 重置数据库

```bash
# 删除数据卷并重建（清除所有数据）
docker compose down -v
docker compose up -d
```

---

## 文件结构

```
ev-parts-lakehouse/
├── docker-compose.yml          # PostgreSQL 16 服务配置
├── initdb/
│   ├── 01_schema.sql           # DDL：所有表、索引、约束、注释、视图
│   ├── 02_seed.sql             # 种子：维表数据（国家/产品/工厂/客户等）
│   └── 03_seed_facts.sql       # 种子：事实表批量数据（generate_series）
├── docs/
│   ├── er.md                   # ER图（Mermaid）
│   └── sample_questions.md     # 示例分析问题 + 参考 SQL
└── README.md
```
