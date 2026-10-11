# 05 ERTS 作为目标平台（提案）


> 编号说明:本文原属 IronScheme 设计文档序列(原编号 14),重排为本库 05;文中对 05/10/11/12/13 等编号文档的引用均指向 `IronScheme/designs/`(不在本库)。
状态：设计提案（未立项）。评估把 Erlang 运行时（ERTS/BEAM）纳入目标平台，作为 CLR、JVM（IronScheme/designs/11-portability.md D9）之外的第三类目标。

> 结论先行：**能纳入，但 ERTS 不是机器描述表里的"又一个表项"**——它不满足 IronScheme/designs/11-portability.md §2 D6"托管运行时对象模型"的前提（类/字段/方法、带类型局部变量+操作数栈、结构化异常），属于比 JVM 高一个层次的移植。天然契合点（真尾调用、异常、atom、任意精度整数、进程模型）反而优于 JVM；根本成本在**不可变堆与 `eq?` 身份语义的模拟**。

## 1. 与 D6 框架的关系

D6 把"机器"定义为 CLR/JVM 交集的托管对象模型，Lcil 是其 IR。BEAM 不在此交集内：

| Lcil 假设 | BEAM 现实 |
|---|---|
| 类、方法、字段 | 模块 + 函数，没有字段 |
| lambda → `Procedure` 子类，自由变量 → 字段 | fun 闭包 ✓（唯一契合的映射） |
| 库变量 → 静态字段 | 无可变静态字段（最近的是 `persistent_term` / ETS） |
| 带类型局部变量 + 操作数栈 | term 机器，无类型局部变量 |
| 结构化异常 try/catch/finally | `try ... catch ... after` ✓ |

因此 L3 之后的 codegen 与 Lcil **不可复用**，新路径：L3 → Erlang/Core Erlang 源码 → `erlc`。BEAM 没有公开稳定的文本汇编格式，生成源码交给 erlc 是唯一正道；发射器仍"只是序列化器"（D6 语），可以用 Scheme 写，自举友好。

沿用 D6 的**结构**（目标无关管线 + 每目标一份描述 + 每目标一个发射器），但承认 ERTS 的机器描述粒度更粗，不塞进托管机抽象制造"看起来可移植"的假象（D1 批判过的）。

## 2. 天然契合点（优于 JVM 的部分）

1. **真尾调用**：BEAM 原生 proper tail calls，psyntax 展开器的硬需求直接满足。JVM 移植的头号难题（IronScheme/designs/11-portability.md §2 D9 第 1 条）在 BEAM 上不存在。
2. **异常体系**：逃逸 call/cc（throw/catch 按身份标记）、`$try/finally`（`try...after`）、handler 链（进程字典或 ETS 持有）——IronScheme/designs/13-clr-exceptions.md 的整套分层都有对应物。
3. **数据类型**：符号 = atom，列表原生，任意精度整数原生。
4. **async**：BEAM 进程 + 消息比 `Task<object>` 更贴合 `(ironscheme async)` 的语义；D2 可移植包装层几乎不用改。
5. **自举**：D8 交叉编译路径原样成立——.NET 上的 IronScheme 以 `target = erts` 编译 boot 源码产出 Erlang 源码，ERTS 侧只需运行时（Erlang 原语模块）+ 加载器。不动点检验同理。
6. **热更新**白送。

## 3. 根本性错配（成本所在）

### 3.1 不可变堆 vs 可变性与 `eq?` 身份 —— 立项前必须回答

- R6RS 有可变对（`set-car!`/`set-cdr!`）、可变字符串、可变向量、可变记录字段；BEAM 的项全部不可变。
- 更根本的是 **`eq?`**：BEAM 没有对象身份，结构相同的项不可区分；R6RS 的 `eq?` 在对、字符串、记录上是身份判定。
- 出路只有装箱模拟：每个可变/需身份的对象包一层"单元"（ETS 行 / 进程 / 带唯一 id 的元组）。这会抵消 BEAM 的原生性能优势，`eq?` 走查表。
- **建议先做 spike**：手工用 Erlang 实现 cons 单元 + `eq?` + `set-car!` + 可变向量，测性能，再决定是否立项。这是整个提案的第一个技术问题，先于发射器。

### 3.2 原语契约（D7）的 Erlang 实现

约 230 个 `$` 原语重写为 Erlang。难点集中在：IO 端口（Erlang IO 是消息式）、可变字节向量（binary 不可变）、散列表（ETS 模拟）。性质同 D7 所述"和 Chez 的 C 内核一样没法共享"。

### 3.3 字符串

有趣的对冲：Erlang 传统字符串就是**码点列表**，天然符合 IronScheme/designs/12-strings.md 的按码点语义，但内存代价大；binary（UTF-8）下标 O(n)。窄/宽表示需按 BEAM 重新设计。

## 4. 按 D2/D6 的复用盘点

| 层 | 复用 |
|---|---|
| L0 ~ L3 pass 链（`host-*` 节点，iron-056/057） | ✅ 完全复用 |
| codegen | ❌ 重写（fun/模块/ETS 而非类/字段/方法） |
| Lcil | ❌ 不适用；新文本 IR 或直接产 Erlang 源码 |
| 发射器 | ❌ 新写（Scheme 写 Erlang 源码生成器） |
| 运行时原语 | ❌ 新写（Erlang，约 230 个） |
| 机器描述表 | ⚠️ 框架保留，ERTS 表项粒度远超"类名/内联模板" |
| 自举路径（D8 交叉编译） | ✅ 原样成立 |

互操作按 D1 诚实命名：`(ironscheme erts)`，暴露 Erlang 模块/函数/进程概念，不假装可移植。

## 5. 推进路径（如立项）

1. **Spike（先行）**：手工 Erlang 实现可变单元 + `eq?` + `set-car!` + 可变向量 + 一个散列表，跑性能基准。判定标准：cons 密集代码的性能损失是否在一个数量级以内。
2. 原语子集：只先实现 boot 镜像需要的 `$` 原语子集（对照 `primitives.ss`）。
3. 发射器：L3 → Erlang 源码（fun/模块映射），.NET 侧交叉编译 boot（D8）。
4. 运行时加载器 + REPL 冒烟。
5. 不动点检验：ERTS 上的 IronScheme 编译自己 = 交叉编译产物。

## 6. 与其他文档的关系

- IronScheme/designs/11-portability.md：本文是 D6 框架适用边界的第一个具体测试；ERTS 超出"托管机"前提，结构上沿用、抽象上另立。
- IronScheme/designs/13-clr-exceptions.md：异常分层在 BEAM 上的映射（throw/catch/after）作为契合点引用。
- IronScheme/designs/12-strings.md：字符串的窄/宽表示需按 BEAM 重新设计（§3.3）。
- IronScheme/designs/05-bootstrap.md：D8 交叉编译增加第二个目标实例。
