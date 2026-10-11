# clojerl2-006 nanopass 框架完整版

状态:已完成(2026-10-11,Erlang 实现)
里程碑:M1
依赖:clojerl2-005

## 目标

把框架从最小版补齐到 [01](../designs/01-nanopass-pipeline.md) §3 对照表的完整特性集,使完整 nanopass 路线(非 jolt 的 nanopass-lite)落地。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §3 — Scheme 框架到 clojerl2 的逐项对照表(extends / 自动穿通 / trace/echo / diff-languages / defpipeline)
- [01](../designs/01-nanopass-pipeline.md) §2 — 拒绝 nanopass-lite 的理由:样板成本由 extends 与自动穿通吸收
- [01](../designs/01-nanopass-pipeline.md) §5.9 — fixpoint 迭代组用于优化簇的 mode-gated 组合

## 工作内容

- [x] `extends` 继承:产生式并/差集(§1.3 的写法)
- [x] 自动穿通子句生成:pass 未提及的产生式自动恒等遍历
- [x] `trace` / `echo`:pass 级 IR 打印,dev 模式可用
- [x] `diff-languages`:两语言产生式 diff
- [x] `defpipeline` 组合器:含 fixpoint 迭代组(jolt 模式,`:max-iter` 截断)

## 验收标准

- 01 §3 对照表的每一行都有对应实现与测试
- 用 extends 链重写的玩具编译器(3+ 语言)通过测试
- defpipeline 的 fixpoint 组在演示 pass 对上按 `:max-iter` 终止

## 结论

2026-10-11 完成(`clj2_np`/`clj2_lang`,[designs/09](../designs/09-erlang-hosted-compiler.md) §1/§2):

- `extends`:L0→L1→L2→L3→L4→L5 六级差分链(加上 Labs 共 7 种语言),产生式增删与非终结符包含(`includes`,nanopass 的 `Expr ::= t`)。
- 自动穿通:`descend/4`、`mapfold/4`;按字段声明的非终结符选 processor,缺省即下降。
- trace/echo:`run/3` 的 `trace => [Pass]` + `trace_fun`(默认打印);`clj2_compiler_tests:trace_test/0` 断言每个 pass 按序出现且输出语言正确。
- `diff_languages/2`:`diff_languages_test/0`(L2 → L3:加 `fn_group`/`group_ref`,去 `letfn`)。
- fixpoint 组:管线元素 `{fixpoint, [Pass], #{max_iter => N}}`,不变或到 N 轮即停;`fixpoint_test/0` 用演示 pass 验证两种终止。
- 偏离:没有 `defpipeline` 宏,pipeline 是模块列表(`clj2_compiler:pipeline/0`);没有编译期 pass 校验,由每个 pass 边界的运行期整树校验替代。
