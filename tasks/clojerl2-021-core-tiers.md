# clojerl2-021 core 全层移植

状态:未开始
里程碑:M4
依赖:clojerl2-014, clojerl2-015, clojerl2-016

## 目标

完成 core 全层移植:`01-core` / `02-protocols` / `03-print` / `04-repl`,按 `boot-order.edn` 显式加载。

## 设计依据

- [04](../designs/04-bootstrap-and-conformance.md) §6.1 — core 分层表(jolt NN-*.clj 模式)与各层内容
- [04](../designs/04-bootstrap-and-conformance.md) §6.1 — 加载顺序由 `core/boot-order.edn` 显式声明,不做隐式文件序
- [04](../designs/04-bootstrap-and-conformance.md) §6.2 — form-at-a-time 驱动:宏对后续 form 立即可见
- [03](../designs/03-runtime-model.md) §8 — 第 2 层:能用第 0/1 层原语表达的一律上移到 Clojure
- [04](../designs/04-bootstrap-and-conformance.md) §7 M4 — core 全层加载是 M4 判据

## 工作内容

- [ ] 从 clojerl 1.0 `src/clj/clojure/` 移植改造各层;参考其 core.clje 分层与 `clje_exclude` 的经验(哪些 form 在 BEAM 上需改写或剔除)
- [ ] 每层按 `core/boot-order.edn` 的文件列表与依赖层加载,驱动器严格 form-at-a-time
- [ ] `01-core`:高阶函数、transducer、字符串函数,基于 00-kernel 与第 0 层原语
- [ ] `02-protocols`:核心协议对内建类型的 extend(Seq/ISeq 等到 vector/map/set/keyword 等);与协议运行时的加载顺序协调——extend 只编译 impl 模块,不阻塞后续层
- [ ] `03-print`:`pr`/`print-method`/`prn` 的 Clojure 侧,基于 020 的第 0 层 IO 原语
- [ ] `04-repl`:REPL 支持函数(doc、source、dir 等的库侧)

## 验收标准

- 四层全部加载成功,`boot-order.edn` 声明的依赖序被驱动器遵守
- jolt corpus 中按层标签(`:core`/`:seq`/`:print` 等)对应的条目通过率基线建立并写入报告,为 clojerl2-022 的门控铺路

## 结论

(完成后填写)
