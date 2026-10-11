# clojerl2 用户文档

clojerl2 是跑在 BEAM(Erlang/OTP)上的 Clojure 方言:每个命名空间编译成一个 BEAM 模块,没有解释器,与 Erlang 直接互操作。它不追求与 JVM Clojure 逐字节兼容,有意的差异都登记在案、有设计依据、有测试佐证。

| 文档 | 内容 |
|---|---|
| [getting-started.md](getting-started.md) | 安装、REPL、运行脚本和程序 |
| [erlang-interop.md](erlang-interop.md) | 调用 Erlang/OTP、值的对应关系、进程与消息、从 Erlang 调用 Clojure |
| [rebar3.md](rebar3.md) | rebar3 项目、插件命令、编译缓存 |
| [differences.md](differences.md) | 与 JVM Clojure 的全部已登记差异,以及替代写法 |

## 现状(2026-10)

clojerl2 还在开发中。下面是诚实的现状,不是路线图。

**能用的**:
- 编译器、REPL、命令行 `bin/clojerl2`、rebar3 插件和编译缓存;
- clojure.core 的大部分:序列与集合函数、惰性序列、transducer、解构、宏、协议(`defprotocol`/`extend-type`/`defrecord`)、`ns`/`require`/`eval`;
- 字符串是 UTF-8,中文可直接使用。

**还没有的**(括号里是 corpus 中因此失败的条目数,见 [corpus 基线](../notes/corpus-baseline.md)):
- 尚未移植的 clojure.core 函数,或已有函数缺少某些元数(arity),例如 transducer 形式(492)
- 正则表达式、`format` 的大部分、字符串/字符函数、读写 IO(311)
- atom、volatile、agent、future、promise、`binding`(218)
- `class`/`type`/`instance?` 等宿主类型查询(208)
- 值上的元数据,即 `meta`/`with-meta`(131)
- `clojure.string`、`clojure.set`、`clojure.walk` 等标准库命名空间(125)
- 有序集合(114)、transient(79)、多方法与层级(77)、BigDecimal(66)

**与 JVM 有意不同的**:见 [differences.md](differences.md)。共 16 条,每条都有替代写法。
