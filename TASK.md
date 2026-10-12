# TASK.md — clojerl2 任务索引

clojerl2:基于 nanopass 的 Clojure on ERTS 全新实现。设计文档见 [designs/](designs/)(00 总览 / 01 管线 / 02 后端 / 03 运行时 / 04 自举与一致性;05、06 为 IronScheme 文脉的背景文档;07 Scheme 金属层(已作废);08 nanopass 宿主调研;**09 编译器宿主改为 Erlang,2026-10-11——nanopass 框架与全部 pass 用 Erlang 写,直接产出 absform,不建 Scheme 层、不需要种子与不动点**)。任务文件在 [tasks/](tasks/),每任务一文件,含 目标/设计依据/工作内容/验收标准/结论。

里程碑与验收判据定义见 [designs/04 §7](designs/04-bootstrap-and-conformance.md)。

## M0 — Spike(风险验证,可并行)

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-001](tasks/clojerl2-001-value-repr-spike.md) | 值表示 spike(打标元组 vs map+?TYPE) | 无 | 已完成 |
| [clojerl2-002](tasks/clojerl2-002-protocol-dispatch-bench.md) | 协议分派三方案基准 | 无 | 已完成 |
| [clojerl2-003](tasks/clojerl2-003-lazy-memo-spike.md) | lazy-seq/delay 记忆化 spike | 无 | 已完成 |

## ~~M0.5 — Scheme 金属层~~(2026-10-11 整体作废,见 designs/09)

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-026](tasks/clojerl2-026-scheme-primitives.md) | ~~Scheme 原语层(Erlang,可变单元=ets)~~ | 无 | 已废弃 |
| [clojerl2-027](tasks/clojerl2-027-stage0-erlang.md) | ~~stage0 编译器(Lcore-Erlang → .beam)~~ | 026 | 已废弃 |
| [clojerl2-028](tasks/clojerl2-028-boot-libs-port.md) | ~~boot 库移植(三项修正:call-with-return/try/nil)~~ | 026, 027 | 已废弃 |
| [clojerl2-029](tasks/clojerl2-029-expander-bringup.md) | ~~expander 上线(syntax-case + 库系统)~~ | 028 | 已废弃 |
| [clojerl2-030](tasks/clojerl2-030-r6rs-gate.md) | ~~r6rs 一致性子集门控~~ | 029 | 已废弃 |
| [clojerl2-031](tasks/clojerl2-031-nanopass-beam.md) | ~~nanopass 上线(skeg 子模块复用)~~ | 029 | 已废弃 |

## M1 — reader 与 nanopass 框架(Erlang)

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-004](tasks/clojerl2-004-reader.md) | Erlang Clojure reader(Lcore 契约) | 无 | 已完成 |
| [clojerl2-005](tasks/clojerl2-005-nanopass-core.md) | nanopass 框架(`clj2_np`/`clj2_lang`) | 无 | 已完成 |
| [clojerl2-006](tasks/clojerl2-006-nanopass-full.md) | 框架补齐(extends/穿通/trace/fixpoint/diff-languages/非终结符包含) | 005 | 已完成 |

## M2 — pass 管线端到端

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-007](tasks/clojerl2-007-parse-resolve-driver.md) | parse/resolve + form-at-a-time 驱动器(含宏系统) | 004, 005 | 已完成 |
| [clojerl2-008](tasks/clojerl2-008-transform-passes.md) | 变换 pass 组(recur/loop/letfn/ANF/case/const-fold/inline/verify;解构归 core) | 007 | 已完成 |
| [clojerl2-009](tasks/clojerl2-009-labs-emitter.md) | Labs 文法 + absform 发射器 | 005 | 已完成 |
| [clojerl2-010](tasks/clojerl2-010-e2e-pipeline.md) | 端到端打通(M2 验收) | 008, 009 | 已完成 |

## M3 — core 冷启动(2026-10-11:种子与不动点作废)

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-011](tasks/clojerl2-011-subset-discipline.md) | ~~编译器源码子集纪律 + lint CI~~ | 010 | 已废弃 |
| [clojerl2-012](tasks/clojerl2-012-seed-genesis.md) | ~~种子生成~~(并入 014) | 011, 014 | 已废弃 |
| [clojerl2-013](tasks/clojerl2-013-fixpoint-gate.md) | ~~不动点门控(selfhost/remint)~~ | 012 | 已废弃 |
| [clojerl2-014](tasks/clojerl2-014-kernel-tier.md) | 00-kernel 层划定 + boot-order | 010 | 已完成 |

## M4 — 运行时全量与一致性

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-015](tasks/clojerl2-015-var-ns.md) | Var/NS 运行时(直接链接) | 010 | 已完成 |
| [clojerl2-016](tasks/clojerl2-016-protocols.md) | 协议(impl 模块 + 存在性缓存) | 015, 002 | 已完成 |
| [clojerl2-017](tasks/clojerl2-017-multimethods.md) | 多方法(分派模块 absform 化) | 015 | 已完成(改为 ETS 方法表) |
| [clojerl2-018](tasks/clojerl2-018-ref-types.md) | 引用类型(atom/agent/delay/future) | 015, 003 | 已完成 |
| [clojerl2-019](tasks/clojerl2-019-lazy-seq.md) | 惰性序列(thunk + 记忆单元) | 003 | 已完成(含 clojerl 1.0 吞吐对比) |
| [clojerl2-020](tasks/clojerl2-020-strings-io.md) | 字符串与 IO 原语层 | 010 | 已完成 |
| [clojerl2-021](tasks/clojerl2-021-core-tiers.md) | core 全层移植(01-04 层) | 014, 015, 016 | 已完成 |
| [clojerl2-022](tasks/clojerl2-022-corpus-conformance.md) | corpus + known-divergences 门控 CI | 021 | 已完成(含 clojure-test-suite 门控 `make cts`) |

## M5 — 工具链与发布

| 任务 | 标题 | 依赖 | 状态 |
|---|---|---|---|
| [clojerl2-023](tasks/clojerl2-023-repl-cli.md) | REPL 与 clojerl2 CLI(单轨求值) | 014, 021 | 已完成 |
| [clojerl2-024](tasks/clojerl2-024-rebar3-cache.md) | rebar3 插件 + 编译缓存 | 023 | 已完成(整条 rebar3 命令的 20% 判据只部分达标) |
| [clojerl2-025](tasks/clojerl2-025-docs-divergences.md) | 用户文档 + known-divergences 定稿 | 022, 024 | 已完成,真实用户试用待安排 |

## 关键路径

```
004 ✔ ─┐
005 ✔ ─┴─ 007 ─ 008 ─┐
          005 ─ 009 ─┴─ 010 ─┬─ 014 ─┐
                             ├─ 015 ─ 016 ─┐
                             │   014,015,016 ─ 021 ─ 022 ─┐
                             │                 014,021 ─ 023 ─ 024 ─ 025
```

M0(001-003)、M1(004-006)、M2(007-010)已完成:nanopass 管线按 01 §5 全部落地(designs/09 §2)。M3 的 core 冷启动(014)已完成:clojure.core 的 00-kernel 层由 `clj2_core:boot/0` 加载。
