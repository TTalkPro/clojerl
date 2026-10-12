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
- 引用类型:atom、volatile、agent、future、promise、`binding`/`bound-fn`(ref/STM 有意不提供);
- 多方法与层次:`defmulti`/`defmethod`、`derive`/`isa?`/`prefer-method`,支持自定义层次;
- 字符串与 IO:正则(Java 语法,`re-find`/`re-seq`/`re-matches`…)、`clojure.string`、`format`/`printf`(java.util.Formatter 语法)、`*out*`/`*in*`/`*err*` 重定向、`with-out-str`/`with-in-str`、`slurp`/`spit`、UUID;
- 字符串是 UTF-8,中文可直接使用。

**还没有的**(括号里是 corpus 中因此失败的条目数,见 [corpus 基线](../notes/corpus-baseline.md)):
- 尚未移植的 clojure.core 函数,或已有函数缺少某些元数(arity),例如 transducer 形式(507)
- `class`/`type`/`instance?` 等宿主类型查询(222)
- 值上的元数据,即 `meta`/`with-meta`(137)
- `clojure.set`、`clojure.walk`、`clojure.edn` 等其余标准库命名空间(18)
- 有序集合(116)、transient(79)、BigDecimal(66)
- `alter-var-root`、`with-redefs`、`locking`(11)

**与 JVM 有意不同的**:见 [differences.md](differences.md)。共 21 条,每条都有替代写法。
