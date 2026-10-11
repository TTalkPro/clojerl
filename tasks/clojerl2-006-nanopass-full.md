# clojerl2-006 nanopass 框架完整版

状态:未开始
里程碑:M1
依赖:clojerl2-005

## 目标

把框架从最小版补齐到 [01](../designs/01-nanopass-pipeline.md) §3 对照表的完整特性集,使完整 nanopass 路线(非 jolt 的 nanopass-lite)落地。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §3 — Scheme 框架到 clojerl2 的逐项对照表(extends / 自动穿通 / trace/echo / diff-languages / defpipeline)
- [01](../designs/01-nanopass-pipeline.md) §2 — 拒绝 nanopass-lite 的理由:样板成本由 extends 与自动穿通吸收
- [01](../designs/01-nanopass-pipeline.md) §5.9 — fixpoint 迭代组用于优化簇的 mode-gated 组合

## 工作内容

- [ ] `extends` 继承:产生式并/差集(§1.3 的写法)
- [ ] 自动穿通子句生成:pass 未提及的产生式自动恒等遍历
- [ ] `trace` / `echo`:pass 级 IR 打印,dev 模式可用
- [ ] `diff-languages`:两语言产生式 diff
- [ ] `defpipeline` 组合器:含 fixpoint 迭代组(jolt 模式,`:max-iter` 截断)

## 验收标准

- 01 §3 对照表的每一行都有对应实现与测试
- 用 extends 链重写的玩具编译器(3+ 语言)通过测试
- defpipeline 的 fixpoint 组在演示 pass 对上按 `:max-iter` 终止

## 结论

(完成后填写)
