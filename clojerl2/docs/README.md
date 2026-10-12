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
- 命名空间反射:`resolve`/`ns-resolve`/`ns-publics`/`ns-interns`/`ns-map`/`ns-refers`/`ns-aliases`/`find-var`/`intern`/`ns-unmap`/`remove-ns`/`requiring-resolve`/`bound?`;
- reader 条件 `#?`/`#?@`(特性 `:clje` 与 `:default`),`.cljc` 文件可直接 `require`;
- 标准库命名空间:`clojure.string`、`clojure.set`、`clojure.walk`、`clojure.template`、`clojure.test`(`deftest`/`is`/`are`/`run-tests` ……,见 [getting-started.md](getting-started.md));
- 引用类型:atom、volatile、agent、future、promise、`binding`/`bound-fn`(ref/STM 有意不提供);
- 多方法与层次:`defmulti`/`defmethod`、`derive`/`isa?`/`prefer-method`,支持自定义层次;
- 字符串与 IO:正则(Java 语法,`re-find`/`re-seq`/`re-matches`…)、`clojure.string`、`format`/`printf`(java.util.Formatter 语法)、`*out*`/`*in*`/`*err*` 重定向、`with-out-str`/`with-in-str`、`slurp`/`spit`、UUID;
- 字符串是 UTF-8,中文可直接使用。

**还没有的**(括号里是 corpus 中因此失败的条目数,见 [corpus 基线](../notes/corpus-baseline.md);corpus 通过 3614 / 4841):
- 尚未移植的 clojure.core 函数,或已有函数缺少某些元数(arity),例如部分 transducer 形式(118)
- reader 尚不接受的写法:部分数字语法、转义等(105)
- 编译器尚不接受的形式:fn 体内的 `def`、部分 `letfn`/`set!`/`.`/`new` 用法等(178 + 11)
- BigDecimal:`1.5M` 读得进来,求值时抛错(67)
- 其余命名空间反射与 `ns` 子句:`:use`、`:import`、`refer` 函数等(61)
- 部分宿主类型查询(20)
- `clojure.edn`、`clojure.math`、`clojure.pprint` 等其余标准库命名空间(22)
- `alter-var-root`、`with-redefs`、`locking`(12)
- 能跑但结果与 JVM 不一致、待逐条分诊的(357)

**clojure-test-suite**:[jank-lang/clojure-test-suite](https://github.com/jank-lang/clojure-test-suite)(`vendor/clojure-test-suite`,子模块)全量跑在 CI 里(`make cts`),247 个命名空间,断言通过 4660 / 失败 414 / 错误 743,逐命名空间的失败数登记在 `test/cts-known-failures.txt`,变好变坏都会让 CI 变红。

**与 JVM 有意不同的**:见 [differences.md](differences.md)。共 21 条,每条都有替代写法。
