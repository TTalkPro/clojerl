# clojerl2-019 惰性序列

状态:已完成(2026-10-11;与 clojerl 1.0 的吞吐对比未能完成,见结论)
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

- [x] 原语:`lazy-seq`/`force`/`doall`/`dorun`/`realized?`(另有 `delay`/`deref`/`@`)
- [x] 逐元素实现:v1 不做 chunked-seq,分歧登记进 known-divergences(`:lazy-seq/no-chunking`)
- [x] pdict 版记忆单元:首次实现后按 Key 缓存(值不可变,不改写槽位);有上限
- [x] ETS 开关版:每单元一行,realize-once 用 `ets:update_counter/4` claim(003 结论,替代 select_replace),失败者等待赢家;开关默认 pdict
- [x] 跨进程分歧文档条目:同一 lazy-seq 在不同进程各自 realize 一次(`:lazy-seq/per-process-realization`)
- [x] 惰性链与进程调度无锁交互的注释与测试(03 §6;pdict 不跨进程,ETS 版 claim + 等待)

## 验收标准

- 惰性正确性测试:至多一次(pdict 版单进程内)/至少一次(ETS 版并发下最多算两次)语义按选定机制验证;副作用 thunk 的 realize 次数符合文档承诺
- 性能对比:与 clojerl 1.0 同级代码的吞吐差不超 003 报告固化的阈值
- 跨进程分歧条目进 known-divergences 注册表

## 结论

2026-10-11 完成,设计落点见 [designs/03](../designs/03-runtime-model.md) §6 注、基线见 `clojerl2/notes/lazy-seq.md`。

- 代码:`clj2_lazy`;`clj2_coll` 的 seq 原语认识惰性值与惰性尾 cons;kernel 的生产者改为惰性(map/filter/concat/take/drop/range/iterate/repeat/cycle/...);宏返回值在边界实现为普通形式;`@` 读作 `deref`。
- 验收(`clojerl2/test/clj2_lazy_tests.erl`):
  - 至多一次(pdict,单进程):副作用 thunk 在多次遍历下只跑一次;只实现被取到的元素;
  - ETS 版并发:8 个进程同抢一个慢 thunk,thunk 恰好运行一次、值一致(失败者等待赢家,比文档原来的"最多两次"更强);
  - 跨进程(pdict):3 个进程各实现一次、值一致——已登记 known-divergences;
  - 记忆单元有上限,长链(跳过 100 万元素的 filter)常量栈。
- **未完成**:"与 clojerl 1.0 同级代码吞吐差不超 003 阈值"——003 报告没有固化这样的阈值,且 clojerl 1.0 在本机 OTP 28 上编不完整(`clojure/instant.clje` 的正则字面量),无法运行对比代码;clojerl2 自身的 pdict/ETS 吞吐已作为基线入库(notes/lazy-seq.md),对比留作开放项。
- known-divergences 注册表首次建立:`clojerl2/test/known-divergences.edn`(10 条,含此前各任务的分歧),格式由 `clj2_divergences_tests` 校验;门控随 022。
- 顺带修正:eval 模块不再在返回后立即删除(否则结果里的惰性序列/闭包会 `undef`),保留最近 100 个;docstring 进 EEP-48 Docs chunk(`-moduledoc`/`-doc`,对照 OTP 28 absform 文档,见 02 §2.1)。
