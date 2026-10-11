# clojerl2-009 Labs 文法与 absform 发射器

状态:已完成(2026-10-11)
里程碑:M2
依赖:clojerl2-005, clojerl2-006

## 目标

定义 Labs(与 absform 一一对应的末端 IR)并实现纯序列化发射器 emit:Labs → absform 项 → `compile:forms/2`,零语义决策。

## 设计依据

- [01](../designs/01-nanopass-pipeline.md) §1.7 — Labs 边界:emit-lower 之后只剩结构翻译
- [02](../designs/02-beam-backend.md) §2 — 发射器架构与纯函数性质
- [02](../designs/02-beam-backend.md) §3.1 — 名称改编表(`? * ! < > = + - / .` 转义)
- [02](../designs/02-beam-backend.md) §3.2 — 字面量 `erl_parse:abstract/1` 技巧
- [02](../designs/02-beam-backend.md) §3.3-3.4 — 模块布局与 `__ns_init__/0` on_load 骨架
- [02](../designs/02-beam-backend.md) §4 — ANNO 纪律,禁止 `erl_anno:new(0)` 兜底

## 工作内容

- [x] Labs `define-language`:文法与 absform 一一对应;guard-safe 子语言为独立非终结符(02 §7 风险 1)
- [x] emit/1 纯序列化器:Labs 树进、Erlang 项出,不做任何"聪明事"
- [ ] ~~名称改编表实现~~:决定不做(02 §3.1 修订,015)
- [x] 字面量两路径:编译期已知 → `erl_parse:abstract/1` 构造树;含非字面量子项 → 运行时构造函数调用
- [x] 模块布局与 `-on_load(__ns_init__/0)` 骨架生成
- [x] ANNO 纪律落地:每个节点带 `erl_anno:new({Line,Col})`(属性与 `run/0` 例外,无源位置)
- [x] `compile:forms/2` 集成(含 debug_info 选项)

## 验收标准

- emit 输出经 `compile:forms` 成功产出 beam
- Labs 每个节点的源位置出现在 beam `Line` chunk
- 发射器纯函数性测试:同一 Labs 两次 emit 字节一致

## 结论

2026-10-11 完成:

- Labs 语言:`clj2_lang:get(labs)`,与 absform 一一对应;guard 子语言 `eguard` 为独立非终结符(`labs_guard_sublanguage_test/0`:remote 调用、非 guard BIF 在文法层被拒)。
- lower-labs(`clj2_p_labs`)做全部 Clojure 决策;emit(`clj2_p_emit`)是每节点一条子句的纯序列化器。
- 字面量:`erl_parse:abstract/2`(编译期已知,含 D8 集合);运行时构造走 `clj2_coll`。
- 模块布局与 `-on_load(__ns_init__/0)`:见 015。
- ANNO:节点位置原样进 absform,`line_in_stacktrace_test/0` 断言栈回溯的行号与文件指向 Clojure 源。
- 纯函数性:同一源码两次编译 .beam 逐字节一致(`deterministic_build_test/0`、`clj2_macro_tests:deterministic_test/0`)。
- 偏离:不做名称改编(02 §3.1 修订);属性与 `run/0` 的 Anno 为 0(没有对应源位置)。
