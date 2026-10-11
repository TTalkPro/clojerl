# 07 Scheme 金属层(cleat 路线,复用 skeg RNRS 代码)

状态:**已作废**(2026-10-11 同日第二次裁决:不建 Scheme 层,编译器用 Erlang 写,见 [09](09-erlang-hosted-compiler.md))。以下原文保留作历史记录;据此写的 stage0(`sk_*`,后改名 `cljk_*`)已删除,其 absform 发射经验与 bug 教训并入 `clj2_p_emit` 及回归测试。

~~状态:已采纳(2026-10-11 用户裁决,推翻 [00](00-overview.md) 原 D2/D3 对 Scheme 层路线的否决)。~~
前置阅读:[00](00-overview.md) 决策表、[skeg/Skeg/designs/03-compiler.md](../../../skeg/Skeg/designs/03-compiler.md)(Lcore 文法)。

## 0. 裁决记录

用户拍板:**像 cleat 一样先建 Scheme 层,直接自己实现一个 Scheme,复用 `~/workspace/skeg` 的 RNRS Scheme 代码**,并带三项语言修正:

1. `guard` 保留;`call/cc` 不做全量续延,改名 **`call-with-return`**(逃逸续延)。
2. 无 `dynamic-wind`;用 Clojure 式 **`try`/`catch`/`finally`**,直接映射 Erlang `try`/`catch`/`after`。
3. 新增 **`nil` 常量**代表 null。

推翻原否决的依据:原 [00](00-overview.md) §46 否决 cleat 路线的核心论据是"R6RS 全量 call/cc 在 BEAM 无对应物"。**逃逸续延恰好对应 Erlang `throw`**(非局部退出),该障碍不成立。其余两项修正同样消除了 BEAM 上的高成本机制。

skeg 现状佐证(已核实):
- `Skeg/src/scheme/boot/**/*.sls` 中 `call/cc`、`dynamic-wind` 引用均为 **0**——skeg 自身已按同方向完成裁剪,boot 库可直接复用;
- `skeg/RESUME.md` 有 call-with-return/guard 双形态/try 宏的完整设计与 IronScheme 实测记录,照搬即可;
- skeg 已把 nanopass-framework-scheme 移植到非 Chez 宿主(`lib/nanopass/implementation-helpers.skeg.sls`,209 行),证明该框架可在任意足够强的 Scheme 上运行。

## 1. skeg 资产清单与移植矩阵

| skeg 组件 | 规模 | 处置 |
|---|---|---|
| `Skeg.Core`(C# 运行时原语) | 11,704 行 | **移植为 Erlang** `sk_*` 原语层(按 boot 库实际依赖取子集,§3) |
| `Skeg.Stage0`(C# stage0:Lcore reader/analyzer/interpreter) | 1,102 行 | **移植为 Erlang** stage0 编译器(§5;解释路径不需要,宿主原生代码无自举问题) |
| `Skeg/src/scheme/boot/*.sls`(含 `expander/` 6,081 行 syntax-case + 库系统) | 14,889 行 | **直接复用**,仅套用三项修正(§2) |
| `nanopass-framework-scheme` 子模块 + `implementation-helpers.skeg.sls` | 209 行适配层 | **直接复用**,另写 `implementation-helpers.clojerl2.sls` |
| `tests/r6rs/` 一致性套件 | 6,286 行 | **子集门控**(裁剪 dynamic-wind/重入续延用例) |
| `lib/skeg/std.*`(持久数据结构等) | 大 | **不移植**——编译器底座不需要,Clojure 层有自己的集合 |
| boot 镜像 fasl(`skeg.boot.dll` 等) | — | **不需要**——BEAM 的 `.beam` 文件就是持久化 boot 镜像(§5) |

## 2. 三项语言修正(落点)

### 2.1 call-with-return(逃逸续延)

- 语义:只能在被捕获帧内向上逃逸,不可重入、不可存储后跨帧调用——正是 Erlang `throw` 的形状。
- 实现:`(call-with-return proc)` → `catch  {cwr, Tag, Val} -> Val`;proc 内 `(return v)` → `throw {cwr, Tag, v}`。Tag 为每次调用生成的唯一引用,防止无关 throw 穿透误捕获。
- Lcore 落点:`$throw`/`catch` 已覆盖(skeg Stage0 已有 `$throw` special);`call-with-return` 作为**特殊原语**登记(skeg RESUME 验证过 PrimGen specials 合并清单的先例)。
- r6rs 套件中依赖重入续延的用例裁剪,登记 known-divergence。

### 2.2 guard / try / catch / finally

- `guard` 保留,双形态子句照搬 skeg RESUME 定稿:`(guard (var [#t body] …) )` 中 var 绑 Scheme 条件对象;新增形态 var 绑 Erlang 异常对象 `{erlang_exception, Class, Reason, Stack}`;未匹配子句重抛(`erlang:raise/3` 保类别)。
- `try` 宏:`(try e … (catch (var Type) body …) … (finally body …))` → 展开 to `$try/catch` + `$try/finally` specials → Erlang `try … catch … after …`。
  - "按类 catch"映射 Erlang 异常类别:`throw`/`error`/`exit` + scheme-exception;Type 匹配在 catch 体首部做谓词分派,不匹配重抛(skeg 的 `(try (clr-rethrow ex) 剩余子句)` 递归展开技巧同款)。
- `conditions.sls`(R6RS 条件系统)照常复用,条件对象是普通 record;`raise` 最外层 fallback 把 Scheme 条件包成 `{scheme_exception, Cond}` 抛出(skeg Errors.cs:93 同款)。

### 2.3 nil 常量

- `nil` 为自求值常量,与 `'()` **不同**(`(eq? nil '())` → `#f`)。存在意义:Clojure 桥(§6)与用户层 null 语义。
- BEAM 表示:原子 `nil`。
- Scheme 库代码不使用它;它只出现在(clojerl2 的)Lcore-Clojure 数据与桥接层。

## 3. BEAM 值表示(金属层自己的表示)

**注意:本节是 Scheme 金属层的表示,与 [03](03-runtime-model.md) D8(Clojure 运行时值表示)是两套东西。** 金属层只运行编译器本体(展开器/pass/宏展开/REPL 后端),用户 Clojure 程序的运行时仍是 D8 的 Erlang 项 + `clj2_rt`。

| Scheme 值 | BEAM 表示 | 备注 |
|---|---|---|
| pair / `'()` | `[Car \| Cdr]` / `[]` | 原生 cons |
| symbol | atom | gensym = 全局计数器后缀 atom(skeg 的 `--deterministic` 语义保留,构建可复现) |
| boolean | `true` / `false` | 原生 |
| exact 整数 | integer | BEAM 原生 bignum,无位数问题 |
| flonum | float | 原生 |
| ratnum / complex | `{ratio,N,D}` / `{complex,R,I}` | R6RS 数值塔;**expander 是否依赖待实测**(M0.5 验证点),不依赖则延后到库层 |
| char | `{char, CP}` | |
| string | `{sstring, Size, Tab, Key}`(**可变**) | ets 行存 `{size, Map}`;`string-set!` 读改写一行。boot 中 10 处 |
| vector | `{vector, N, Tab, Key}`(**可变**) | 同上;boot 中 43 处(含 expander/core.sls:313) |
| bytevector | `{bvector, N, Tab, Key}`(**可变**) | boot 中 5 处 |
| hashtable / eq-hashtable | ets 表直用,`{hashtable, Tab}` 包装 | `hashtable-set!` 22 处;eq-hashtable 用 ets `set` + `=:=` 语义天然匹配 |
| box | 单行 ets(`{box, Tab, Key}`) | 26 处 |
| record | `{rec, Rtd, Field…}`;rtd/rcd 是普通 Scheme 数据 | `define-record-type` 语义在库层实现(skeg boot/records/) |
| procedure | fun/2(闭包) | case-lambda → 单 fun 按 arity 分派 |
| 多值 | `{values, [V…]}`;单值直接返回 | `call-with-values` 16 处(含 expander/core.sls)——必须支持 |
| parameter | **pdict**(`{param, Id}` key,值栈) | `parameterize` = pdict 栈推拉;34 处。动态绑定与进程字典天然同构 |
| condition / 异常 | `{scheme_exception, Cond}` / `{erlang_exception, Class, Reason, Stack}` | §2.2 |
| port / IO | 文件子集映射 `file:*`;字符串端口 = iodata accumulator | 展开器只需 `with-exception-handler`/格式化级 IO |

**set! 的三档编译策略**(stage0 捕获分析分流,2026-10-11 补):

1. **未被闭包捕获的词法 `set!`** → 编译成 BEAM 变量重绑定(Elixir rebind 方案:每次 `set!` 生成新变量 `x@1`/`x@2`…),零开销。BEAM SSA 原生支持,emitter 直接产出 abstract forms。
2. **被闭包捕获的词法 `set!`** → 装箱:绑定替换为 cell 句柄,读写走原语;cell 落 pdict(金属层 v1 声明单进程,~30ns)。改名法在此**语义错误**——状态须跨激活存活,激活内任何新变量都做不到(Elixir 同因造出 Agent/:ets);gensym 计数器/缓存类代码全依赖此语义。
3. **数据结构与全局槽**(vector/string/bytevector/hashtable/`set!` 全局名)→ ets 行 / pdict `{skglobal, Sym}`,见上表。

捕获分析是 stage0 analyzer 作用域分析的副产品(027);装箱只发生在第 2 档,占少数。

**可变单元的裁决**:全部走 ets(规则单一,eq? 别名语义靠稳定 Key 天然正确)。编译期工具对 50-100ns 的单元开销不敏感;热点实测后再把单进程场景降级到 pdict,**M0.5 不做优化**。ets 不 GC → REPL 长会话会积累垃圾单元,提供 `(sk-gc-legacy)` 复位钩子,文档化。

## 4. Lcore-Erlang(对 skeg Lcore 的裁剪与扩展)

以 skeg `boot/expander/internal.sls` 的 rewrite 输出 + `Skeg.Stage0/Analyzer.cs` 为蓝本:

```
e ::= x | (quote d) | (if e e e) | (if e e) | (begin e …) | (set! x e)
    | (case-lambda [fmls body] …) | (letrec ((x e) …) body) | (letrec* …)
    | (library-letrec* name ((x loc e) …) body)      ; 库系统用,保留
    | (annotated-call ann . X)                        ; 只取源位置(调试信息)
    | (erl-call Mod Fun Arity Args)                   ; 替代 clr-* :调用任意 Erlang 函数
    | (erl-make-tuple e …) | (erl-tuple-ref e i) | (erl-tuple-size e)
    | (e e …)                                         ; 应用
specials(原语形态):($throw e) ($try/catch (e) (Class e) …)
                  ($try/finally e1 e2) ($and? e …) ($or? e …)
```

- 删除:`clr-*` 全部、`ffi-*`/`pinvoke-*`、`async-*`/`await`(CLR 专属)、`typed-*`/`annotated-case-lambda` 的类型通道(fixnum 装箱优化,后续作为纯性能工作再加)。
- 新增:`$try/catch`(§2.2);`erl-*` 内部形式(桥与运行时 FFI 出口)。
- 符号三分类不变:词法变量 / 原语表 / 全局值槽(全局槽 = pdict `{skglobal, Sym}` 或模块属性,展开器自身用得极少,REPL 用)。

## 5. stage0 与自举梯子

skeg 的 stage0 同时有解释与编译路径(C# 编译器自身也要自举)。**我们的 stage0 是 Erlang 写的,直接就是编译器,无需解释路径**:

```
stage0_escript / sk_stage0.erl:
  Lcore 文本 --reader--> 数据 --analyzer(词法层)--> Node --emit--> Erlang abstract forms
           --compile:forms/2(+debug_info)--> .beam
```

自举梯子(替代 skeg 的 seed → boot fasl 两遍流程;`.beam` 即持久镜像):

1. **T1**:stage0 能编译自测试的 Lcore 手写样本(quote/if/lambda/case-lambda/letrec/set!/$throw/$try-*)。
2. **T2**:原语层(§3)就位后,stage0 依序编译 boot 依赖最少的文件:`boot-seed.core` 等价物 → `internal.sls` → `core.sls`(expander 核心)→ `builders/library-manager/main`(skeg `seed-buildscript.sps` 的顺序照搬)。
3. **T3**:expander 上线后,其余 boot 库(conditions/records/enums/hashtables/io/…)**全部经 expander 编译**——这一步开始验证 syntax-case 全量语义。
4. **T4**:nanopass 上线(§7),编译器库随发行打包。
5. **T5**:r6rs 子集套件全绿 → M0.5 验收门(§8)。

构建确定性:skeg 的 `--deterministic` gensym 语义保留(同一输入产出逐字节一致的 .beam,供不动点比对)。

## 6. 与 clojerl2(Clojure 层)的桥

```
Clojure 源码
  → clj2_reader.erl(已完成,293 测试)          [Erlang 侧]
  → Lcore-Clojure 包装器 loc 形式
  → sk_bridge:to_scheme/1                        [边界:BEAM 项恒等,仅位置/nil/keyword 约定转换]
  → Clojure 宏展开器(Clojure 写,跑在金属层上)
  → 展开后的 Lcore
  → nanopass pass 链(Scheme,定义 L0-L3 语言)   [Scheme 侧]
  → 末级 pass 发射 Erlang abstract forms(仍是 Scheme 数据)
  → sk_bridge:to_erlang/1 → compile:forms/2      [边界]
  → .beam
```

- 两侧都是 BEAM 项,桥是**约定**而非拷贝:keyword `':a'` atom、`nil` 常量、位置包装器归一为 `annotated-call` 兼容形式。
- REPL/eval:运行期需要 reader(FFI 调 Erlang reader)+ expander + 编译器都在场——**接受 cleat 的双运行时成本**,编译器随发行。纯库部署(已编译 .beam)不含金属层,零开销。
- Clojure 层自举:D2 原方案"clojerl 1.0 充当 stage0"**废除**。新梯子: Scheme 写的最小 Clojure 展开器(special forms,无用户宏)→ clojure.core 用 Clojure 写、金属层编译 → 展开器自举。clojerl 1.0 降级为 core.clj 移植的行为参考。

## 7. nanopass 上线

- 复用 `nanopass-framework-scheme` 子模块(skeg 固定提交 `c14d3924`,MIT)。
- 新写 `implementation-helpers.clojerl2.sls`:以 skeg 的 209 行适配层为模板,落点:
  - `format/printf/pretty-print` → 原语层 io 子集;
  - `gensym/regensym` → 原语层;
  - `define-nanopass-record` 的宿主 record(skeg iron-034 的"记录类型定义一次"优化直接继承);
  - `eq-hashtable-*` → ets 原语;
  - `syntax->source-information` 系列 → 桥的位置包装器。
- [01](01-nanopass-pipeline.md) 的 L0-L3 语言定义与 pass 链**不变**,只是宿主从"Clojure 内自实现"换成"标准 nanopass 宏"。

## 8. 验收(M0.5 门)

1. T5:r6rs 子集套件(裁剪 dynamic-wind/重入续延/call/cc 重入用例)全绿;
2. `(guard …)` 双形态、`call-with-return` 逃逸与误穿透防护、`try/catch/finally` 与 Erlang 异常类别互通,各有单测;
3. `nil` 与 `'()` 区分的单测;
4. 确定性构建:同一 boot 源两次编译产出一致的 .beam 集合;
5. nanopass 冒烟:define-language/define-pass/pass 归一/trace 各一例跑通。

## 9. 风险登记

1. **expander 的可变性暗依赖**:43 处 vector-set!/10 处 string-set! 已确认,但 ets 化后别名与遍历次序语义需在 T3 用例中压实;`sstring` 的 Unicode 处理(char 是 CP、string 是 Map)在 `unicode.sls` 移植时重点验证。
2. **数值塔裁剪**:ratnum/complex 若 expander 不用则延后,登记分歧;若用了,T3 前补 `{ratio,N,D}` 归一化原语。
3. **ets 不 GC**:长 REPL 会话内存增长 → 复位钩子 + 文档;编译批处理场景(最常见)无此问题。
4. **多进程展开**:pdict parameter 与全局槽在多进程下语义破碎 → v1 声明金属层单进程(REPL 单会话),多进程 eval 作为后续工作。
5. **skeg 代码许可**:skeg LICENSE 与 nanopass MIT 均允许派生,入库时保留版权头,登记来源提交号。

## 10. 与其他文档的关系

- [00](00-overview.md) D2/D3 已按本文件修订(2026-10-11);[04](04-bootstrap-and-conformance.md) §2 的 clojerl 1.0 种子模型作废,自举梯子以本文件 §5 为准。
- [03](03-runtime-model.md) 不变——D8 值表示、协议分派(S2)、pdict delay 全部仍是 **Clojure 运行时**的决策,与金属层正交;M0 三个 spike 的结论继续有效。
- [01](01-nanopass-pipeline.md) 不变(pass 链),宿主变为本文件 §7。
- 原 `06-scheme-on-erts.md`(记录"为何不先建 Scheme 层")保留原文并在文首加注:其结论被本文件以"逃逸续延修正"为前提推翻。
