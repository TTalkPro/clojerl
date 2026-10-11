# clojerl2-027 stage0 编译器(Lcore-Erlang → core Erlang → .beam)

状态:已废弃(2026-10-11)——不建 Scheme 金属层,见 [designs/09](../designs/09-erlang-hosted-compiler.md) §0。 已写的 stage0(`sk_*`,后改名 `cljk_*`)已删除,其 absform 发射经验并入 `clj2_p_emit`,bug 教训改写为 `clj2_compiler_tests:probe_test_/0`。
里程碑:M0.5(Scheme 金属层)
依赖:026

## 目标

Erlang 写的 stage0:Lcore-Erlang 文本 → analyzer → Erlang abstract forms → `compile:forms/2` 出 .beam。替代 skeg `Skeg.Stage0`(C#,1.1K 行);**只做编译路径,不做解释器**(宿主原生代码无自举问题)。

## 设计依据

- [07](../designs/07-scheme-layer.md) §4(Lcore-Erlang 文法)/§5(自举梯子)
- `~/workspace/skeg/Skeg/src/Skeg.Stage0/`(Analyzer.cs 的作用域/三分类逻辑为蓝本)
- `~/workspace/skeg/Skeg/designs/03-compiler.md` §2(Lcore 文法原文)

## 工作内容

- [ ] Lcore 文本 reader(quote/注释/字符串字面量/字符字面量/向量)
- [ ] analyzer:词法作用域(层数,下标)、三分类(词法变量/原语表/全局槽)、letrec 初始化检查(R6RS 限制)
- [ ] **捕获分析**(designs/07 §3 三档策略):标记每个 letrec/lambda 绑定是否被闭包捕获;未捕获 `set!` → BEAM 变量重绑定(x@N 改名,零开销);捕获 `set!` → 装箱 cell(pdict)
- [ ] specials:`$throw`/`$try/catch`/`$try/finally`/`$and?`/`$or?`/`call-with-return`
- [ ] erl-* 内部形式:`erl-call`/`erl-make-tuple`/`erl-tuple-ref`/`erl-tuple-size`
- [ ] 发射:闭包 = fun/2,case-lambda 按 arity 分派,尾调用( BEAM 原生)、`library-letrec*` 的双名写槽
- [ ] `annotated-call` 位置提取 → abstract forms 的 anno(调试信息)
- [ ] 确定性构建:gensym 计数器种子化,同一输入产出一致的 .beam
- [ ] 命令行:`sk_stage0:compile_dir/1`(目录批编译,依序)

## 验收标准

- 手写 Lcore 样本集(quote/if/lambda/case-lambda/letrec/set!/$throw/$try-*/多值)编译→执行全对
- 编译内部错误带位置信息
- 同一输入两次编译 .beam 一致

## 结论

(完成后填写)
