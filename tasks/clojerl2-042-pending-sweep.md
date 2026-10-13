# clojerl2-042 其余待办类别

状态:已完成(2026-10-13)
里程碑:M6(一致性收尾)
依赖:clojerl2-041

## 目标

清理剩下的 `:pending/*`:regex-edge 12、runtime-eval 31、core-bugs 20、printer 20、var-surface 18、laziness 10、format-edge 8,以及 records、metadata、ref-types、strings-io、special-forms 等小类。

## 工作内容

- [x] 正则按 Erlang 的 re(PCRE)走(用户决定,2026-10-13):新登记差异 `:regex/erlang-semantics`(字符类交集、`\cX`、`(?x)` 在转义里、look-behind 规则),12 条改挂
- [x] `read`/`read+string`(字符串 reader 上只读一个形式,其余留给 `read-line`)、`line-seq`
- [x] fn var 在值位置与 `var-get` 取到同一个值(`(identical? > @#'>)`);`Var/intern` 会建命名空间;`require` 把别名改指别的命名空间时抛 IllegalStateException;`def` 可以用本命名空间限定的名字(宏里语法引用的 def);deftype 的类名不在 `ns-interns` 里;`(deref nil)` 是 NullPointerException
- [x] `for` 重写:修饰符按源码顺序生效,`:while` 结束所在绑定的遍历,能看到前面的 `:let`;`cond->`/`cond->>`/`some->`/`some->>` 的展开形状同 JVM;`definline` 实例化模板;`(map f)` transducer 接受多个输入;带 `&` 的向量解构按 `(seq x)` 走(map、set 也能解构);`:arglists` 去掉开头的 `&form &env`;协议方法 var 的元数据带 `:protocol`;`extenders` 不列 deftype/defrecord 自带的实现;nil 不落到 Object 的实现;宏可以把 fn 值拼进代码;`*suppress-read*` 默认 nil
- [x] `print-method`/`print-dup` 是真正的多方法,打印器对用户方法的类型调用它(嵌套值也是),`remove-method` 后恢复;`*print-meta*`;异常 `pr` 为 `#error {:cause .. :via [..] :trace []}`,`str` 为 "类名: 消息"(ExceptionInfo 再加数据);StringWriter 的 `.toString`
- [x] reader 的 `^Tag` 元数据键改为 `:tag`;`read-string` 保留列表上的元数据;`quote` 保留列表上的用户元数据
- [x] core 与标准库 var 带 JVM Clojure 的文档字符串和 arglists:`tools/gen-jvm-docs.clj` 用 JVM Clojure 1.12.4 生成 `priv/clj2/jvm-docs.eterm`(EPL-1.0),自身没有的 var 才用;`(doc map)` 与 JVM 一致
- [x] Var 对象:`getTag`、`setMacro`、`bindRoot`、`alterRoot`、`unbindRoot`、`.ns`/`.sym` 与 `.-ns`/`.-sym`;未绑定的 var 的值是 `clojure.lang.Var$Unbound`;编译器把 `.bindRoot`/`.alterRoot` 的目标当作可改根的 var
- [x] `with-local-vars` 按 JVM:var 初始未绑定,form 里是本进程的线程绑定(`thread-bound?`、`with-bindings`、`alter-var-root` 改根),出了 form 再 `var-set` 抛 IllegalStateException
- [x] 惰性:`iterate` 取首元素不调用 f;`pmap` 半惰性(领先处理器数 + 2 个),无限序列不再挂起;`eduction` 是 `clojure.core.Eduction` 类型(可 seq、可 reduce、`sequential?`,不是 seq/coll,`count` 抛 UnsupportedOperationException,打印与 `=` 按其元素)
- [x] format:`%#010x` 的零填充在 `0x` 之后,`%+x`/`%+o` 抛 FormatFlagsConversionMismatchException,`%0$s` 抛 IllegalFormatArgumentIndexException,`%5n` 抛 IllegalFormatWidthException;`%a` 带精度时按半偶舍入、进位升指数、次正规数规格化,`%08a` 在 `0x` 后补零
- [x] atom 的 `:meta`(非 map 抛 ClassCastException)与 `:validator`(初值不合法即抛 IllegalStateException);atom/agent 的 `alter-meta!`/`reset-meta!`;`with-meta` 先实现惰性序列
- [x] record 的 `map?`/`coll?` 为 true,`.-__extmap`/`.-__meta`
- [x] deftype 方法里的 seq 类型相等(Sequential 的 deftype 与向量按元素比较);一个类型的 impl 模块在首次调用其方法时按需加载
- [x] 改登记:Inf/次正规数 → `:number/beam-semantics`;类即符号的 `str` → `:host/jvm-classes`(差异说明已补充);`ns`/`defmacro` 不是 var → `:macros/defmacro-form`(说明已补充);transient 原地修改 → `:transients/wrapped`;map 顺序 → `:collections/map-order`;分块 → `:lazy-seq/no-chunking`;跨进程 `set!` → `:dynamic/per-process-bindings`;jolt 特有写法 → `:pending/corpus-environment`

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `pending_sweep_test`

## 结论

- 本机门控:eunit 664 全过;corpus 4228 → **4314**/4841(89.1%),0 新失败、0 过期;CTS 5733 → **5743**(失败 233、错误 388,基线已重写)。登记差异 33 条。
- 剩余 `:pending`:corpus-environment 17(期望值来自 jolt 或 JVM 上没导入的类)、metadata 3(列表元数据经 `conj`/`pop`/`into` 不保留:带元数据的列表在这里是惰性序列)、compiler 3、laziness 2、special-forms 1(deftype 可变字段)。

## 后续(同日)

- corpus 环境:提到 `*ns*` 的条目在 `user` 里跑(JVM 在 user 的 REPL 里求值);期望 `:throws` 时,JVM Clojure 也没有的符号的编译错误算作抛出(用 `priv/clj2/jvm-docs.eterm` 判断;JVM 有而这里没有的仍算缺口)。
- `extend-type`/`extend-protocol` 写在表达式里改写为运行时的 `extend`;`deftype`/`defrecord`/`defprotocol` 写在表达式里时定义提升到当前顶层形式之前(与表达式里的 `def` 同一机制),表达式的值是类 / 协议名。
- deftype 的可变字段:构造时放进 cell,方法体里的读与 `set!` 改写为读写 cell(`quote` 内不改,语法引用里只改 `~` 部分)。
- `empty` 作用于 record 抛 UnsupportedOperationException。
- 改登记:列表元数据经 `conj`/`pop`/`into` 的 3 条 → `:seqs/class-model`(`(list 1)` 与 `(cons 1 [2])` 在这里都是 Erlang 列表,无法区分);带 transducer 的 `sequence` 不立即实现首元素 → `:lazy-seq/per-process-realization`(说明已补充)。
- 结果:eunit 665 全过;corpus **4320**/4841(89.2%);CTS 5743 / 233 / 388。剩余 `:pending`:corpus-environment 14、compiler 1、laziness 1(都源于文件整体编译后才运行的模型)。回归测试 `expression_type_forms_test`。
