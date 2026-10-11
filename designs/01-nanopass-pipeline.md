# 01 nanopass 管线:语言链、pass 清单与框架实现(D3/D5/D6)

状态:设计提案。细化 [00](00-overview.md) 的 D3(nanopass 框架 Clojure 重实现)、D5(编译器纯函数)、D6(尾调用/闭包红利):给出从 reader 输出(Lcore)到 absform 对齐 IR(Labs)的形式化语言链、完整 pass 清单及其输入输出语言对,以及在 Clojure 内实现 nanopass 框架的最小 API 形态。

> 结论先行:**走完整 nanopass,不走 jolt 的 "nanopass-lite"**。每条 pass 一对形式化语言(define-language + spec 校验),pass 边界即语法契约;样板成本由 `extends` 继承与自动生成的穿通子句吸收。BEAM 原生特性让管线比 Chez/cleat 短一截:无 closure conversion、无 convert-assignments、无 TCO 分析。宏展开是驱动层的效果边界,pass 本身全部纯函数(D5)。

## 1. 语言链总览

```
Lcore ─parse─▶ L0 ─resolve-symbols─▶ L1 ─expand-destructuring─▶ L2a
      ─normalize-arities─▶ L2 ─validate-recur─▶ L2 ─lower-loop─▶ L3
      ─normalize-anf─▶ L4 ─lower-case─▶ L5 ─optimize*(fixpoint, mode-gated)─▶ L5
      ─verify─▶ L5 ─emit-lower─▶ Labs ─▶ [02 号文 emitter]
```

`validate-recur`/`verify` 是分析 pass(只报错不改树),其余为变换 pass。`*` 表示 dev/release 门控(§5.9)。

### 1.1 Lcore:reader↔编译器的唯一契约

Lcore 不是 define-language 定义的 IR,而是**Clojure 数据本身**:reader(Erlang 写)产出的形式——list/vector/map/set/symbol/keyword/字面量,附元数据 `{:line :column}`。任何合法 Clojure form 都是合法 Lcore。契约内容只有两条:(a) 数据结构种类封闭;(b) 源位置经 metadata 可达,供下游 ANNO 生成([02](02-beam-backend.md) §4)。

### 1.2 L0:parse 之后的显式 AST

特殊形式全部落成 `:op` 节点,宏已展开:

```clojure
(define-language L0
  (terminals
    (symbol (s))          ;; 未解析符号
    (literal (c))         ;; 数/串/keyword/nil/bool
    (meta (m)))           ;; 源位置等
  (Expr (e body)
    c
    (quote c)
    (var s)               ;; (var x)
    (if e0 e1 e2)
    (do body ... e)
    (let* ([s e] ...) body ... e)
    (letfn* ([s f] ...) body ... e)   ;; f 限 fn*
    (loop* ([s e] ...) body ... e)
    (recur e ...)
    (fn* s? (s* body ... e) ...)      ;; 多 arity 子句
    (def s e)
    (throw e)
    (try body ... e (catch s s e) ... (finally body ...)?)
    (case* e (c* e)* e)               ;; 常量分派
    (set! s e)                        ;; 仅 thread-bound var
    (. e s e ...)  (new s e ...)      ;; 互操作
    (deftype* ...) (defprotocol* ...) (extend-type* ...) (reify* ...)
    (receive* (c body ... e)* (after e body ... e)?)   ;; BEAM 扩展
    (erl-binary* ...)                                   ;; bit syntax 扩展
    (invoke e e ...)                  ;; 一般调用
    (primop s e ...)))                ;; erlang/+ 等原语
```

支持的特殊形式以 clojerl 1.0 + Clojure 为准(见 [00](00-overview.md) §1 的方言定位)。BEAM 扩展的取舍:**保留 `receive*` 与 `erl-binary*`**(消息与 bit syntax 是 BEAM 母语能力,无库级替身);`erl-list*`/`erl-alias*` 暂缓,列为开放问题(§7 风险 4)。

### 1.3 L1:符号已解析

```clojure
(define-language L1
  (extends L0)
  (Expr (e body)
    (- s)                       ;; 裸符号消失
    (+ (local uid))             ;; 局部变量:唯一 id
    (+ (varref ns name))        ;; Var 引用:全限定
    (- (let* ([s e] ...) ...))  ;; 绑定位 s 全部换成 uid
    (+ (let* ([uid e] ...) ...))))
```

`extends` 的意义:L1 只声明差异,其余产生式原样继承——这是完整 nanopass 样板可控的关键(§2)。

### 1.4 L2:解构与 arity 已规整

L2a(解构展开后):`let*`/`fn*` 绑定位只允许裸 `uid`,vector/map 模式全部消解为 `primop` 取件调用序列。L2(arity 规整后):`fn*` 只剩单子句;多 arity 变成 dispatcher 节点 `(fndispatch uid (f arity-n) ... (f arity-variadic)?)`,变参已变成定长参数 + list-collecting 前奏。

### 1.5 L3:loop 已降低

`loop*`/`recur` 消失。L3 新增 `(named-fun uid (uid* ...) body ...)`(自递归局部函数,对应 Erlang named fun)与 `(modcall m f e ...)`(模块私有函数调用,letfn* 互递归的落点,见 §4)。`validate-recur` 保证 L3 中不存在尾位置之外的递归残留。

### 1.6 L4:A 范式(ANF)

调用参数、`case*`/`receive*` 子句的模式与守卫语境中不再含任意表达式,复杂子表达式全部经 `let*` 提取为原子或平凡调用。动机是 Erlang 约束:case/receive 子句的**模式与守卫不能含任意调用**,守卫只认 guard BIF——把求值提升到子句之前是唯一保语义的映射。

### 1.7 L5 与 Labs

L5:`case*` 已降低为字面量等值判定的嵌套 `if`/`match` 树(Erlang case 直接吃字面量模式)。Labs:与 absform 一一对应的序列化前 IR(`(efun ...)`/`(ecase ...)`/`(ereceive ...)` 等),其文法与 emitter 归 [02](02-beam-backend.md) 所有,本文只划定边界:**emit-lower 之后不再有任何 Clojure 语义决策,只剩结构翻译**。

## 2. 为什么是完整 nanopass,而不是 jolt 的 nanopass-lite

jolt 用单一 IR + 注解键(pass 间靠约定而非语法)。我们拒绝这条路,理由:

1. **文法校验的 pass 边界能在语言定义层抓 bug**。L1 里出现裸 symbol、L3 里残留 `recur`、Labs 里出现 `letfn*`,都是 spec 校验立刻失败的结构错误,而非某个 pass 深处的神秘崩溃。clojerl 1.0 的分析器巨石([00](00-overview.md) §2.1)正是死于"任何节点可以出现在任何地方"。
2. **样板成本由 `extends` 继承吸收**。L0→L5 是渐进精化而非重写,每条后继语言只声明增删产生式(§1.3 的写法);nanopass-framework-scheme 的**自动穿通子句**(pass 未提及的产生式自动生成恒等遍历)在 Clojure 版同样实现。
3. **代价我们认账**:jolt 的 `map-ir-children` 共享遍历器在完整 nanopass 下退化为每语言一套遍历骨架(由 define-language 宏生成)。代码量上升,换来的是上面第 1 条——这是明确接受的权衡,不是疏忽。
4. **调试设施照搬 Scheme 框架**:`trace`/`echo`(pass 级 IR 打印)与 `diff-languages`(两语言产生式 diff)是排错主力,开发期默认挂在 pipeline 上。

## 3. D3:Clojure 内的 nanopass 框架

BEAM 上没有可 vendor 的宿主 Scheme(cleat 15 号文路线在此无对象),框架在 Clojure 内重实现。对应关系:

| nanopass-framework-scheme | clojerl2 (Clojure) |
|---|---|
| `define-language` + `extends` | `define-language` 宏,产生式编译为 spec;`:extends` 做产生式集合并/差 |
| terminals / nonterminals | 同上;terminal 即谓词(`symbol?`/`literal?`) |
| IR 记录 | **map 节点**:`{:op :if, :test .., :then .., :else .., :meta ..}` |
| `define-pass` + catamorphism | `define-pass` 宏:模式 → 模板,未匹配产生式自动生成穿通遍历 |
| `with-output-language` 模板 | 模板即输出语言的构造器语法,编译期按 Lout spec 校验键集合 |
| `trace` / `echo` / `diff-languages` | 同名函数,dev 模式可用 |

示意:

```clojure
(define-pass expand-destructuring : (L1) -> (L2a)
  (Binding : Binding -> [(uid ... ) (Expr ...)]     ;; 一对多:绑定消解为取件序列
    [(vec ,p* ...) ,e
     (let* ([,tmp ,e])                              ;; tmp 为框架生成的唯一 uid
       ,(mapcat (fn [p i] (Binding [p (primop nth ,tmp ,i)])) p* (range)))]))
```

`define-pass` 展开时做两件静态检查:(a) 模式键属于 Lin 的 `:op` 集;(b) 模板产出的节点键属于 Lout。加上运行期 spec 对输出整树校验,形成"编译期查模式、运行期查全树"的双层防线。

pass 组合器支持迭代组(jolt 的 fixpoint cluster 模式,用于内联/常量折叠互促):

```clojure
(defpipeline pipeline
  [parse resolve-symbols expand-destructuring normalize-arities
   validate-recur lower-loop lower-letfn normalize-anf lower-case
   (fixpoint [const-fold inline] {:mode :release, :max-iter 8})
   verify emit-lower])
```

## 4. D5:编译器是纯函数,宏展开是驱动层边界

纪律:**pass 链不读任何全局运行时状态**。NS/Var 解析结果打包为显式 `env` 参数穿线:`(resolve-symbols env form) -> [env' form']`——env 不可变,`def`/`in-ns` 的效应以返回值回传,由驱动层提交到运行时 NS 表([03](03-runtime-model.md) §2)。

对照 clojerl 1.0:分析器在 `analyze` 中途直接改写 ETS 里的 namespace,编译与运行时状态交织([00](00-overview.md) §2.5),导致编译必须跑在隔离子进程里。D5 下 pass 可任意并行、重放、缓存。

**与宏展开的共处**:宏是编译期求值,必然有执行效果,不可能纯。划界方式——宏展开在**驱动层**做,form-at-a-time:驱动读入一个顶层 form,宏展开之(此时允许 effectful eval,走 [02](02-beam-backend.md) §5 的单轨编译执行),展开结果进入纯 pass 链;`def`/`ns` 产生的 env 增量由 pass 返回、驱动提交。即:**效果是驱动与运行时之间的事,pass 与 pass 之间只有数据**。

## 5. pass 清单

| # | pass | Lin→Lout | 类别 | 一句话规格 |
|---|---|---|---|---|
| 1 | parse | Lcore→L0 | 变换 | 按特殊形式表把 Clojure 数据落成 `:op` 节点;未知 list 头归 `invoke`;宏已在驱动层展开 |
| 2 | resolve-symbols | L0→L1 | 变换 | 裸符号分类:局部绑定 → `uid`(词法作用域栈),其余按 env 查 NS/Var → `varref`;未解析即报错,不留 fake_fun 式补救([00](00-overview.md) §2.6) |
| 3 | expand-destructuring | L1→L2a | 变换 | 绑定位 vector/map 模式消解为 `primop` 取件 + `let*` 链;clojerl 1.0 把解构内联在分析器里,此处独立成 pass |
| 4 | normalize-arities | L2a→L2 | 变换 | 多 arity `fn*` → 每 arity 一个函数 + dispatcher;变参 → 定长参数 + 集list 前奏(无需 Chez 式 case-lambda 规范化,分派是显式节点) |
| 5 | validate-recur | L2→L2 | **分析** | 尾位置标注遍历:`recur` 必须出现在所在 `loop*`/`fn*` 的尾位置,且参数个数匹配;违规即带源位置的编译错误 |
| 6 | lower-loop | L2→L3 | 变换 | `loop*` → 命名局部递归 fun,`recur` → 自尾调用(§6) |
| 7 | lower-letfn | L2→L3 | 变换 | `letfn*` 按绑定图 SCC 分类降低(§6.3) |
| 8 | normalize-anf | L3→L4 | 变换 | ANF 化;重点服务 Erlang 约束:case/receive 子句模式与守卫中的复杂表达式提取到子句前的 `let*` |
| 9 | lower-case | L4→L5 | 变换 | `case*` 常量分派 → 字面量模式匹配树(直接对应 Erlang case) |
| 10 | const-fold / inline | L5→L5 | 变换 | 优化簇,fixpoint 迭代;**mode-gated**:dev 只跑 const-fold(jolt 模式),release 全开 |
| 11 | verify | L5→L5 | **分析** | Chez 式语言校验器:按 define-language spec 校验整树,dev 模式每条变换 pass 后也插一次(§2.4) |
| 12 | emit-lower | L5→Labs | 变换 | 语义决策终点,结构翻译起点;之后归 [02](02-beam-backend.md) |

## 6. D6:BEAM 红利与不需要的 pass

### 6.1 尾调用

BEAM 原生 proper tail calls([05](05-erts-target.md) §2.1):`recur` → 自尾调用,`loop*` → 局部递归函数。**不需要 TCO 分析 pass**——`validate-recur` 只是把 Clojure 的"recur 必须在尾位置"约束提前为编译错误,运行期零机制。

### 6.2 闭包

Erlang fun 原生捕获词法环境,`fn*` 直接映射为 fun。**免 closure-conversion pass**——Chez 管线中 `convert-closures` 这一整段在 clojerl2 无对应物。

### 6.3 letfn* 的诚实处置

Erlang 没有 fun 间的 mutual letrec:named fun 只支持**自递归**。设计:

- **自递归**(绑定图 SCC 为单点自环)→ named fun,零成本;
- **互递归**(SCC 含环)→ 提升为**模块私有的生成函数**,自由变量作为显式前导参数传入,`letfn*` 体内引用编译为对生成函数的 `modcall`。

注意这是针对 letfn 互递归这一个局点的定向降低,不是通用 closure conversion——自由变量显式传参的方案只在生成函数边界生效,普通 `fn*` 闭包仍走原生捕获。模块私有函数的全部权宜(命名、可见性、`on_load` 注册)属 [03](03-runtime-model.md) 模块模型范围。

### 6.4 与 Chez/cleat 管线的删减对照

| Chez/cleat pass | clojerl2 处置 | 理由 |
|---|---|---|
| convert-assignments | **无** | Clojure 局部变量不可变 |
| convert-closures | **无** | D6,fun 原生闭包 |
| case-lambda 规范化 | **无** | arity 分派是显式节点(normalize-arities) |
| TCO 分析/蹦床 | **无** | PTC 原生 |
| ANF/normalize | 有(normalize-anf) | Erlang 子句守卫约束 |
| verify(语言校验) | 有 | §2.4 |

## 7. 风险

1. **框架宏的工程量**:define-language/define-pass/自动穿通生成是元编程密集区,stage0 子集([04](04-bootstrap-and-conformance.md) §2)必须够大才能编译框架自身——这与 [00](00-overview.md) 风险 1 是同一冷启动问题的正面。缓解:M1 先写最小版(无 `extends`、手工穿通),框架自举后再补齐。
2. **ANF 与 Erlang 自身优化的重叠**:erlc 前半段也做子句提取,我们的 normalize-anf 可能与之重复劳动;保留它的理由是守卫约束必须在语义层保证,不能赌 erlc 内部顺序。若基准证明冗余,降级为只对 case/receive 语境做定向提取。
3. **letfn* 提升的交互**:生成模块私有函数与增量编译/REPL 的模块替换语义([03](03-runtime-model.md) §2)有交互,需在 M4 实测。
4. **开放问题**:(a) `erl-list*`/`erl-alias*` 是否保留(§1.2);(b) optimize 簇的 release 内联启发式直接搬 jolt 参数是否适配 BEAM 调用成本,待基准;(c) `set!` 仅限 thread-bound var,若 [03](03-runtime-model.md) 的动态绑定方案调整,本 pass 的校验规则跟随。

## 8. 与其他文档的关系

- [05](05-erts-target.md):真尾调用契合点(§2.1)在此兑现为 D6 的管线删减;其"发射器只是序列化器"的判词由 Labs↔absform 边界继承。
- [06](06-scheme-on-erts.md):其 nanopass 管线设想在此按 Clojure 语义实例化;其"先自举 Scheme metalayer"路线被 D3 取代([00](00-overview.md) §8)。
- [00](00-overview.md):本文细化 D3(§3)、D5(§4)、D6(§6);语言链是 §5 架构图"L0→…→Labs"段的展开。
- [02](02-beam-backend.md):Labs 文法、absform 序列化、ANNO 源位置约定、单轨求值(D11)归其所有;本文只承诺 emit-lower 的输出契约。
- [03](03-runtime-model.md):值表示(D8)、Var/NS 模型(D7,本文 env 参数的运行时对岸)、letfn* 生成函数的模块安置。
- [04](04-bootstrap-and-conformance.md):框架自举对 stage0 子集大小的要求(§7 风险 1)、pass 级 corpus 门控([00](00-overview.md) D12)的挂接点是本文的 verify pass。
