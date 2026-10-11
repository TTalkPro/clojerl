# clojerl2-004 reader

状态:已完成
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

已完成。`clj2_reader.erl`(293 eunit 全绿,0 警告),导出 read/1,2、read_all/1,2、strip/1、loc/1。
产出契约见 [../clojerl2/notes/reader-format.md](../clojerl2/notes/spike-001-value-repr.md 已关联):
keyword=冒号前缀 atom(':a'/'::a');meta 恒为 map 或 nil(JVM 风格规范化,外层合并优先);
read 返回位置恒等于 loc(Form);EOF 位置 one-past-end;#() 对齐 JVM(裸 % 恒 %1、%foo 报错);
嵌套 #() 允许(遮蔽语义,known-divergence);bigradix 2r1010N 支持。
agent 初版有 ~8 个 reader bug + ~15 处测试契约错误,已全部修复。
契约文档:[../clojerl2/notes/reader-format.md](../clojerl2/notes/reader-format.md)。
