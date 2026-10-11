# clojerl2-030 r6rs 一致性子集门控

状态:已废弃(2026-10-11)——不建 Scheme 金属层,见 [designs/09](../designs/09-erlang-hosted-compiler.md) §0。
里程碑:M0.5(Scheme 金属层)
依赖:029

## 目标

skeg `tests/r6rs/`(6,286 行)裁剪后作为金属层的一致性门,接入 CI。

## 设计依据

- [07](../designs/07-scheme-layer.md) §8(验收门)/§2.1(重入续延用例裁剪)
- `~/workspace/skeg/Skeg/src/scheme/tests/r6rs/`(复用源)

## 工作内容

- [ ] vendor 测试套件入 `clojerl2/scheme/tests/r6rs/`
- [ ] 裁剪清单:dynamic-wind 用例、call/cc 重入用例、(视 029)数值塔超集用例——逐条登记理由
- [ ] `run.sps` 适配:改为 stage0/expander 驱动的批跑器(Erlang 侧 escript)
- [ ] 失败基线:首轮跑出失败清单,分类(移植 bug / 裁剪遗漏 / 语义分歧)并给迁移项
- [ ] CI 门:全绿(或 known-divergences 白名单)才允许 M0.5 收口

## 验收标准

- 子集套件全绿 + 白名单外零失败
- 裁剪清单与白名单入库(notes/r6rs-gate.md),与 designs/07 §9 分歧登记交叉引用

## 结论

(完成后填写)
