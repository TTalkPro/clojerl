# clojerl2-004 reader

状态:未开始
里程碑:M1
依赖:无

## 目标

Erlang 实现的 Clojure reader,产出 Lcore([01](../designs/01-nanopass-pipeline.md) §1.1 的契约:Clojure 数据 + `{:line :col :file}` 元数据),作为 reader↔编译器的唯一边界。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §1.1 — Lcore 契约:数据结构种类封闭 + 源位置经 metadata 可达
- [00](../designs/00-overview.md) §5 — reader 是架构图第一环,与编译器之间是数据契约边界
- [02](../designs/02-beam-backend.md) §4 — 源位置元数据供下游 ANNO 纪律消费
- [00](../designs/00-overview.md) §7 — M1 范围:reader + Lcore 文法

## 工作内容

- [ ] 完整 Clojure 语法:列表/vector/map/set/字符/字符串/关键字/符号/数字塔/readable 字面量
- [ ] 引号族(quote/syntax-quote/unquote/unquote-splicing)与元数据 `^`
- [ ] 注释与读取宏:`#_`、`#{}`、regex 字面量等
- [ ] 每个产出 form 附源位置元数据(line/col/file)
- [ ] 可参考 clojerl 1.0 `src/erl/clj_reader.erl` 的术语表,但独立成模块,不共享代码
- [ ] golden 测试集:文本 → 期望数据 + 位置

## 验收标准

- golden 测试集全绿
- 任意产出 form 的位置元数据可达(下游可按 02 §4 约定取到 line/col)
- reader 不依赖编译器任何模块(纯边界,可独立编译与测试)

## 结论

(完成后填写)
