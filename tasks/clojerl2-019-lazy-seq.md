# clojerl2-019 惰性序列

状态:未开始
里程碑:M4
依赖:clojerl2-003

## 目标

实现惰性序列:`lazy-seq` = thunk + 记忆单元,默认 pdict 版;ETS 开关按 clojerl2-003 spike 结论定。

## 设计依据

- [03](../designs/03-runtime-model.md) §6 — `lazy-seq` = `{lazy_seq, Meta, ThunkOrCell}`,未实现时是 fun,实现后改写为缓存的 seq
- [03](../designs/03-runtime-model.md) §5.3 — 记忆化机制选型:pdict 默认,ETS 开关备选
- [03](../designs/03-runtime-model.md) §6 — chunked-seq v1 不做(优化而非语义),分歧登记
- [03](../designs/03-runtime-model.md) §6 — ETS 开关版 realize-once 用 `ets:select_replace` CAS,并发重复实现退化为"最多算两次"
- [00](../designs/00-overview.md) §6 风险 4 — 惰性序列 spike 判据

## 工作内容

- [ ] 原语:`lazy-seq`/`force`/`doall`/`dorun`/`realized?`
- [ ] 逐元素实现:v1 不做 chunked-seq,分歧登记进 known-divergences
- [ ] pdict 版记忆单元:首次 force 后槽位改写为缓存值
- [ ] ETS 开关版:每单元一行,realize-once 用 `ets:select_replace` CAS;开关默认值按 003 spike 报告定
- [ ] 跨进程分歧文档条目:同一 lazy-seq 在不同进程各自 realize 一次(纯函数语义下结果相同,仅副作用型 thunk 可观察)
- [ ] 惰性链与进程调度无锁交互的注释与测试(03 §6)

## 验收标准

- 惰性正确性测试:至多一次(pdict 版单进程内)/至少一次(ETS 版并发下最多算两次)语义按选定机制验证;副作用 thunk 的 realize 次数符合文档承诺
- 性能对比:与 clojerl 1.0 同级代码的吞吐差不超 003 报告固化的阈值
- 跨进程分歧条目进 known-divergences 注册表

## 结论

(完成后填写)
