# clojerl2-003 lazy 记忆化 spike

状态:已完成
里程碑:M0
依赖:无

## 目标

验证 lazy-seq/delay 的记忆化机制([03](../designs/03-runtime-model.md) §5.3):pdict 记忆单元(跨进程重算,文档化分歧)vs ETS 单元(跨进程共享,成本高),量化吞吐差并给出开关默认值建议。

## 设计依据

- [03](../designs/03-runtime-model.md) §5.3 — 三种候选方案表与 v1 默认(pdict + 文档化分歧)
- [03](../designs/03-runtime-model.md) §6 — `{lazy_seq, Meta, ThunkOrCell}` 表示与 ETS CAS realize-once 语义
- [00](../designs/00-overview.md) §6 — 风险 4:惰性序列在 BEAM 的成本

## 工作内容

- [ ] 两种记忆化原型的吞吐基准:pdict 版与 ETS 版(每 delay 一行)
- [ ] 跨进程语义分歧的实测确认:同一 delay 在不同进程各自 realize 一次(纯 thunk 结果相同、副作用 thunk 可观察)
- [ ] ETS 版 realize-once 的正确性验证:`ets:select_replace` CAS 下并发重复实现退化为"最多算两次"
- [ ] 惰性链典型形态(长链 map/filter)在两版下的开销对比
- [ ] 给出开关默认值建议并起草分歧条目(供 known-divergences 注册表)

## 验收标准

- 报告入库,含两版吞吐数据与跨进程语义实测记录
- 03 §5.3 的默认选择被数据确认或修改(写入报告结论)
- 分歧条目草案提交入库

## 结论

已完成(OTP 28)。维持 03 §5.3 原判:**v1 默认 pdict,ETS 为开关备选(默认关)**。
链式场景 pdict 快 12-27 倍;跨进程语义实测:pdict 纯 thunk 分歧不可观察(值一致,仅执行次数不同);
naive lookup+insert 无 realize-once 保证(并发下观察者看到不同值),ETS 版必须用 claim 形态;
claim 原语选定 `ets:update_counter/4`(57ns,恰好一次),优于 select_replace(469ns,OTP28 拒绝预编译
match spec 是主因)。03 §6 的 select_replace 表述应改为 update_counter。
报告:[../clojerl2/notes/spike-003-lazy-memo.md](../clojerl2/notes/spike-003-lazy-memo.md)。
