# clojerl2-031 nanopass 上线(标准框架跑在金属层)

状态:已废弃(2026-10-11)——不建 Scheme 金属层,见 [designs/09](../designs/09-erlang-hosted-compiler.md) §0。
里程碑:M0.5(Scheme 金属层)
依赖:029

## 目标

nanopass-framework-scheme(skeg 子模块,MIT,固定提交 `c14d3924`)在金属层上运行:define-language/define-pass/归一/trace 全部可用。取代原 clojerl2-005/006("在 Clojure 内自实现框架")。

## 设计依据

- [07](../designs/07-scheme-layer.md) §0/§7
- `~/workspace/skeg/Skeg/src/scheme/lib/nanopass/implementation-helpers.skeg.sls`(209 行适配层模板)
- `~/workspace/skeg/Skeg/src/scheme/lib/nanopass-framework-scheme/`(上游子模块)

## 工作内容

- [ ] vendor nanopass 子模块入 `clojerl2/scheme/lib/nanopass-framework-scheme/`
- [ ] `implementation-helpers.clojerl2.sls`:format/gensym/eq-hashtable/record(source-information 桥到 annotated-call 位置)/`define-nanopass-record`(skeg iron-034 "记录类型定义一次"优化继承)
- [ ] 冒烟:define-language → define-pass → 归一循环 → nanopass-case 分派 → trace,各一例
- [ ] 原方案 005/006 的成果回收:其 L0-L3 语言定义草案(若有)转为 define-language 声明初稿
- [ ] 性能抽查:一个真实 pass 链(≥5 pass × 1000 节点)的耗时基线入库

## 验收标准

- 冒烟五项全过,[01](../designs/01-nanopass-pipeline.md) 的 L0 定义能用 define-language 表达
- 性能基线入库(notes/nanopass-beam.md)

## 结论

(完成后填写)
