# EV Lakehouse 数据生成引擎

替换原 `20_fact_data.sql` 的 Python 生成引擎。用真实的因果链和统计模型生成对齐、守恒、
带真实波动的事实数据(约150万行, 2022-01~2025-12)。

## 前置条件

1. 已执行完 `00~11` 建表 + `12_supply_chain_map.sql` + `13_supply_chain_v2.sql`
   (即维度、供应商、桥表都已就绪; 本引擎只读维度、写事实表)
2. Python 3.9+, 安装依赖:
   ```
   pip install numpy psycopg2-binary
   ```

## 运行

```bash
# 设置数据库连接(或改 config.py 里的 DB_CONFIG)
export PGHOST=localhost PGPORT=15432 PGDATABASE=ev_parts PGUSER=ev_user PGPASSWORD=ev_password

python main.py
```

脚本会:
1. 读取所有维度(BOM/供应商/桥表/工厂产线)
2. **清空所有事实表**(TRUNCATE, dim和桥表保留)
3. 按因果链顺序生成并写入

## 模块结构

| 文件 | 职责 |
|------|------|
| `config.py` | 所有真实参数(车型基线/增长/季节/价格GBM/供应商能力) — **最该审的文件** |
| `db.py` | 连接、读维度、批量写、TRUNCATE |
| `demand.py` | ① 需求(顶层输入): 月销 = 基线×增长×季节×生命周期×噪声 |
| `pricing.py` | ⑤ 原材料价格(GBM真随机游走) + 成本roll-up递归对齐 |
| `sales.py` | ② 销售订单+VIN: 工厂/国家/客户加权分配, 售价真实值 |
| `production.py` | ③ 生产: 销量→产量(良率爬坡)→BOM展开零件→排产, 数量守恒 |
| `procurement.py` | ④ 采购: 零件产量→原材料需求→读桥表份额拆采购单 |
| `derived.py` | ⑥ 汇率/利率/库存快照 |
| `main.py` | 编排 + 自增ID回填 + 分批写库 |

## 关键设计(解决原SQL的问题)

- **真波动**: 原材料价格用几何布朗运动GBM + 低概率跳跃(厚尾), 替换原来的sin
- **真关联**: 客户国家/车型/工厂用条件概率加权抽样, 替换原来的random
- **数量守恒**: 销量→产量→零件→原材料一路推导, 每层加总对得上
- **成本对齐**: 从原材料日价递归roll-up到整车, 与售价算出的毛利率自然合理

## 已知局限(诚实标注)

1. **原材料采购行挂靠代理零件**: `fact_purchase_order_item.component_id` 是NOT NULL且外键
   指向dim_component, 原材料没有对应component, 故用"第一个消耗该材料的零件"代理挂靠。
   更规范应给该表加 `material_id` 字段。

2. **成本roll-up的单位近似**: 用量按kg、价格按USD/MT换算(÷1000)。SIC-WAFER(按片)、
   GLASS-AU(按SQM)等非MT计价材料是近似处理, 需精确时应按uom分别换算。

3. **不含断供连锁**(按你要求的轻量版): 只有价格波动和良率爬坡, 没有"断供→切备选→
   库存波动"的扰动链。后续要加的话, 在 derived.py 里基于桥表的switch_over_days扩展。

## 验证(跑完后)

```sql
-- 毛利率是否合理(应在10-30%区间)
SELECT vehicle_code, ROUND(AVG(adj_gm_rate_pct),1) AS avg_gm
FROM public.v_vehicle_gross_margin GROUP BY vehicle_code ORDER BY avg_gm;

-- 锂价是否走出下跌趋势
SELECT DATE_TRUNC('quarter', price_date) q, ROUND(AVG(price_usd_per_mt)) 
FROM product.fact_raw_material_price_daily
WHERE material_id=(SELECT material_id FROM product.dim_raw_material WHERE material_code='LIOH')
GROUP BY q ORDER BY q;

-- 良率是否随产线成熟爬坡(新厂Texas应低于老厂上海)
SELECT factory_code, ROUND(AVG(yield_rate),3) FROM public.v_factory_efficiency
GROUP BY factory_code;
```
