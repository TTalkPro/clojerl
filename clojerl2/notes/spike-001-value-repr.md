# spike-001 值表示基准报告(clojerl2-001)

状态:已完成。对应 [designs/03-runtime-model.md](../../designs/03-runtime-model.md) §1.4 的 spike 判据。
基准代码:[`../bench/spike-001-value-repr.escript`](../bench/spike-001-value-repr.escript)。

## 1. 判据与结论(先行)

designs/03 §1.4 的问题:**D8 值形状 `{Tag, Meta, Data}`(打标元组,A)相对 clojerl 1.0 的
`#{?TYPE => Tag, ...}`(map 内嵌类型键,B)在热路径上是否值得切换。**

实测(i9-13900H,OTP 28,单调度器,median):

| 操作 | B (map+?TYPE) | A ({Tag,Meta,Data}) | 加速比 |
|---|---|---|---|
| dispatch(tag→impl) | 7.36 ns | 5.63 ns | **1.31x** |
| dispatch + impl call | 7.38 ns | 5.87 ns | **1.26x** |
| tag 取标签 | 8.74 ns | 5.77 ns | **1.51x** |
| get(f2) 字段访问 | 3.82 ns | 2.82 ns | **1.36x** |
| with-meta(净值) | 15.12 ns | 5.58 ns | **2.71x** |
| construct(净值) | 2.90 ns | 1.54 ns | **1.89x** |
| = (same) | 9.63 ns | 10.50 ns | 0.92x |
| = (diff) | 9.45 ns | 10.95 ns | 0.86x |

**结论:采纳 A = `{Tag, Meta, Data}`(D8 维持)。** 热路径(分派/取标签/字段访问/with-meta)
全面领先 1.26x–2.71x;唯一回退是结构化相等 `=`(0.86x–0.92x),而相等在协议分派路径上不是
热操作,可接受。A'(字段内嵌 map 的变体)与 A 几乎无差,不引入。

with-meta 差距最大(2.71x 净值)符合预期:B 形态要重建整个 map(7 键),A 形态只换元组第 2 槽。

## 2. 环境与复现

| 项 | 值 |
|---|---|
| OTP | release 28 / ERTS 16.4.0.3,x86_64-pc-linux-gnu |
| CPU | 13th Gen Intel i9-13900H |
| 调度器 | `+S 1:1`(单调度器,排除调度噪声) |
| escript 编译模式 | `%%! -mode(compile)`(BEAM JIT,非解释执行) |
| 迭代/格 | record 100,000;collection 50,000;keyword 50,000 |
| 采样 | warmup 1 + samples 4,报告 median 与 min |

> 注:agent 初版迭代量(record 2M/collection 1M)在本机跑不完,已下调 20x 至上述值;
> 每格 10^5 次迭代 × 4 采样对 ns 级操作已足够稳定(min/med 偏差 <10%)。

```sh
escript clojerl2/bench/spike-001-value-repr.escript
```

## 3. 集合包装开销(§1.1)

外层包装 `{Tag,Meta,Inner}`(A)对 `#{?TYPE=>…, array/map=>Inner}`(B):

| 操作 | A | B | 说明 |
|---|---|---|---|
| vector construct | 9.53 ns | 7.41 ns | A 略慢(多一层元组) |
| vector nth(4) | 3.21 ns | 3.86 ns | A 快(element 直达) |
| map construct | 10.34 ns | 8.54 ns | 同上 |
| map get(k3) | 3.64 ns | 3.89 ns | A 略快 |
| set construct | 10.02 ns | 7.45 ns | 同上 |
| set contains(k3) | 8.66 ns | 13.32 ns | **A 快 1.54x**(B 要先 maps:get(array) 再 is_key) |

读操作 A 全面不慢,写操作 B 略快但差距 <3 ns,不是瓶颈。

## 4. DCE 校验(测量可信性)

证明 harness 的"构造+消费"循环不会被 BEAM 死码消除:

| 循环 | ns/op |
|---|---|
| 只遍历(无构造) | 2.79 |
| A 构造 + 丢弃结果 | 3.01(≈ 只遍历 → **被 DCE 掉了**) |
| B 构造 + 丢弃结果 | 3.40(同样被 DCE) |
| A 构造 + `=:= Ref` 消费(主表用法) | 8.50(真实成本) |
| B 构造 + `=:= Ref` 消费(主表用法) | 10.87 |

教训:**产生新值的操作必须用不透明比较消费结果**,否则测的是空循环。主表全部用
`b2i(V =:= Ref)` 消费,Ref 取自独立构建的同形列表。

## 5. keyword atom 策略(§1.2,附带原型)

`kw_new(Bin) = try binary_to_existing_atom(Bin) catch badarg -> {kw_dyn, Bin}`:

| 操作 | ns/op |
|---|---|
| b2ea 命中(已有 atom) | 27.71 |
| b2ea miss(异常 + {kw_dyn,Bin}) | 82.61(异常开销 3x) |
| atom =:= atom | 8.13 |
| atom =:= {kw_dyn,Bin}(归一后) | 30.40 |
| {kw_dyn} =:= {kw_dyn} | 52.10 |

**关键发现:`{kw_dyn, Bin}` 与 atom 形态作为 map key 不互通**(`#{user=>1}[{kw_dyn,<<"user">>}]`
≠ 命中)。这意味着动态 keyword 方案要求**所有** key 查找先归一化,成本太高。
该原型结论支持 reader 已落地的契约:**keyword 一律是冒号前缀 atom**(`:a`→`':a'`,
`::a`→`'::a'`),reader 期 `binary_to_atom` 直接建 atom(详见
[`reader-format.md`](reader-format.md))。atom 表膨胀风险由编译期已知 keyword 集合天然限定。

## 6. 修复记录(agent 初版的 bug)

1. `inputs()` 生成器模式 `{{T}, …}` 笔误 → 输入恒为空表 → 所有循环死循环(只打印 harness 基线)。
2. 全部 23 个"构造/with-meta/相等"循环的 refs/对照列表耗尽后不复位(function_clause)。
3. 6 个 eq/neq 循环第二列表的原始引用被主列表覆盖。
4. summary 里中文字符串用 `~s` 打印崩溃(需 `~ts`)。
5. 迭代量过大,本机不可复现,已下调(见 §2)。

以上均已修复,`escript` 退出码 0,checksum 全 ok。
