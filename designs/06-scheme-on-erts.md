# 06 Scheme on ERTS：独立方言的语言形态（提案）


> 编号说明:本文原属 IronScheme 设计文档序列(原编号 15),重排为本库 06;文中对 05/10/11/12/13 等编号文档的引用均指向 `IronScheme/designs/`(不在本库)。
状态：**已废**(2026-10-11)——本提案被 [07](07-scheme-layer.md) 以修正后的形式重新采纳(cleat 路线 + skeg RNRS 代码复用 + 逃逸续延);本文关于"为何不先建 Scheme 层"的论证前提(R6RS 全量 call/cc)已不成立,原文保留作历史记录。

状态：设计提案（未立项）。方向：不依赖 .NET 实现，借鉴 IronScheme 的经验，在 Erlang/ERTS 上独立自举一个 Scheme 方言。每个 Scheme runtime 是一个 BEAM 轻量进程（gen_server），与 Erlang 原生互操作，编译器沿用 nanopass 管线。

> 与 [05](05-erts-target.md) 的关系：05 号文评估"ERTS 作为 IronScheme 的目标"，结论是不塞进托管机抽象。本文是更彻底的方向——独立方言，以 BEAM 母语建模，并通过三项删减换取架构简化。

## 1. 定位：Scheme 方言，不是 R6RS 实现

三项删减决定了定位：

1. **不支持 FFI**：无 NIF/ports 到本机代码，原语全部纯 Erlang 实现。Erlang 互操作（`apply(M,F,A)`、fun 传递、消息）不是 FFI，保留。
2. **不要 dynamic-wind**：以 Erlang 的 `try/catch/after` 为元语言直接暴露清理语义。
3. **不要 call/cc，改名 `call-with-return`**：逃逸型、一次性、只向上——名副其实，砍掉重入幻觉。

三者互相咬合：没有重入续延 ⇒ dynamic-wind 退化为 try/finally ⇒ 砍掉无损失；dynamic-wind 的依赖方另有替身（§3）。定位类似 Clojure 之于 Common Lisp：借语法与精神，不背 R6RS 兼容包袱。

## 2. 自举（沿用 IronScheme 结构，种子换来源）

```
阶段 0：Erlang 写的核心语言解释器（≈ IronScheme.Stage0），运行文本种子
阶段 1：stage0 上跑 nanopass 编译器（Scheme 写的），编译 boot 源码 → Core Erlang → erlc → boot beam
阶段 2：beam 自编译，验证不动点
```

- **种子来源**：用 Chez 运行 psyntax 展开器一次性生成文本种子并提交（psyntax 原生跑在 Chez 上）。Chez 仅为构建期工具，不是运行时依赖；不动点后可自我再生。
- **目标 IR 选 Core Erlang**：erlc 官方支持的编译器目标格式，文本、显式 let/fun/词法作用域，比生成 Erlang 源码少一层语法摩擦；发射器只是序列化器，可用 Scheme 写。
- **风险**：psyntax 若内部使用 dynamic-wind/call/cc，需在 boot 内部保留非导出版本（§6 风险 1）。

## 3. 三项删减的依赖方处置

| 依赖方 | 原实现 | 新方案 |
|---|---|---|
| 清理语义（dynamic-wind 的 out） | `dynamic-wind` | `try/catch/after` 的 `after` |
| `parameterize` | dynamic-wind | **进程字典**：每参数一个 pdict 键，保存旧值 + put + after 里恢复。对应 IronScheme 的 AsyncLocal 参数槽（10 §2 D7），且更便宜。runtime=进程 ⇒ pdict 即"当前 runtime 的动态环境" |
| handler 链（`with-exception-handler`） | 动态绑定列表 | 同样住进 pdict |
| boot 内 dynamic-wind/call/cc 用法 | 逃逸型（IronScheme 审计结论） | 机械改写为 `after` / `call-with-return` |

表面语法直接暴露 Erlang 三类异常：

```scheme
(try body ...
  (catch (throw Pattern) ...)
  (catch (error Pattern) ...)
  (after cleanup ...))
```

## 4. 控制流体系（全部直接映射 BEAM 原生机制，无模拟层）

| 原语 | 语义 | BEAM 实现 |
|---|---|---|
| `call-with-return` | 逃逸跳转，一次性、向上 | `throw({scheme_k, Ref, V})`，捕获帧按 ref 匹配 catch（`make_ref` 作身份标记） |
| `guard` / `raise` | 条件系统：handler 链在事故现场运行，`raise-continuable` 保留 | handler 链在 pdict；guard 展开为 `call-with-return` + handler 注册（原 `call/cc` 展开式一行改名） |
| `try/catch/after` | 宿主异常 + 清理 | `try ... catch ... after` |
| `receive` / `send` | 进程间控制流 | 原生；`receive` 的模式匹配映射到 match 库 |

IronScheme 为 guard 保住的三条 R6RS 语义（事故现场运行、continuable、原环境重抛）在此完整保留——它们不依赖 call/cc 的重入，只依赖 handler 链 + 逃逸跳转。

## 5. runtime = gen_server 的模型

**边界划在"运行时实例"上，不是函数调用上**：进程内部 Scheme 调用 = 普通 Erlang 函数调用（零消息开销）；进程边界 = 顶层 eval/REPL/隔离单元。

收益：

| 收益 | 机制 |
|---|---|
| 多 runtime 隔离 | 每 gen_server 独立堆与 GC |
| 监督树 | runtime 崩溃自动重启 |
| 分布式 | 给远程 pid 发 `{eval, Form}` = 远程 REPL |
| 热升级 | `code_change` 保留全局状态换代码 |
| 抢占式调度 | reduction 计数对编译产物天然生效；Scheme 死循环卡不死调度器 |
| 串行化 | gen_server 本身即串行化器，IronScheme"runtime 非线程安全"的约束反转为结构保证 |

**并发模型**：初版单 runtime 单线程，并发走多 runtime + 消息传递（actor 风格，参照 Termite Scheme）。Scheme 共享堆线程与 BEAM 不共享内存的矛盾留待后续（共享堆需 ETS，代价大）。

## 6. 三项删减的联动红利

1. **async/await 整个特性不需要**：BEAM 进程里阻塞式 receive 即非阻塞（调度器抢占）。IronScheme 的整个 AsyncFrame 状态机（10 号文）在此无对应物——同步风格代码天然并发。`task-result` 等变成消息模式。
2. **错误处理与监督树合流**：未处理条件 → 默认 handler → gen_server 以 `error` 类崩溃 → 监督者重启，其他 runtime 不受影响。"let it crash"成为方言的错误处理上层建筑。
3. **运行时极简化**：无 escape-frame 内联优化、无状态机、无 AsyncLocal——控制流四个原语全部原生映射（§4）。

## 7. 风险清单（按优先级）

1. **可变对与 `eq?` 身份**：同 14 §3.1。不可变对用元组原生实现；可变对装箱 `{cell, Ref}` + ETS/pdict 查表。**spike 先行**：手工 Erlang 实现 cons 单元 + `eq?` + `set-car!` + 可变向量，cons 密集代码性能损失一个数量级以内才立项。
2. **psyntax 审计**：逐行确认展开器不用 dynamic-wind/真 call/cc；若用，boot 内部保留非导出版本，方言不暴露。
3. **pdict 的 GC 特性**：pdict 内容被 GC 扫描；handler 链与参数栈很小无碍，但立规矩"大块数据不进 pdict"。
4. **Core Erlang 能力边界**：验证 fun 作用域、receive、try/catch/after 组合在 Core Erlang 中的表达。

## 8. 落地顺序

1. Spike：可变对 + `eq?`（风险 1）
2. Erlang stage0 解释器 + Chez 生成种子
3. `call-with-return` + handler 链（pdict）+ guard——先把错误处理闭环跑通，它决定 psyntax 能否存活
4. try/catch/after 表面语法
5. gen_server runtime 壳 + REPL
6. nanopass → Core Erlang codegen

## 9. 与其他文档的关系

- [05](05-erts-target.md)：目标平台评估，本文取代其"塞进 D6 框架"的路线。
- IronScheme/designs/13-clr-exceptions.md：异常分层的"接警/送货"分析与"finally 可借、catch 不可借"结论在此的体现——guard 保留 handler 链，try/after 直借宿主。
- IronScheme/designs/10-async.md：async 状态机在 BEAM 上无必要（§6.1），`parameterize` 的 AsyncLocal 方案对应 pdict（§3）。
- IronScheme/designs/05-bootstrap.md：自举结构沿用，种子来源换成 Chez（§2）。
