# 与 JVM Clojure 的差异

clojerl2 的定位是 BEAM 上的 Clojure 方言(designs/00 D1)。凡是 BEAM 上做不到、或做了就是伪装的地方,我们选择不同,并把每一处登记下来。

- **登记表**:`test/known-divergences.edn`,每条都有原因、设计依据和替代写法。
- **实测佐证**:`test/clj2_divergence_evidence_tests.erl` 为每一条准备一个测试。如果哪天行为变了,测试就会失败,登记表必须跟着更新。CI 还会检查本文是否覆盖了每一条。
- **corpus 门控**:corpus 里因这些差异而与 JVM 结果不同的条目,都标注了对应的差异编号(`make certify`)。

下面共 31 条。每条依次是:JVM 上的行为 → clojerl2 上的行为 → 替代写法。

另外有很多功能是**还没做**,不属于有意的差异,例如 atom、多方法、正则。那些列在 [README](README.md#现状2026-10)。

---

## 数字

### `:number/beam-semantics` 数学运算按 BEAM 来

- **JVM**:`long` 溢出抛异常,`(= 0.0 -0.0)` 为 true,`(/ 1.0 0)` 得 `##Inf`,`(byte 128)` 抛异常。
- **clojerl2**:
  - 整数无界,`(+ 9223372036854775807 1)` 得 9223372036854775808;
  - 浮点精确比较,`(= 0.0 -0.0)` 为 false;
  - `(/ 1.0 0)` 报 `badarith`;BEAM 没有 Inf/NaN,`##Inf`/`##NaN` 读得进来,求值时抛 `ArithmeticException`(文件里提到它们不影响其余部分编译);
  - `byte`/`short`/`int`/`long`/`char`/`float` 这些转换不检查范围,`(byte 128)` 得 128;
  - `^long`/`^double` 类型提示不做任何转换,`%x` 对负数输出带符号的结果。
- **替代写法**:需要范围检查的地方自己判断;需要 64 位回绕的地方用 `(bit-and x 0xFFFFFFFFFFFFFFFF)`;浮点除法前先判断除数是否为零。
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
- **clojerl2**:`\a` 是 97,`(seq "ab")` 是 `(97 98)`,`(str \a)` 是 `"97"`,`(= \a 97)` 为 true;`char?` 对任何码点范围内的整数都为 true,`format` 的 `%c` 也接受整数。这是项目决定(2026-10-12):保持码点表示,与 Erlang 的码点列表天然互通。corpus 里测试字符渲染的条目在 `test/corpus-overrides.edn` 中改写。
- **替代写法**:尽量直接操作字符串(`subs`、`clojure.string` 的函数、正则)。要表示某个字符组成的字符串,直接写字符串字面量,如 `"\u3000"`,JVM 上也成立;要从码点拼回字符串,用 `(unicode/characters_to_binary (list c))`。
- 依据:designs/03 §1.1、§7。

## 函数与编译

### `:fn/arity-at-compile-time` 元数错误在编译期报告

- **JVM**:以错误的参数个数调用函数,运行时抛 `ArityException`。
- **clojerl2**:直接调用一个 fn var 时,如果元数不对,编译就不通过,因为 var 直接链接到模块函数。
- **替代写法**:元数只能在运行时确定时,通过值来调用:`(apply f args)`,或 `(let [g f] (g 1 2))`。这样会像 JVM 一样在运行时报错,也能被 `catch` 捕获。
- 依据:designs/03 §2.1a。

### `:interop/erlang-module-calls` 未知的限定名是 Erlang 模块调用

- **JVM**:`(zzs/union ...)` 里的 `zzs` 既不是别名也不是已有命名空间时,编译期报 `No such namespace: zzs`。
- **clojerl2**:调用头 `ns/f` 的限定名既不是别名、也不是已知命名空间时,它指一个 Erlang 模块(`(lists/reverse x)` 调用 `lists:reverse/1`)。所以未知别名在编译期不报错,调用执行时才失败(`undef`)。
- **替代写法**:在使用别名的 form 之前 `require` 好命名空间(JVM 上 fn 体内的 `require` 在编译期同样不建立别名);别名拼错时,看运行时的 `undef` 错误。
- 依据:designs/09 §2(resolve:其余 `mod/fun` 调用头成为 `erl_call`)、§3(Erlang 调用)。

### `:vars/forward-references` 同一文件里可以先用后定义

- **JVM**:fn 体里引用文件后面才定义的 var,编译期报 `Unable to resolve symbol`,要先写 `declare`。
- **clojerl2**:命名空间文件(以及任何作为一个单元编译的代码)在编译任何形式之前先声明全部顶层 var,所以 fn 体可以调用文件后面才定义的 var。在 REPL 里每个形式单独编译,未定义的名字仍然是编译错误。
- **替代写法**:在 JVM 上能编译的代码不用改;要在两边都能跑的代码,照 JVM 的要求写 `declare`。
- 依据:designs/03 §2.1(`clj2_p_declare`)。

### `:macros/defmacro-form` defmacro 是编译器形式

- **JVM**:`(macroexpand-1 '(defmacro m [a] a))` 展开成 `(do (clojure.core/defn m ([&form &env a] a)) (. (var m) (setMacro)) (var m))`。
- **clojerl2**:`defmacro` 由编译器直接处理,不是宏,`macroexpand-1` 原样返回它。
- **替代写法**:不要依赖 `defmacro` 的展开结果;要判断一个 var 是不是宏,用 `(:macro (meta #'m))`。
- 依据:designs/01 §5(parse 的内核形式)。

### `:fn/structural-identity` fn 按值比较

- **JVM**:每次求值 fn 形式都得到一个不同的对象。
- **clojerl2**:fn 是 Erlang fun,按值比较。同一个 fn 形式、捕获的值也相等的两个闭包,既 `=` 也 `identical?`,放进集合会合并成一个。
- **替代写法**:不要把 fn 的身份当标识用,显式加上标识,例如 `{:id 1 :f f}`。
- 依据:designs/03 §1.1、§2.1。

### `:exceptions/erlang-classes` 底层是 Erlang 的异常

- **JVM**:每个异常都是某个 Throwable 子类的实例,`catch` 按类选择。
- **clojerl2**:`catch` 同样按 JVM 类选择,包括父类,例如 `RuntimeException` 能捕获 `ArithmeticException`;类层次来自 `clj2_class` 的 JVM 模型。但底层的错误是 Erlang 的,所以:
  - Erlang 错误被归到最接近的 JVM 类:`badarith` 是 `ArithmeticException`,`function_clause`/`badarg` 是 `IllegalArgumentException`,下标越界是 `IndexOutOfBoundsException`,其余是 `RuntimeException`;
  - 运行时自身抛出的错误在 `ex-data` 的 `:type` 里注明了对应的 JVM 类;
  - Erlang 的 exit 和 throw 只能被 `:exit`/`:throw`/`:default`/`Exception`/`Throwable` 捕获;
  - 模型里没有的 JVM 类在编译期报错;
  - future 主体抛出的异常,`deref` 时原样重新抛出,不包装成 `ExecutionException`。
- **替代写法**:照 JVM 的写法捕获需要的类即可;如果要区分 Erlang 错误对应的具体 JVM 子类,就捕获一个更宽的类(`RuntimeException`),再在处理代码里看 `(ex-data e)` 或消息。
- 依据:designs/09 §3。

## 协议

### `:protocols/type-designators` extend-type 只认类模型里的类

- **JVM**:`extend-type` 接受任何类和接口,还有 `reify`。
- **clojerl2**:`extend-type` 接受 clj2 类模型里的 JVM 类和接口(java.lang、java.util、clojure.lang 的:`Object` `String` `Number` `Map` `IPersistentVector` ……),分派时沿着值的类的祖先链查找;clj2 的类型标签(`integer` `vector` `map` …… `default`)以及 `deftype`/`defrecord` 的名字同样可以用。没有 `reify`,类模型之外的类(`java.io.File`、用户的 Java 类)不能扩展。
- **替代写法**:原来用 `reify` 的地方,改成 `defrecord` 加 `extend-type`;扩展类模型认识的类(或 clj2 标签)。
- 依据:designs/03 §4.1a。

## 命名空间、重定义与绑定

### `:namespaces/hot-code-two-versions` 重定义遵循 BEAM 两版本语义

- **JVM**:重定义 var 后,所有地方立即看到新值。
- **clojerl2**:
  - 重新加载命名空间,或在 REPL 里重定义 var(每个 REPL var 有自己的模块)时,旧版本仍然保留;
  - 此前取走的 fn 值继续运行旧代码,新的调用走新代码;
  - 再重定义一次,最旧的版本就被清除,仍持有它的 fn 值再被调用会报 `badfun`;
  - 如果有进程正在执行最旧的版本,重定义会失败(`old_code_in_use`);
  - 在运行时被改值的 var(表达式里的 `def`、`alter-var-root`、`with-redefs`)不走上面这套:它的值第一次被改时搬进 var 表(只换一次代码),此后每次改值都只是改表,所有调用方立即看到新值,也没有版本上限的问题。
- **替代写法**:想总是用到最新定义时,保存名字而不是值:直接写 `(f ...)`,或包一层 `(fn [& args] (apply f args))`。
- 依据:designs/02 §5、designs/03 §2.2。

### `:vars/core-direct-linked` clojure.core 的 var 不能在运行时改值

- **JVM**:`(with-redefs [deref my-deref] ...)` 里,用户代码对 `deref` 的调用都走新值(core 内部是直接链接的,不受影响)。
- **clojerl2**:clojure.core 直接链接进所有针对它编译的代码,包括 core 自己,所以 core 里 fn 和常量 var 的 root 不能在运行时改:对它们 `alter-var-root`、`with-redefs`,或在表达式里 `def`,会抛 `IllegalStateException`,信息里带这个编号。动态 var(`*out*`、`*print-length*` 等)照常 `binding`、`set!`。
- **替代写法**:自己定义一个包一层的 var 并调用它,例如 `(defn my-deref [x] (deref x))`,然后 `(with-redefs [my-deref ...] ...)`。
- 依据:designs/03 §2.1a。

### `:vars/self-calls-direct` fn 对自己的调用不经过 var

- **JVM**:fn 体里按名字调用自己,走的是 var,所以 `alter-var-root` 换上的新值在旧值的递归里也会被调用到。
- **clojerl2**:命名空间模块里的 var 一旦在运行时被改值(`with-redefs`、`alter-var-root`、表达式里的 `def`),模块里 var 之间的调用都改走 var 表;但一个 fn 对自己的调用留在自己的函数体里,和 `recur` 一样。例如 `(alter-var-root #'f (fn [old] (fn [n] (if (zero? n) :new (old n)))))` 之后,`old` 的递归不会再进到新值里。
- **替代写法**:需要让递归经过可替换的值时,把 fn 自身作为参数传进去,或者让它递归调用一个辅助 fn,新值去包那个辅助 fn。
- 依据:designs/03 §2.1a、§2.2。

### `:namespaces/symbols` 命名空间就是符号

- **JVM**:`*ns*` 是 `clojure.lang.Namespace` 对象,打印为 `#namespace[user]`。
- **clojerl2**:`*ns*`、`in-ns`、`the-ns`、`find-ns`、`create-ns` 都用符号表示命名空间,`*ns*` 打印为 `user`。
- **替代写法**:需要名字时写 `(ns-name *ns*)` 或直接用 `*ns*`。原来调用 Namespace 对象方法的代码,要改用 clj2 的函数。
- 依据:designs/03 §2.1。

### `:symbol/no-metadata` 符号不带元数据

- **JVM**:符号可以带元数据,`(meta '^:foo bar)` 是 `{:foo true}`,`with-meta` 对符号可用。
- **clojerl2**:符号就是 atom,本身不带元数据:`(meta '^:foo bar)` 是 `nil`,对符号 `with-meta` 会失败。写在 `def` 名字上的元数据会保留,经过定义类的宏也一样(`(defn ^:private f ...)`、`(defmulti ^:dynamic m ...)`、`(defonce ^:private x ...)`):编译器把读入时宏调用名字上的元数据,接到展开结果里同名的 `def` 上。
- **替代写法**:元数据放在 var 或集合上,不要放在符号值上;宏需要名字的元数据时,改为显式传一个 map 参数。
- 依据:designs/03 §1.1。

### `:dynamic/per-process-bindings` 动态绑定属于进程

- **JVM**:任何线程上都可以用 `bound-fn` 带上绑定;`future`、agent 自动带上。
- **clojerl2**:动态绑定存在进程字典里。`future`、agent 的动作和 `bound-fn` 会把调用方的绑定带过去,与 JVM 一致;其他进程(`erlang/spawn` 启动的、Erlang 回调的)一开始没有任何绑定,看到的是根值。REPL 的当前命名空间,以及 `*1`/`*2`/`*3`/`*e`,也是绑定。
- **替代写法**:交给 `erlang/spawn` 或 Erlang 代码的 fn,先用 `bound-fn` 包一层;或者把值显式作为参数、消息传过去。
- 依据:designs/03 §3。

## 状态

### `:refs/no-stm` 没有 ref 和 STM

- **JVM**:`ref`、`dosync`、`alter` 提供多对象事务。
- **clojerl2**:`ref`/`dosync`/`sync`/`alter`/`commute`/`ref-set`/`ensure` 都会抛出 ex-info 说明不支持。BEAM 没有多对象事务内存,假装支持就是在隔离性上说谎。
- **替代写法**:把一起变化的状态放进同一个值:用一个 atom 存一个 map(`swap!` 原子地更新它),或者交给一个 agent / gen_server 持有,通过消息更新。
- 依据:designs/03 §5.2。

### `:state/explicit-lifetime` 可变单元不会被回收

- **JVM**:atom、promise、agent 不再被引用时由 GC 回收。
- **clojerl2**:BEAM 没有终结器,也没有弱引用,无法得知一个值何时不再被引用。因此:
  - 写过的 atom 会一直保留它的 ETS 行,直到虚拟机停止;只读过的 atom 不占任何空间;
  - promise、future 的结果行,以及 agent 的进程,也一直保留;
  - volatile 存在创建它的进程的进程字典里,进程退出时才释放,其他进程读不到。
- **替代写法**:长期存在的 atom 和 agent 只创建一次(用 `def`),不要在长期运行的进程里每次调用都新建;每个请求的临时状态放在局部绑定、`loop`/`recur` 或进程自身的状态里;短期工作交给单独的进程,进程退出时它的 volatile 随之释放。
- 依据:designs/03 §5.2。

### `:agents/process-per-agent` 每个 agent 一个进程

- **JVM**:`send` 和 `send-off` 用不同的线程池;动作执行期间发出的 send 会暂存,动作成功后才派发;`shutdown-agents` 之后再 send 会抛异常。
- **clojerl2**:每个 agent 是一个进程,按到达顺序执行动作。`send` 和 `send-off` 共用这一个队列;动作执行期间发出的 send 立即派发;`shutdown-agents` 什么也不做。
- **替代写法**:普通用法不用改。不要依赖"失败的动作里发出的 send 会被丢弃",也不要依赖 `shutdown-agents` 停止 agent。
- 依据:designs/03 §5.2。

### `:values/no-identity` 值没有对象身份

- **JVM**:`identical?` 和 `compare-and-set!` 比较的是对象身份,两个内容相同的新向量不是同一个对象。
- **clojerl2**:BEAM 的值没有身份,`identical?` 就是精确相等(`=:=`):`(identical? [1 2] (vector 1 2))` 为 true;`compare-and-set!` 在当前值等于期望值时就会交换。
- **替代写法**:不要用 `identical?` 或 `compare-and-set!` 区分内容相同的值;确实需要时,在值里显式带上版本号或标识,例如 `{:version n ...}`。
- 依据:designs/03 §1.1、§5.2。

### `:collections/map-entry-vectors` map entry 就是二元向量

- **JVM**:map entry 是 `clojure.lang.MapEntry`:`(map-entry? [:a 1])` 为 false,`(key [:a 1])` 抛异常,`(empty (first {:a 1}))` 为 nil。
- **clojerl2**:map entry 就是两个元素的向量,没有单独的类型:`map-entry?` 对任何二元向量为 true,`key`/`val` 也接受它,`empty` 得到 `[]`。
- **替代写法**:不要用 `map-entry?` 区分 entry 和自己构造的二元组;`key`、`val` 对两者都可用。
- 依据:designs/03 §1.1。

### `:sorted/comparator-calls` sorted 集合调用比较器的次数不同

- **JVM**:sorted map/set 是红黑树 `PersistentTreeMap`,构建 1024 个递增键调用比较器 12301 次。
- **clojerl2**:sorted 集合是自己的平衡树,调用比较器的次数不同(通常更少)。顺序、查找和相等都一样。
- **替代写法**:比较器不要有副作用,不要统计它被调用的次数。
- 依据:designs/03 §1.3。

### `:collections/exact-keys` map 的键按项精确比较

- **JVM**:map 的键、set 的元素按 `=` 比较,`(get {[1 2] :a} '(1 2))` 得到 `:a`。
- **clojerl2**:hash map 和 set 底层是 Erlang map,键按 Erlang 项精确比较。所以两个 `=` 但表示不同的键(元素相同的列表和向量)、或者元数据不同的键,是两个不同的键:上面的 `get` 得到 nil,`assoc` 这样的键会新增一项而不是替换。键是数字、字符串、关键字、符号,或者同一种集合时,行为与 JVM 一致。
- **替代写法**:复合键统一用一种集合(比如都用向量),不要依赖键上的元数据;可能以 seq 形式到来的键先用 `(vec k)` 规整。
- 依据:designs/03 §1.3。

### `:collections/map-order` map 不按插入顺序迭代

- **JVM**:不超过 8 项的 map(array-map),以及用 `array-map` 构造的任意大小 map,按插入顺序迭代:`(keys {:c 3 :a 1 :b 2})` 得到 `(:c :a :b)`。
- **clojerl2**:map 底层是 Erlang map,按 Erlang 内部的顺序迭代(同一组键顺序固定,与构造方式无关),不记插入顺序:上例可能得到 `(:b :a :c)`。`keys`、`vals`、`seq`、打印,以及建立在它们之上的 `frequencies`、`group-by`、`merge`、`zipmap` 等的结果顺序都可能不同;相等、查找和哈希不受影响。
- **替代写法**:不要依赖 map 的顺序(JVM 上 hash map 本来也不保证):需要顺序时对条目排序、在 map 旁边另存一个有序的键向量,或者使用 sorted-map。
- 依据:designs/03 §1.3。

### `:transients/wrapped` transient 包装持久值

- **JVM**:transient 是可变的;`persistent!` 之后再使用它会抛出 `IllegalAccessError`。
- **clojerl2**:BEAM 的值不可变,transient 包装的是一个持久值。`conj!`、`assoc!` 等返回下一个 transient,所以按 Clojure 的要求使用返回值的代码都能正常工作;但 `persistent!` 之后再用、或者用了旧的 transient,都不会被检测出来。transient 也不会比持久操作更快。
- **替代写法**:每个 bang 操作都使用它的返回值(Clojure 本来就这样要求);这里用 transient 没有速度上的收益,直接用持久操作也一样。
- 依据:designs/03 §1.1。

### `:seqs/class-model` seq 只有两种表示

- **JVM**:seq 有一族具体类:`Cons`、`LongRange`、`Range`、`Iterate`、`Repeat`、`Cycle`、`ChunkedCons`、`ArraySeq`、`APersistentMap$KeySeq` ……,`(class (range 5))` 是 `clojure.lang.LongRange`。
- **clojerl2**:seq 要么是 Erlang 列表(有限、已实现),要么是惰性序列:`class` 报 `clojure.lang.PersistentList` 或 `clojure.lang.LazySeq`,对那些具体 seq 类做 `instance?` 以及打印类名都会不同。seq 的行为(`first`、`rest`、`count`、`=`、`hash`)相同。
- **替代写法**:用谓词(`seq?`、`sequential?`、`coll?`、`counted?`)判断,不要对具体的 seq 类用 `class` 或 `instance?`。
- 依据:designs/03 §6。

## 宿主

### `:host/jvm-classes` 只有常用的 JVM 成员

- **JVM**:任何 Java 类都可以用互操作语法调用。
- **clojerl2**:没有 JVM。互操作语法落到宿主垫片(`clj2_jvm`),实现了 java.lang、java.util、clojure.lang 里常用的成员(`Integer/parseInt`、`Math`、String 方法、异常构造器、`StringBuilder`、Var/Symbol/Keyword 成员……)。其他类不可用:java.io 的文件、流、reader 和 URL,java.net,java.text 与 java.time/Calendar(因此 `format` 的 `%t`),带种子的 `java.util.Random`,具名字符集,Thread 对象。用到时抛 IllegalArgumentException(no matching method)。
- **替代写法**:用 Clojure 函数(`slurp`、`spit`、`clojure.string`、不带 `%t` 的 `format`、`rand`),或直接调 Erlang 模块:`file`、`filename`、`io`、`calendar`、`unicode`、`rand`、`erlang:system_time`(`(file/read_file path)`、`(calendar/universal_time)` ……)。
- 依据:designs/09 §3。

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
