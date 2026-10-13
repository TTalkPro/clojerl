# clojerl2-050 并发与状态改用 Erlang 进程

状态:已完成(2026-10-13)
里程碑:M7(designs/10)
依赖:clojerl2-049

## 目标

用户决定(2026-10-13):clojerl2 保留 Clojure 的核心语法体系,并发与共享状态直接用 Erlang 的进程体系,
删除 Clojure 自己的那一套:atom、volatile、agent、future、promise,以及 ref/STM。

## 工作内容

- [x] 删除 `atom`、`swap!`、`swap-vals!`、`reset!`、`reset-vals!`、`compare-and-set!`、`atom?`;atom 上的 watch、validator、元数据
- [x] 删除 `volatile!`、`vswap!`、`vreset!`、`volatile?`;core 的有状态 transducer 改用运行时的进程内单元(`clj2_ref:volatile/vreset`)
- [x] 删除 `agent`、`send`、`send-off`、`send-via`、`await`、`await-for`、`agent-error`、`restart-agent`、`set-error-handler!`、`error-handler`、
  `set-error-mode!`、`error-mode`、`shutdown-agents`、`*agent*`,以及 `clj2_ref` 里 agent 的实现
- [x] 删除 `future`、`future-call`、`future?`、`future-cancel`、`future-done?`、`future-cancelled?`、`promise`、`deliver`;`pmap`/`pcalls` 保留,
  内部用运行时的进程实现
- [x] 删除 STM 的占位函数(`ref`、`dosync`、`sync`、`alter`、`commute`、`ref-set`、`ensure`),名字不再解析
- [x] 运行时自己的共享单元改名为内部的 cell(`clj2_ref:cell/swap/reset`):数组、StringBuilder、deftype 可变字段、全局层次、`memoize`、
  clojure.test、clojure.pprint 改用它
- [x] `bound-fn` 对固定元数的 fn 返回同元数的 Erlang fun,可以直接交给 `erlang/spawn`
- [x] 差异登记:新增 `:state/erlang-concurrency`(取代 `:state/no-atom`),删除 `:refs/no-stm`、`:agents/process-per-agent`,改写
  `:state/explicit-lifetime`;corpus 中依赖这些 API 的 176 条改挂 `:state/erlang-concurrency`(harness 按未解析的符号自动归类)
- [x] 测试改写:状态用内部 cell,并发用 `erlang/spawn` + 消息

## 结论

eunit 全过;corpus 4318 → 4142/4841(差额都是依赖被删 API 的条目);CTS 5816 → 5530(部分测试命名空间用到这些 API 而整体无法编译),基线已重写。
