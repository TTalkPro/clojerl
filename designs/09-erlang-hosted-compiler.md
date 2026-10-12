# 09 编译器宿主改为 Erlang:Erlang 内的 nanopass 框架与 pass 链

状态:**已采纳**(2026-10-11 用户裁决,第二次修订 D2/D3)。取代 [07](07-scheme-layer.md)(Scheme 金属层),修订 [00](00-overview.md) D2/D3、[01](01-nanopass-pipeline.md) §3、[04](04-bootstrap-and-conformance.md) §1-§4。已落地代码:`clojerl2/src/erl/clj2_np.erl`、`clj2_lang.erl`、`clj2_p_*.erl`、`clj2_compiler.erl`、`clj2_rt.erl`;测试 `clojerl2/test/clj2_compiler_tests.erl`。

> 结论先行:**不建 Scheme 层,编译器(nanopass 框架 + 全部 pass)长期用 Erlang 写,直接产出 absform**。三条目标约束:(1) 语法对齐 Clojure,平台相关处按 BEAM 习惯取舍;(2) nanopass——每条 pass 一对形式化语言,渐进加 pass 即渐进优化;(3) 直接编译为 absform,与 Gleam/Elixir 主流路线一致。Erlang 宿主同时满足三者,且消除了自举冷启动:编译器不是 Clojure 写的,就没有种子、没有不动点门控。

## 0. 裁决记录

| 日期 | 决策 | 文档 |
|---|---|---|
| 初版 | 编译器 Clojure 自寄宿,clojerl 1.0 做种子;nanopass 在 Clojure 内重实现 | 00 D2/D3、04 |
| 2026-10-11 上午 | 改为 cleat 路线:自研 Scheme-on-BEAM 金属层,复用 skeg RNRS 代码与 nanopass-framework-scheme | 07 |
| **2026-10-11 本文** | **不用 Scheme 层;nanopass 框架与 pass 长期在 Erlang;产出 absform** | 本文 |

推翻 07 的依据(审查记录见 [08](08-nanopass-host-languages.md) §5):

1. **Scheme 层是整整一个语言实现的成本**(原语层、boot 库移植、syntax-case expander、r6rs 门控:任务 026-030),换来的唯一收益是"nanopass 宏原样可用"。而 Clojure 的语义需求(不可变局部量、无 call/cc、fn 即 fun)比 Scheme 窄得多,用不上 Scheme 层的大部分能力。
2. **stage0 实测暴露的 bug 几乎全部来自 Scheme 特有语义**:三档 `set!` 的变量改名与 SSA phi 合并、R6RS `letrec`、`call-with-return`。Clojure 局部量不可变,这些机制整体不需要。
3. **Erlang 是 nanopass 风格的好宿主**([08](08-nanopass-host-languages.md) §3):函数子句即 syntax-case 子句,累积器即上下文穿线,TCO 有语言保证;OTP 编译器自身就是多 pass 的 Erlang 程序。
4. **代价我们认账**:没有编译期 pass 校验和 ellipsis 模板。由框架的**运行期语言校验**(每个 pass 边界整树按输出语言检查)与列表推导分别替代。

## 1. 框架:`clj2_np` + `clj2_lang`

### 1.1 语言即数据

```erlang
spec(l1) ->
    {extends, l0,
     #{terminals => #{uid => fun ?MODULE:is_uid/1, atom => fun is_atom/1},
       remove    => #{expr => [sym]},
       add       => #{expr => #{local => [uid], erl_call => [atom, atom, {list, expr}], ...},
                      binding => #{bind => [uid, expr]}, ...}}};
```

- 语言 = 终结符谓词表 + 非终结符表(`NT => #{Op => [FieldKind]}`),`FieldKind :: Terminal | NT | {list, K} | {opt, K}`。
- `extends` 只写增删差异(对应 nanopass `(extends L0)` 与 `+`/`-`);同名 op 重定义即替换。
- op 在一个语言里只能属于一个非终结符(构建期检查),所以节点自带类型,无需额外标签。

### 1.2 节点即 absform 形状的元组

`{Op, Anno, Field1, ..., FieldN}`,Anno 是 `erl_anno()`(reader 的 `{Line, Col}`)。选元组而非 map:pass 用**函数头模式匹配**写子句,和 absform、OTP 编译器内部表示同一习惯;Anno 原样流到 absform,BEAM 栈回溯直接是 Clojure 源位置(Gleam 1.19 强调的收益)。

### 1.3 自动穿通(nanopass 的 system clauses)

pass 只为要改的 op 写子句,其余一律交给框架,框架按**输入语言**的字段表重建节点、递归处理子节点:

```erlang
expr({recur, A, Args}, Target, L, St) -> ...;      % 只写关心的 op
expr({loop, A, Binds, Body}, Target, L, St) -> ...;
expr(Node, Target, L, St) ->                        % 其余:自动穿通
    clj2_np:mapfold(L, #{expr => fun(N, S) -> expr(N, Target, L, S) end}, Node, St).
```

| API | 用途 |
|---|---|
| `descend/4` | 重建节点,子节点按非终结符分派到 pass 的 processor(缺省继续下降);只向下传上下文 |
| `mapfold/4` | 同上,外加穿线累积器(uid 计数器等) |
| `fold/4`、`children/2` | 只读遍历,供分析 pass |
| `check/2` | 整树按语言校验,报错带路径 `[{Op, FieldIndex} ...]` |
| `run/3` | pipeline 驱动:`check`(默认开)在每个 pass 后按 `out` 语言校验;`trace => [PassName]` 打印该 pass 输出 |

### 1.4 pass 即模块

```erlang
-module(clj2_p_loop).
pass() -> #{name => lower_loop, in => l1, out => l2}.
run(Trees, PassState) -> {Trees1, PassState1}.
```

pipeline 是模块列表(`clj2_compiler:pipeline/0`)。**加一个优化 = 加一个模块进列表**,这就是"渐进式优化":先让朴素 pass 链正确,再插入 L→L 的优化 pass,框架保证插入点两侧的语言契约不变。PassState 只携带 `next_uid`(确定性 uid)与 `module`/`file`,不读全局状态(D5)。

## 2. 当前 pass 链(已落地,01 §5 清单已全部覆盖)

```
reader ─▶ Lcore ─parse─▶ L0 ─declare─▶ L0 ═(驱动:查外部 NS → scope)═▶ ─resolve─▶ L1
   ─validate-recur─▶ L1 ─lower-loop─▶ L2 ─lower-letfn─▶ L3 ─link─▶ L4
   ─{fixpoint: [inline]? const-fold}─▶ L4 ─normalize-anf─▶ L5 ─verify─▶ L5
   ─lower-labs─▶ Labs ─emit─▶ absform ─▶ compile:forms/2
```

| pass | 模块 | Lin→Lout | 规格 |
|---|---|---|---|
| parse | `clj2_p_parse` | Lcore→L0 | 输出 `top` 节点(`ns_decl`/`def`/`eval`),顶层 `do` 摊平;special form(含 `case*`)→ 节点;宏展开(驱动给的能力,§4.1)、syntax-quote、`defmacro`、集合字面量、`#()`;fn* arity 规则校验 |
| declare | `clj2_p_declare` | L0→L0 | 分析:NS 名、全部 def 的 var 种类表(前向引用)、require、限定符号涉及的 NS |
| resolve | `clj2_p_resolve` | L0→L1 | 词法作用域;binder → uid `{Sym, N}`;var(本 NS / 别名 / refer / 已知 NS)→ `varref`;其余 `mod/fun` 调用头 → `erl_call`;未解析即编译错误 |
| validate-recur | `clj2_p_recur` | L1→L1 | 分析:recur 必须在尾位置(含 `case*` 分支)、参数个数匹配、不跨 try |
| lower-loop | `clj2_p_loop` | L1→L2 | 每个 fn clause 得名(Erlang named fun);`loop*` = 立即调用的 fn;`recur` = 自调用(BEAM 尾调用) |
| lower-letfn | `clj2_p_letfn` | L2→L3 | letfn* → 一个 named "group" fun,成员 J = `G(J)`;自命名的多 arity fn 同样处理 |
| link | `clj2_p_link` | L3→L4 | var 直接链接:fn var 调用 → `M:f(...)`(变参打包剩余参数),其他 var → 访问器调用,fn var 作值 → fun 引用 |
| inline | `clj2_p_inline` | L4→L4 | 优化,**仅 release**:就地调用的单 clause、无自名、不 recur 的 fn 字面量 β-归约为 `let*`(不复制函数体) |
| const-fold | `clj2_p_constfold` | L4→L4 | 优化:常量 `if`/`case*`、纯 BIF 常量调用、`let` 常量/别名传播、去掉纯语句;与 inline 同在 fixpoint 组(`max_iter` 8) |
| normalize-anf | `clj2_p_anf` | L4→L5 | 所有实参位置变为 trivial(局部量/常量):Clojure 从左到右求值,Erlang 不规定实参顺序;`if`/`case*` 的测试与 invoke 的头/实参可放进 guard 与分派 |
| verify | `clj2_p_verify` | L5→L5 | 分析:每个 uid 只绑定一次、每个引用都在作用域内——生成的 Erlang 满足 erl_lint 的前提(§3.1);违反即编译器 bug |
| lower-labs | `clj2_p_labs` | L5→Labs | 最后一个懂 Clojure 的 pass:调用约定(normalize-arities:每 arity 一个 fun + `clj2_fn` 分派记录)、真值(`if` + guard)、`case*`(字面量模式,含 map 时改 `=:=` guard)、异常类别、命名空间模块布局 |
| emit | `clj2_p_emit` | Labs→absform | 纯序列化,每个 Labs 节点一条子句 |

框架侧(任务 006):语言 `extends`、非终结符包含(`Expr ::= t`,L5 的 `triv`、Labs 的 `eatom`)、自动穿通、每个 pass 边界整树校验、`trace`(可挂回调)、fixpoint 组、`diff_languages/2`。

与 [01](01-nanopass-pipeline.md) §5 的对应与偏离:

| 01 的 pass | 落点 |
|---|---|
| expand-destructuring | **归 `clojure.core` 的 `let`/`fn`/`loop` 宏**(JVM Clojure 的 `destructure` 同样在 core):特殊形式 `let*`/`fn*` 只接受符号,编译器不需要这一 pass。随 core 层(014/021)实现 |
| normalize-arities | lower-labs 的调用约定:每个 arity 一个 named fun,多 arity / 变参时由 `{clj2_fn, ...}` 记录与 `clj2_rt:invoke/2` 分派;单固定 arity 时就是 Erlang fun |
| lower-case | lower-labs:Erlang `case` 原生匹配字面量,不需要先降为判定树;含 map 的常量改用 `=:=` guard(map 模式会匹配超集) |
| emit-lower | lower-labs(L5 → Labs) |
| `receive*`、`erl-binary*`、互操作、`deftype*` | 未做,随运行时任务加入;新增特殊形式只需在 L0 增产生式,并在需要的 pass 里写子句,其余 pass 自动穿通 |

## 3. 平台取舍(目标约束 1 的落点)

| 主题 | 决定 | 理由 |
|---|---|---|
| 真值 | 只有 `nil` 与 `false` 为假(Clojure 语义) | 发射为 `case C of X when X =:= false; X =:= nil -> Else; _ -> Then end`,一个 case 不复制分支代码 |
| fn 值 | 单个定长 clause 的 fn **就是** Erlang `fun/N`;多 arity / 变参 fn 是 `{clj2_fn, #{N => fun/N}, nil \| {Min, fun/(Min+1)}}` | 常见情况与 Erlang 零成本互操作(`(lists/map (fn* [x] ...) xs)` 直接可用);变参 clause 的 rest 参数是列表,无剩余参数时为 `nil` |
| invoke | `case F of _ when is_function(F, N) -> F(Args); _ -> clj2_rt:invoke(F, Args) end` | 快路径是原生调用;慢路径集中在运行时,将来给 keyword/map/var 加 IFn 只改 `clj2_rt` |
| Erlang 调用 | 调用头为 `mod/fun` → `mod:fun(Args)`;值位置的 `mod/fun` 报错(需要 arity) | 对齐 clojerl 1.0 习惯 |
| throw | `(throw x)` → `erlang:error(x)` | Clojure 异常对应 Erlang `error` 类(带栈);Erlang `throw` 类是非局部返回,不混用 |
| catch 类 | `:error`/`:exit`/`:throw` 对应 Erlang 三类;`:default`(ClojureScript 写法)捕获全部类、原样绑定;`Exception`/`Throwable` 与其他 JVM 类按 `clj2_class` 的类模型选择,绑定时 Erlang 错误包成带类的 throwable(`clj2_rt:throwable/2`,2026-10-12) | 类层级用 jolt 的 JVM 类图模拟;Erlang 错误映射到最近的 JVM 类,登记 `:exceptions/erlang-classes` |
| JVM 互操作 | `(Class/m args)`、`Class/FIELD`、`(Class/.m obj args)`、`(.m obj args)`、`(. obj m args)`、`(.-f obj)`、`..`、`(new C args)`/`(C. args)` 编译为 `clj2_jvm` 的 `static`/`field`/`method`/`instance_field`/`new` 调用(2026-10-12) | 没有 JVM:常用的 java.lang/java.util/clojure.lang 成员(`Integer/parseInt`、`Math/*`、String 方法、异常构造器、`StringBuilder`、Var/Symbol/Keyword 成员……)在 BEAM 上按 JVM 结果实现;其余类登记 `:host/jvm-classes` |
| 命名空间 | 一个 NS 一个模块,var 是模块函数,不做名称改编;同 NS 引用编译为本地调用(on_load 期间远程自调用会 `undef`) | 细节见 [03](03-runtime-model.md) §2.1a、[02](02-beam-backend.md) §3.1/§3.4 |
| 宏 | 展开在驱动、parse 只拿能力;同文件宏靠编译期段模块;`defmacro` 暂为内核形式 | §4.1 |
| `'x` | reader 产出 `(quote x)`;`#'x` 产出 var 形式 | 修复 reader 原先两者都读成 `{var, [], x}` 的 bug |
| letfn 互递归 | group fun 而非 lambda lifting | 成员保持原生闭包捕获,成员间尾调用保持;不生成模块级函数,与 REPL 模块替换无交互([01](01-nanopass-pipeline.md) §7 风险 3 消除)。代价:每次成员引用分配一个闭包——之后由可选优化 pass 处理 |

### 3.1 absform 的 lint 约束如何满足

`compile:forms` 会跑 `erl_lint`,它禁止重绑定、跨 case/try 臂导出变量("unsafe")等源码级规则。不变式:**每个 uid 在编译单元内只绑定一次,emit 的临时变量全新,因此没有 Erlang 变量被重绑定、遮蔽或在 Clojure 作用域之外使用**。旧 stage0 在 try、`or`、实参内语句顺序、letfn 自由变量上的崩溃全部源于违反这一点,其探针已改写为 Clojure 回归测试(`clj2_compiler_tests:probe_test_/0`)。

## 4. 自举的变化

- 编译器是 Erlang,**不需要种子、不需要不动点门控**:[04](04-bootstrap-and-conformance.md) §1-§4 与任务 011/012/013 作废。
- 宏:Clojure 宏由 Clojure 写,机制已落地(§4.1)。
- core 的冷启动(clojerl2-014,已落地):00-kernel 层只用特殊形式、内核形式 `defmacro` 与 Erlang 调用,由 Erlang 编译器直接编译;`clj2_core:boot/0,1` 按 `core/boot-order.edn` 把各层文件依次编进同一个 `clojure.core` 模块(依赖必须在前,层的 `:allowed-ns` 由编译器的 `allowed_ns` 选项执行)。其他命名空间自动 refer `clojure.core`(支持 `:refer-clojure :exclude`),自己的定义优先;syntax-quote 把 core 符号限定为 `clojure.core/x`。清单见 [04](04-bootstrap-and-conformance.md) §6.1。

### 4.1 宏系统(已落地)

- **展开是驱动的效果,parse 只拿到能力**:驱动把 `expand(Sym, FormData, EnvData) -> {ok, Data} | none` 放进 parse 的 pass 状态。parse 遇到"头是符号、不是特殊形式、不是局部量"的列表就交给它;局部量遮蔽宏,与 Clojure 一致。parse 本身仍是"输入 + 能力"的函数(01 §4)。
- **宏的输入输出是值**:实参经 `clj2_form:to_data/1` 去掉位置包装、转成 D8 运行时值;宏返回的值直接再 parse,其节点继承宏调用处的位置。`&form` 是整个调用形式,`&env` 是以局部量名为键的 map。
- **同文件宏(form-at-a-time)**:命名空间是一个模块,但宏必须在模块存在之前就能运行。驱动逐个顶层形式解析;每遇到一个 `defmacro`,就把自上一个 `defmacro` 以来的形式编译成编译期段模块 `'<ns>$ctN'` 并加载(这些形式的顶层副作用会在编译期执行,与 JVM Clojure "编译即加载"一致)。后续段里对前面 var 的引用直接调用前面段的模块(var info 带 `module`)。编译结束(含失败)时段模块全部删除;最终的命名空间模块由全部已展开的形式一次编译而成。
- **`defmacro`**:目前是 parse 识别的内核形式,展开为 `(def ^:macro name (fn* name ([&form &env params...] body...) ...))`,支持 doc、attr-map、多 arity 与变参。不能用 Clojure 宏写它的原因:symbol 是 atom,带不了元数据,宏产出的 `(def ^:macro ...)` 会丢掉 `:macro`。等 symbol 元数据有了方案,`defmacro` 再挪进 `clojure.core`。产生 `defmacro` 的宏(定义宏的宏)可用。
- **syntax-quote 在 parse 展开**(Clojure 在 reader 里做,需要当前 NS):符号按 特殊形式不动 / 别名展开 / refer 归其 NS / 其余归当前 NS 限定;`x#` 换成 `x__auto__行_列`,同一个 syntax-quote 内相同,且构建确定;`~`/`~@` 编译成 `clj2_coll:concat/1` 等运行时调用,全常量部分在编译期直接算好。
- **集合**:`clj2_coll` 提供 D8 形状的 vector/map/set(vector 的数据暂为 tuple,trie 实现时替换,API 不变);集合字面量、quote 的集合、宏返回的集合因此都可以编译。
- **协议相关的内核形式**(clojerl2-016):`defprotocol`、`extend-type`、`extend-protocol`、`deftype`、`defrecord` 需要当前命名空间并产出额外模块,所以是 parse 的内核形式而不是宏。`extend-type` 产出顶层节点 `extend`(类型标识、协议、`method` 节点列表);驱动把每个 `extend` 编成独立的 impl 单元(`unit => impl`),`method` 是语言里的顶层节点(所有 pass 自动穿通,lower-labs 把它变成模块函数,不是 var)。`compile_ns_modules/2` 返回 impl 模块与命名空间模块;`load_ns` 先加载 impl。细节见 [03](03-runtime-model.md) §4.1a。
- 宏 var 在注册表里带 `macro => true`,别的命名空间经 `:refer`/别名/全限定名使用;把宏当值取用是编译错误。`clj2_compiler:macroexpand_1/2` 供调试。

## 5. 风险

1. **无编译期 pass 校验**:pass 写错时,错误在运行期校验才暴露。缓解:dev/测试默认 `check => true`,错误带路径;verify pass 另查作用域不变式;每个 pass 有独立测试。
2. **框架表达力**:`{list, K}`/`{opt, K}` + 非终结符包含已足以表达 L0-L5 与 Labs(含 guard 子语言);若将来需要 `{tuple, [K...]}` 字段种类再加,不需要改已有语言。
3. **group fun 的分配开销**:letfn 成员的每次互相引用分配一个闭包。若基准显示热点,加 lift-letfn 优化 pass(模块级函数 + 自由变量前置参数)。
4. **编译器改用 Clojure 写的可能**:语言表是数据,pass 是独立模块,将来想逐个改写成 Clojure 时可以逐 pass 迁移;本裁决不预设这一步。

## 6. 与其他文档的关系

- [00](00-overview.md):D2/D3 按本文修订。
- [01](01-nanopass-pipeline.md):语言链与 pass 清单保留为目标蓝图;§3 框架实现改为本文 §1。
- [02](02-beam-backend.md):D4 absform 不变;本文 §3 补充调用约定与 lint 不变式。
- [04](04-bootstrap-and-conformance.md):种子/不动点作废,分层 core 与语料门控保留。
- [07](07-scheme-layer.md):被本文取代,保留作历史记录。
- [08](08-nanopass-host-languages.md):宿主调研,其 Erlang 节为本文的可行性依据。
