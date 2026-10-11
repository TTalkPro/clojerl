# clojerl2-018 引用类型

状态:已完成(2026-10-12)
里程碑:M4
依赖:clojerl2-015, clojerl2-003

## 目标

实现引用类型:atom = ETS 行 + `ets:select_replace` CAS;agent = 专用进程;delay = thunk + 记忆单元;promise/future = 进程 + 消息;STM/ref 诚实 raise。

## 设计依据

- [03](../designs/03-runtime-model.md) §5.2 — 引用类型诚实降级总表(atom/agent/delay/ref/promise/future)
- [03](../designs/03-runtime-model.md) §5.2 — atom 备选"每值一进程"的否决理由
- [03](../designs/03-runtime-model.md) §5.3 — 记忆化机制选型(pdict 默认,ETS 开关)
- [03](../designs/03-runtime-model.md) §3 — pdict 动态绑定与 `bound-fn` 帧快照
- [03](../designs/03-runtime-model.md) §10 风险 5 — 热点 atom CAS 争用,文档劝用 agent

## 工作内容

- [x] atom:ETS 行存值,`swap!` = `ets:select_replace` CAS 重试循环,`reset!` = 单写,`deref` = ETS 读;watch 列表随行存储、变更后异步通知
- [x] agent:专用进程(gen_server 风格),`send`/`send-off` 的顺序性 = 消息队列顺序;动作执行携带绑定帧
- [x] delay:thunk + 记忆单元,默认 pdict 版;ETS 开关版按 003 spike 结论实现
- [x] promise/future:进程 + 消息,`deref` = `receive`,`deliver` = `send`;`future` 宏用 `bound-fn` 语义
- [x] `bound-fn`:创建时快照 pdict 绑定帧,调用时重建(03 §3)
- [x] STM 族(`ref`/`dosync`/`alter`/`commute`):明确 raise,错误信息指向 known-divergences 条目

## 验收标准

- atom CAS 并发正确性测试:多进程并发 `swap!` 无丢失更新
- agent 动作顺序性测试:`send` 序列按提交顺序执行
- 调 STM 族宏 raise 信息明确的错误,且该分歧已登记 known-divergences

## 结论

- **实现**:新模块 `clj2_ref`,core 的 01 层加了对应函数。
  - **atom**:ETS 行第一次写入时才建立,只读的 atom 不占空间。CAS 比较行里的版本号,用 `ets:select_replace`,不会把旧值拷进 match spec。有 validator,watch 在修改的进程里同步调用。实现了 `swap!`/`swap-vals!`/`reset!`/`reset-vals!`/`compare-and-set!`/`add-watch`/`remove-watch`/`set-validator!`/`get-validator`,以及 `(atom x :validator f)`。
  - **volatile**:放在进程字典里。
  - **promise**:没有进程,值写进 ETS 行,等待者由消息唤醒;支持带超时的 `deref`。
  - **future**:一个工作进程,用 `bound-fn` 语义带上调用方的绑定;实现了 `future-cancel`/`future-done?`/`future-cancelled?`;主体的异常原样重新抛出。
  - **agent**:每个 agent 一个进程,状态放在 ETS 行里。实现了 `send`/`send-off`/`await`/`await-for`,失败状态、`restart-agent`(含 `:clear-actions`)、error-handler 和 error-mode。
  - **delay**(019 已有):补上异常记忆化:主体抛出的异常也被记住,与 JVM 一致。
  - **`binding`/`bound-fn`/`bound-fn*`**:建立在新增的 **`var` 特殊形式**上。`(var x)` 和 `#'x` 都解析成常量 `#'ns/name`;运行时查注册表得到动态 var 的模块,非 dynamic 的 var 会被拒绝。
  - **STM 族**:错误信息里写明了 `:refs/no-stm`。
  - 打印格式仿照 JVM 的 `#object[clojure.lang.Atom {:status :ready, :val …}]`,只是不带地址。
- **验收**(`clj2_ref_tests`,11 个测试):
  - 50 个进程各做 200 次 `swap!`,没有丢失更新;另有 20 个进程往 map 值的 atom 里并发写入的测试;
  - agent 的动作按提交顺序执行,多个发送进程时,每个发送方自己的顺序也保持不变;
  - STM 的错误信息里带有登记条目编号。
  另外测了 promise 多个等待者、future 的取消和超时、binding 传到 future/agent/bound-fn、agent 的失败与重启。
- **新登记的差异**(各有佐证测试,`differences.md` 已同步):
  - `:state/explicit-lifetime`:写过的 atom 行、结果行和 agent 进程都不会被回收,因为 BEAM 没有终结器;
  - `:agents/process-per-agent`;
  - `:values/no-identity`:`identical?` 和 `compare-and-set!` 都按值比较,corpus 里有 2 条。
  另外修订了三条:`:dynamic/per-process-bindings` 收窄到"只有 future、agent、bound-fn 会带上绑定";`:exceptions/erlang-classes` 补上 future 的异常不包装;`:refs/no-stm` 的替代写法改为推荐 atom。
- **有了 atom 之后,corpus 暴露出的既有 bug**(已修):
  - **`doseq` 只展开第一组绑定,`:when`/`:while`/`:let` 和嵌套全部失效**(kernel 层),已重写;
  - `delay` 的主体抛异常时,每次 deref 都重跑主体;
  - `(deref (reduced x))` 报错。
  还看到但不在本任务范围、留在 triage 的:`iterate` 过早调用 f、`sequence` 急切实现、`mapcat` 的实现粒度与 JVM 不同。
- **corpus**:1955 → **2102 / 4842**。`:pending/ref-types` 从 218 条降到 11 条,剩下的是 `alter-var-root`/`with-redefs`/`locking`。
- **验证**:eunit 554 条、`make smoke`、`make docs-check`、`make example`、`make certify`(0 new / 0 stale)全部通过。
