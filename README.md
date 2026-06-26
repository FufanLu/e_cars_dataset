# EV Parts Lakehouse — Global EV Manufacturing Analytics Database

A PostgreSQL 16 database for **text2ontology / NL2SQL / AI analytics**, modeling Tesla-style vertically integrated manufacturing — from raw materials to vehicle delivery.

---

## Quick Start

```bash
cd e_cars_dataset

# First run (creates schemas + seed data, ~3-5 min)
docker compose up -d

# Watch startup logs
docker compose logs -f

# Verify connection
docker exec -it ev_parts_db psql -U ev_user -d ev_parts -c "\dt"
```

---

## Connection

| Parameter | Value |
|-----------|-------|
| Host | `localhost` |
| Port | `15432` |
| Database | `ev_parts` |
| User | `ev_user` |
| Password | `ev_password` |

**Connection string**:
```
postgresql://ev_user:ev_password@localhost:15432/ev_parts
```

---

## Schema Overview

10 business domains, 49 tables, 303 sales orders spanning 2023-01 to 2025-06.

| Schema | Tables | Description |
|--------|:------:|-------------|
| **geo** | 3 | 28 countries, 21 currencies, 4 regions |
| **product** | 7 | 8 vehicle models, 27 components, 14 raw materials, multi-level BOM |
| **production** | 7 | 5 Gigafactories, 20 production lines, 20 process steps |
| **procurement** | 5 | 12 suppliers (CATL/Panasonic/TSMC...), POs, quality, delivery |
| **sales** | 4 | 500+ customers, direct sales, vehicle orders (VIN) |
| **inventory** | 4 | 22 warehouses (raw/WIP/line-side/in-transit/aftermarket) |
| **finance** | 4 | 12K+ exchange rate rows, interest rates, receivables aging |
| **logistics** | 4 | Tariff rates, 4 trade lanes, freight costs |
| **esg** | 8 | Scope 1/2/3 carbon, EU ETS carbon tax, supplier ESG scores |
| **aftersales** | 3 | 12 failure modes, warranty claims, field failure PPM |

---

## Key Views

| View | Purpose |
|------|---------|
| `v_vehicle_gross_margin` | Per-vehicle adjusted margin (freight + tariff included) |
| `v_net_profit` | ALL-in net profit: revenue − material − manufacturing − freight − tariff − carbon tax + factory name + qty |
| `v_supplier_risk_scorecard` | Supplier ESG + quality + delivery combined |
| `v_factory_efficiency` | Per-factory per-line monthly yield, scrap rate, material cost |
| `v_vehicle_carbon_footprint` | Per-vehicle carbon footprint by factory and year |
| `v_supplier_delivery_scorecard` | On-time rate, avg days late, defect PPM per supplier |
| `v_production_unit_cost` | Unit cost = (labor + material + overhead) / qty per order |

---

## Example Questions

| # | Question | Key Tables |
|---|----------|------------|
| Q1 | Which factory has the lowest unit cost for Model Y? | `v_net_profit` GROUP BY `factory_name` |
| Q2 | Selling to Germany vs US — where is net profit higher? | `v_net_profit` GROUP BY `ship_to_country` |
| Q3 | Does higher freight cost eat into margin? | `v_net_profit` → `freight_cost` vs `net_profit_margin_pct` |
| Q4 | Which suppliers have both low ESG scores and high defect PPM? | `v_supplier_risk_scorecard` |
| Q5 | Shanghai → Europe: how much does tariff + freight eat into gross margin? | `v_vehicle_gross_margin` |
| Q6 | Does higher batch size mean lower unit cost? (economies of scale) | `v_production_unit_cost` |
| Q7 | Which country carries the heaviest carbon tax burden? | `v_net_profit` GROUP BY `ship_to_country` |
| Q8 | How much does carbon tax impact net margin? (regression analysis) | `v_net_profit` → `carbon_tax` vs `net_profit_margin_pct` |

---

## File Structure

```
e_cars_dataset/
├── docker-compose.yml
├── initdb/
│   ├── 00_extensions.sql
│   ├── 01_geo.sql
│   ├── 02_product.sql
│   ├── 03_production.sql
│   ├── 04_procurement.sql
│   ├── 05_sales.sql
│   ├── 06_inventory.sql
│   ├── 07_finance.sql
│   ├── 08_logistics.sql
│   ├── 09_esg.sql
│   ├── 10_aftersales.sql
│   ├── 11_views.sql
│   └── 20_fact_data.sql
└── README.md
```

---

## Reset Database

```bash
docker compose down -v
docker compose up -d
```
