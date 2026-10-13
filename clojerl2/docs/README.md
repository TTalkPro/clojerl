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
- `refer`/`refer-clojure`/`use`,`ns` 的 `(:refer-clojure :exclude/:only/:rename ...)` 与 `(:use ...)`,`require` 的 `:rename`;不存在或私有的名字按 JVM 抛 `IllegalAccessError`;私有 var 与私有宏在别的命名空间里被拒绝,`(var ns/私有)` 仍可取到;
- reader 条件 `#?`/`#?@`(特性 `:clje` 与 `:default`),`.cljc` 文件可直接 `require`;
- 标准库命名空间:`clojure.string`、`clojure.set`、`clojure.walk`、`clojure.template`、`clojure.test`(`deftest`/`is`/`are`/`run-tests` ……,见 [getting-started.md](getting-started.md))、`clojure.edn`(`read-string` 的 `:readers`/`:default`/`:eof`,按 EDN 严格校验)、`clojure.math`、`clojure.pprint`(`pprint`/`cl-format`)、`clojure.repl`(`doc`/`source`/`dir`/`apropos`);
- reader:数字分组下划线(`1_000_000`)、记录字面量 `#ns.Rec{...}`/`#ns.Rec[...]`、`#=`、`*data-readers*`/`*default-data-reader-fn*`、`read-string` 的 `:features`/`:eof`,读错误的消息与异常类型同 JVM;
- `#inst` 字面量(`java.util.Date`,`inst-ms`)与 `*print-length*`/`*print-level*`/`*print-namespace-maps*`;
- 引用类型:atom(`:meta`/`:validator` 选项、`alter-meta!`)、volatile、agent、future、promise、`binding`/`bound-fn`、`with-local-vars`(ref/STM 有意不提供);
- 读与打印:`read`/`read+string`/`line-seq`、`print-method`/`print-dup` 多方法、`*print-meta*`、异常打印为 `#error {...}`;core 与标准库 var 带 JVM 的文档字符串和 arglists(`(doc map)`);Var 对象的 Java 方法(`bindRoot`/`alterRoot`/`setMacro`/`getTag`/`unbindRoot` ……);
- var 的运行时改值:表达式里的 `def`、同一文件里重复的顶层 `def`、`alter-var-root`、`with-redefs`/`with-redefs-fn`(包括别的命名空间里的 var)、var 的 watch 与 validator、对动态 var 的 `set!`、`locking`;clojure.core 的 fn 不能改值(见 differences.md);
- 多方法与层次:`defmulti`/`defmethod`、`derive`/`isa?`/`prefer-method`,支持自定义层次;
- 字符串与 IO:正则(Erlang 的 re/PCRE,`re-find`/`re-seq`/`re-matches`…)、`clojure.string`、`format`/`printf`(java.util.Formatter 语法)、`*out*`/`*in*`/`*err*` 重定向、`with-out-str`/`with-in-str`、`slurp`/`spit`、UUID;
- `deftype`/`defrecord`/`defprotocol`/`extend-type`/`extend-protocol` 也可以写在表达式里;deftype 的可变字段(`^:unsynchronized-mutable`/`^:volatile-mutable` + `set!`);
- 宿主类:`Thread`(`.start`/`.join`)、`Executors` 线程池(`submit`/`invokeAll`/`invokeAny`)、命名字符集(`(String. bytes "windows-1252")`、`.getBytes`、`URLEncoder`/`URLDecoder`,UTF-8 坏字节按 JVM 替换)、`Murmur3`/`Util` 哈希、Keyword 方法、`Class/forName`;`deftype`/`defrecord` 可以声明 JVM 接口(`clojure.lang.IReduceInit`、`ISeq` ……),扩展到接口的协议能分派到它们,实现 `ISeq` 的类型可以当 seq 用;
- BigDecimal:`1.5M` 字面量、算术、`with-precision`、`bigdec`、`format` 与常用的 `java.math.BigDecimal` 方法;
- 字符串是 UTF-8,中文可直接使用。

**还没有的**(括号里是 corpus 中因此失败的条目数,见 [corpus 基线](../notes/corpus-baseline.md);corpus 通过 4318 / 4841):
- 一个文件作为一个单元编译、之后才运行带来的时序差别:宏在编译期读不到同一文件里 var 的运行时元数据、宏展开出的 `do` 里前面的 `def` 在 `~@` 实现之前还没执行(1 + 1)
- 另有 14 条是 corpus 生成环境的问题(期望值来自 jolt 特有的写法、JVM 上没有导入的类或重生成时超时),不是功能缺失

**clojure-test-suite**:[jank-lang/clojure-test-suite](https://github.com/jank-lang/clojure-test-suite)(`vendor/clojure-test-suite`,子模块)全量跑在 CI 里(`make cts`),247 个命名空间,断言通过 5816 / 失败 187 / 错误 371,逐命名空间的失败数登记在 `test/cts-known-failures.txt`,变好变坏都会让 CI 变红。

**与 JVM 有意不同的**:见 [differences.md](differences.md)。共 33 条,每条都有替代写法。
