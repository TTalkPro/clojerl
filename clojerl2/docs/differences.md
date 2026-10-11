# 与 JVM Clojure 的差异

clojerl2 的定位是 BEAM 上的 Clojure 方言(designs/00 D1)。凡是 BEAM 上做不到、或做了就是伪装的地方,我们选择不同,并把每一处登记下来。

- **登记表**:`test/known-divergences.edn`,每条都有原因、设计依据和替代写法。
- **实测佐证**:`test/clj2_divergence_evidence_tests.erl` 为每一条准备一个测试。如果哪天行为变了,测试就会失败,登记表必须跟着更新。CI 还会检查本文是否覆盖了每一条。
- **corpus 门控**:corpus 里因这些差异而与 JVM 结果不同的条目,都标注了对应的差异编号(`make certify`)。

下面共 16 条。每条依次是:JVM 上的行为 → clojerl2 上的行为 → 替代写法。

另外有很多功能是**还没做**,不属于有意的差异,例如 atom、多方法、正则。那些列在 [README](README.md#现状2026-10)。

---

## 数字

### `:number/beam-semantics` 数学运算按 BEAM 来

- **JVM**:`long` 溢出抛异常,`(= 0.0 -0.0)` 为 true,`(/ 1.0 0)` 得 `##Inf`,`(< nil 1)` 抛异常。
- **clojerl2**:
  - 整数无界,`(+ 9223372036854775807 1)` 得 9223372036854775808;
  - 浮点精确比较,`(= 0.0 -0.0)` 为 false;
  - `(/ 1.0 0)` 报 `badarith`,BEAM 没有 Inf/NaN,所以 `##Inf`/`##NaN` 读不进来;
  - 比较按 Erlang 的项序,不检查类型,`(< nil 1)` 为 false;
  - `^long`/`^double` 类型提示不做任何转换,`%x` 对负数输出带符号的结果。
- **替代写法**:需要类型检查的地方自己判断;需要 64 位回绕的地方用 `(bit-and x 0xFFFFFFFFFFFFFFFF)`;浮点除法前先判断除数是否为零。
- 依据:designs/03 §1.1;项目决定(2026-10-11)。

### `:number/no-ratio-arithmetic` 没有分数运算

- **JVM**:`(/ 1 2)` 得分数 `1/2`。
- **clojerl2**:得 `0.5`。不能整除的整数除法给出浮点数。字面量 `1/2` 能读进来,但不参与运算。
- **替代写法**:精确整数除法用 `quot`/`rem`;确实需要精确分数时,自己保存分子和分母。
- 依据:designs/03 §1.1。

## 字符串与字符

### `:string/code-point-indexing` 按码点计数与下标

- **JVM**:字符串按 UTF-16 码元计,`(count "😀")` 为 2,`nth`/`subs` 是 O(1)。
- **clojerl2**:字符串是 UTF-8 binary,按码点计,`(count "😀")` 为 1;`nth`/`subs` 要从头走一遍,是 O(n)。中文、emoji 都按"一个字一个"计数,这一点比 JVM 更直观。
- **替代写法**:用 `seq`/`reduce` 遍历,不要在循环里反复用下标取字符;需要随机访问时,先用 `(unicode/characters_to_list s)` 转换一次。
- 依据:designs/03 §7。

### `:char/integer` 字符就是整数码点

- **JVM**:`\a` 是 `java.lang.Character`。
- **clojerl2**:`\a` 是 97,`(seq "ab")` 是 `(97 98)`,`(str \a)` 是 `"97"`。
- **替代写法**:尽量直接操作字符串(`subs` 等字符串函数)。要从码点拼回字符串,用 `(apply str (map (fn [c] (unicode/characters_to_binary (list c))) cs))`。
- 依据:designs/03 §1.1、§7。

## 函数与编译

### `:fn/arity-at-compile-time` 元数错误在编译期报告

- **JVM**:以错误的参数个数调用函数,运行时抛 `ArityException`。
- **clojerl2**:直接调用一个 fn var 时,如果元数不对,编译就不通过,因为 var 直接链接到模块函数。
- **替代写法**:元数只能在运行时确定时,通过值来调用:`(apply f args)`,或 `(let [g f] (g 1 2))`。这样会像 JVM 一样在运行时报错,也能被 `catch` 捕获。
- 依据:designs/03 §2.1a。

### `:fn/structural-identity` fn 按值比较

- **JVM**:每次求值 fn 形式都得到一个不同的对象。
- **clojerl2**:fn 是 Erlang fun,按值比较。同一个 fn 形式、捕获的值也相等的两个闭包,既 `=` 也 `identical?`,放进集合会合并成一个。
- **替代写法**:不要把 fn 的身份当标识用,显式加上标识,例如 `{:id 1 :f f}`。
- 依据:designs/03 §1.1、§2.1。

### `:exceptions/erlang-classes` catch 按 Erlang 异常类

- **JVM**:`catch` 写的是 Throwable 的类名,如 `ArithmeticException`。
- **clojerl2**:`catch` 接受 `:error`/`:exit`/`:throw` 三类;`:default`、`Exception`、`Throwable` 捕获全部。写 JVM 类名会编译报错,因为 BEAM 没有异常类层级。`throw` 抛出的是 Erlang `error`。
- **替代写法**:写 `(catch Exception e ...)` 或 `(catch :error e ...)`,在处理代码里按原因或 `(ex-data e)` 分派。
- 依据:designs/09 §3。

## 协议

### `:protocols/type-designators` extend-type 用 clj2 的类型标签

- **JVM**:`extend-type` 接受类和接口,还有 `reify`。
- **clojerl2**:`extend-type` 接受 clj2 的类型标签(`nil` `boolean` `keyword` `symbol` `integer` `float` `string` `list` `lazy_seq` `vector` `map` `set` `fn` …… 以及 `default`)、`deftype`/`defrecord` 的名字,还认少数 JVM 别名(`Object` `String` `Long` `Integer` `Double` `Boolean` `Keyword` `Symbol`)。没有类层级,没有 `reify`。
- **替代写法**:扩展 clj2 标签,例如用 `integer` 代替 `Long`/`Number`;原来用 `reify` 的地方,改成 `defrecord` 加 `extend-type`。
- 依据:designs/03 §4.1a。

## 命名空间、重定义与绑定

### `:namespaces/hot-code-two-versions` 重定义遵循 BEAM 两版本语义

- **JVM**:重定义 var 后,所有地方立即看到新值。
- **clojerl2**:
  - 重新加载命名空间,或在 REPL 里重定义 var(每个 REPL var 有自己的模块)时,旧版本仍然保留;
  - 此前取走的 fn 值继续运行旧代码,新的调用走新代码;
  - 再重定义一次,最旧的版本就被清除,仍持有它的 fn 值再被调用会报 `badfun`;
  - 如果有进程正在执行最旧的版本,重定义会失败(`old_code_in_use`)。
- **替代写法**:想总是用到最新定义时,保存名字而不是值:直接写 `(f ...)`,或包一层 `(fn [& args] (apply f args))`。
- 依据:designs/02 §5、designs/03 §2.2。

### `:namespaces/symbols` 命名空间就是符号

- **JVM**:`*ns*` 是 `clojure.lang.Namespace` 对象,打印为 `#namespace[user]`。
- **clojerl2**:`*ns*`、`in-ns`、`the-ns`、`find-ns`、`create-ns` 都用符号表示命名空间,`*ns*` 打印为 `user`。
- **替代写法**:需要名字时写 `(ns-name *ns*)` 或直接用 `*ns*`。原来调用 Namespace 对象方法的代码,要改用 clj2 的函数。
- 依据:designs/03 §2.1。

### `:symbol/no-metadata` 符号不带元数据

- **JVM**:def 名字上的元数据经过宏也能保留,`defn-` 定义的是私有 var。
- **clojerl2**:符号就是 atom,本身不带元数据。直接写在 `def` 名字上的元数据会保留(`^:private`、`^:dynamic`、`^{:doc ...}`),`defn` 的 docstring 也会保留;但要经过宏传递的元数据会丢失,所以 `defn-` 和 `(defn ^:private ...)` 定义出来的都是公开 var。
- **替代写法**:私有函数写成 `(def ^:private name (fn ...))`,文档写在 `defn` 的 docstring 里。
- 依据:designs/03 §1.1。

### `:dynamic/per-process-bindings` 动态绑定属于进程

- **JVM**:`future`、agent 会带上发起线程的绑定(binding conveyance)。
- **clojerl2**:动态绑定存在进程字典里,只属于设置它的进程。REPL 的当前命名空间,以及 `*1`/`*2`/`*3`/`*e`,也是如此。新进程看到的是根值。
- **替代写法**:要交给其他进程的值,显式通过参数或消息传过去。
- 依据:designs/03 §3。

## 状态

### `:refs/no-stm` 没有 ref 和 STM

- **JVM**:`ref`、`dosync`、`alter` 提供多对象事务。
- **clojerl2**:`ref`/`dosync`/`sync`/`alter`/`commute`/`ref-set`/`ensure` 都会抛出 ex-info 说明不支持。BEAM 没有多对象事务内存,假装支持就是在隔离性上说谎。
- **替代写法**:把一起变化的状态放进同一个值,交给一个进程持有(gen_server 或 agent),通过消息更新。单个值的情况,atom 会在后续版本(clojerl2-018)提供。
- 依据:designs/03 §5.2。

## 惰性序列

### `:lazy-seq/per-process-realization` 按进程记忆化

- **JVM**:一个惰性序列只实现一次,不管哪个线程去遍历。
- **clojerl2**:记忆存在进程字典里,另一个进程遍历同一个惰性序列时会再实现一遍。纯函数的结果相同,带副作用的 thunk 会在每个进程各执行一次。可以用 `clj2_lazy:set_memo/1` 切换到 ETS,做到跨进程只实现一次。
- **替代写法**:副作用不要放进惰性序列里(副作用用 `doseq`/`run!`);交给其他进程之前先实现掉(`doall`、`vec`)。
- 依据:designs/03 §5.3。

### `:lazy-seq/bounded-memo` 记忆有上限

- **JVM**:记忆没有上限。
- **clojerl2**:每个进程的记忆单元有上限(默认 100000 个),超过后清空,之后再遍历同一个序列会重新实现。这是为了不让长寿进程无限增长。
- **替代写法**:要反复遍历的序列先转成向量;确实需要更多时,用 `clj2_lazy:set_memo_limit/1` 调高上限。
- 依据:designs/03 §6。

### `:lazy-seq/no-chunking` 没有分块序列

- **JVM**:对向量做 `map`,取第一个元素时会一次实现 32 个。
- **clojerl2**:逐个实现,`chunked-seq?` 总是 false,没有 `chunk-first` 等函数。这是优化上的差别,语义不变。
- **替代写法**:不用改;依赖"分块提前实现"的代码(在 `map` 里做副作用)本来就不该这样写。
- 依据:designs/03 §6。
