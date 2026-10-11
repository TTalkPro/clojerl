# 03 clojerl2 运行时模型:值、Var/NS、协议、引用类型

状态:设计提案。方向:为 clojerl2([00](00-overview.md))定义运行时的完整模型——值表示(D8)、Var 与命名空间(D7)、协议(D9)、多方法与引用类型(D10)、动态绑定、惰性序列、字符串,以及运行时的实现语言分层。原则:**Clojure 值语义全不可变,天然契合 BEAM 不可变堆([05](05-erts-target.md) §2);凡契合不了的,诚实降级而非伪造**(jolt host-adapter 模式)。

> 结论先行:clojerl 1.0 的运行时教训可归纳为两条——**间接层太多**(Var 解引用 = 远程调用 `Module:Name__val()`、协议分派 = 每次 extend 重编译全模块、七张 ETS 表/模块),**补救机制太脏**(fake_fun 为前向引用打补丁)。clojerl2 的答案是:能直接链接的全部直接链接(NS = 模块、var = 模块函数、协议 = `Protocol__Type` impl 模块),必须间接的用统一表格化机制(ETS 注册表 + pdict 动态环境),做不到的诚实抛错(STM/ref)。唯二需要 spike 验证的性能点:协议 `apply` 分派([00](00-overview.md) §6 风险 2)与 lazy-seq 记忆化(§6 风险 4)。

## 1. 值表示(D8)

### 1.1 总表

| Clojure 类型 | BEAM 表示 | 备注 |
|---|---|---|
| nil / true / false | atom `nil`/`true`/`false` | 模式匹配零成本 |
| integer / bignum | Erlang integer | 任意精度原生 |
| float | Erlang float | NaN 相等性见 §1.3 |
| ratio | `{ratio, Num, Den}` | 打标元组 |
| symbol / keyword | atom | atom 表耗尽风险见 §1.2 |
| string | binary(UTF-8) | 见 §7 |
| char | integer(码点) | 与 JVM UTF-16 分歧,登记 known-divergences([00](00-overview.md) §6 风险 3) |
| list | Erlang list(`[]`/`[H|T]`) | 原生 |
| vector | `{vector, Meta, Trie}` | 32 路 trie 建在 tuple 上 |
| hashmap | `{map, Meta, Map}` | **包原生 Erlang map**,见 §1.3 |
| hashset | `{set, Meta, Map}` | 同上,value 固定 `nil` |
| record/deftype | `{Tag, Meta, Fields}` + 生成的访问器模块 | Tag = 类型名 atom;访问器模块沿用 clojerl 1.0 的"真 BEAM 模块 + `__new__` 构造器"模式 |
| lazy-seq / delay / atom / agent | 见 §5、§6 | 引用类型不进入本表的纯值部分 |

> 2026-10-11:`clj2_coll` 已按本表形状提供 vector/map/set 的构造(宏与集合字面量需要)。vector 的 Data 暂为 tuple,32 路 trie 落地时在模块内替换,形状 `{vector, Meta, Data}` 不变;Meta 无元数据时为 `nil`。

### 1.2 atom 表耗尽:keyword/symbol 的运行时创建

symbol/keyword 用 atom 表示,模式匹配与比较都是 O(1),但 **BEAM 的 atom 表有上限(默认 1M)且不 GC**。运行时用户输入可经 `keyword`/`symbol` 函数无限制造新 atom——这是真实的拒绝服务向量(clojerl 1.0 同样有此问题,未文档化)。

决策:**编译期已知的 keyword/symbol 字面量直接用 atom**(编译产物内嵌,不消耗运行时转换);**运行时 `keyword/1`、`symbol/1` 默认走 `binary_to_existing_atom`**——atom 不存在时回退到内部表示 `{kw_dyn, Bin}`,相等性判定与原语表照顾这一形态。提供 `*allow-dynamic-atoms*` 开关切到 `binary_to_atom`(REPL 便利场景,文档明示风险)。这是一个公开登记的分歧:dynamically-created keyword 的表示不统一,`pr-str` 等已适配,但对 keyword 的模式匹配需经原语层。

### 1.3 hashmap:包原生 Erlang map,不自建 HAMT

候选:(a) 在 tuple 上自建 HAMT(移植 Clojure 的 BitmapIndexedNode);(b) 包一层原生 Erlang map。选 **(b)**:OTP 的大 map 内部就是 HAMT,原生实现的持久化、内存共享与 GC 友好性都优于手写的 tuple 版;小 map 走 flatmap 还有额外红利。成本是必须包一层 `{map, Meta, Map}` 以携带 meta 槽与类型标签。

键相等性:Erlang map 的键用**精确项相等**(`=:=`),Clojure 用按类别的相等(`1` ≠ `1.0`)。两者基本一致;边缘情况(NaN 不与自身相等、`-0.0` vs `0.0` 在 `=:=` 下不等)登记进 known-divergences,不模拟。

### 1.4 类型标签:打标元组 `{Tag, Meta, Data}`,不沿用 clojerl 的 map+`?TYPE`

clojerl 1.0 把所有值装进 `#{?TYPE => 'user.Foo', ...}` map。否决理由:(1) map 查找标签比元组首元素模式匹配慢,而**协议分派的热路径就是按标签匹配**(§4);(2) meta 槽挤在数据 map 里,`with-meta` 要全量拷贝;(3) 打标元组在 absform 里就是字面元组节点,发射零开销([02](02-beam-backend.md))。vector/map/set/record 统一三槽布局 `{Tag, Meta, Data}`,无 meta 时 `Meta = nil`,构造与模式匹配各一条指令。

## 2. Var 与命名空间(D7)

### 2.1 模型:一个 NS = 一个 BEAM 模块,var = 模块函数

- **直接链接为默认**:编译期解析到的非动态、非 `^:redef` var,调用点直接生成 `NsMod:fn/N` 远程调用。BEAM 的远程调用经导出表跳转,无中间层——**废除 clojerl 1.0 的 `Module:Name__val()` 每次解引用一次远程调用**。
- **前向引用在 NS 编译粒度解决,废除 fake_fun**:D5 的显式环境([01](01-nanopass-pipeline.md) §4)让编译器在编译一个 NS 前拥有全 NS 的 var 声明清单(先跑 declare/resolve pass 收集全部 `def` 的符号与元数据),`defn` 体里引用后文的 var 照常编译为远程调用,加载时目标已存在。clojerl 1.0 需要 fake_fun + replace_calls 的原因(编译与求值双轨、逐 form 求值)在"一律编译执行、以 NS 为编译单元"([00](00-overview.md) D11)下不存在。
- **`^:dynamic` 与 `^:redef` var 走间接表**:值存中央间接表(§2.3),调用点编译为访问器 `NsMod:Name()`,访问器内 `clj2_var:deref(NsMod, Name)`(已落地,见 §2.1a)。REPL 重定义 = 重新编译 NS 模块(热代码两版本语义:旧代码继续跑旧版,新解析的调用点链到新版——文档化,与 Erlang 原生语义一致,不模拟 JVM 的"所有现存引用即刻见新值")。
- **NS 注册表**:一张 ETS 表(`named + read_concurrency`),key = NS 名 atom,value = 模块名 + var 清单;由一个 gen_server 持有,负责建/删 NS 与加载完成回调。保留 gen_server 只为串行化写,读不经它——对比 clojerl 1.0 每模块 7 张 ETS 表 + gen_server 代理所有访问,收敛为**一张表、写才过进程**。

### 2.1a 落地形态(2026-10-11,clojerl2-015)

| var 种类 | 判定(declare pass) | 模块里的形态 | 调用点 |
|---|---|---|---|
| fn | init 是 `fn*` 字面量,且无 `^:dynamic`/`^:redef` | 每个 clause 一个函数 `f/N`(变参 `f/(Min+1)`);fn 的自名与 `recur` 都编译为对这些函数的本地调用 | `(f a)` → `M:f(A)`(同 NS 为本地调用);作为值时为 `fun M:f/N`,多 arity 时为 `{clj2_fn, ...}` |
| const | init 是常量 | 访问器 `x/0` 直接返回常量(进 literal pool) | `M:x()` |
| cell | 其余 init(或无 init) | 访问器 `x/0` = `clj2_var:root(M, x)`;`__ns_init__` 里 `set_root` | `M:x()`;无 init 时读取即报 unbound |
| indirect | `^:dynamic` 或 `^:redef` | 访问器 = `clj2_var:deref/2`(dynamic,先查进程绑定栈)或 `root/2` | `M:x()` |

- 前向引用:declare pass 在 resolve 之前收集整个 NS 的 def 清单,`defn` 体里引用后文的 var 照常编译为直接调用。
- 其他 NS:由驱动在 resolve 之前经 `clj2_ns:info/1` 查一次,作为显式 scope 交给 pass(D5);未加载但在 code path 上的 NS 模块由 `code:ensure_loaded` 加载,其 on_load 自行注册。
- 已知局限:调用方按编译时看到的 var 种类/arity 直接链接;被调 NS 之后把 fn 改成值或改了 arity,旧调用方需重编译(与 AOT Clojure 同类问题)。arity 不匹配的直接调用是**编译错误**(JVM 在运行期抛 ArityException,登记分歧)。
- 表:NS 注册表 `clj2_ns`(protected,写经 gen_server)、var 根值表 `clj2_var`(public,`{Module, Name}` 为键)。gen_server 不链接调用者启动,因为首个注册者往往是短命的 on_load 进程。

### 2.2 REPL 重定义与 on_load

NS 模块带 `on_load` 函数,加载时向注册表报告 var 清单(jank 的 `jank_load_foo` + 注册表模式的 BEAM 映射,见 [00](00-overview.md) §3.5)。REPL 里 `def` 同一个 var:重编译模块 → `code:load_binary` → on_load 更新注册表。两步之间读到旧值是可接受的(REPL 单线程语义下根本观察不到)。

### 2.3 间接表:ETS,不用 persistent_term

| | persistent_term | ETS |
|---|---|---|
| 读 | 零拷贝、常数 | 一次查找(读拷贝小 term 可忽略) |
| 写 | **全表拷贝**,写一次 O(表大小) | O(1) |
| 适用 | 几乎不变的配置 | 会变的 |

REPL 是写密集场景(每次 `defn` 都写),persistent_term 的全表拷贝在 REPL 里随 var 数量线性恶化——选 **ETS**。生产镜像若确认无重定义,可在构建末期把间接表冻结进 persistent_term 作为优化(留作后续,非 v1)。

## 3. 动态绑定

沿用 [06](06-scheme-on-erts.md) §3 的 pdict 方案,按 Clojure 语义实例化:

- 每个 `^:dynamic` var 一个 pdict 键(如 `{clj_dyn, NsMod, Name}`),值为该 var 的**绑定栈**(list,push/pop)。
- `binding` 宏展开为:保存旧栈顶 → put 新栈 → `try body after` 恢复旧栈。`after` 保证 throw/error/exit 三类逃逸都正确解绑——[06](06-scheme-on-erts.md) 已论证 BEAM 的 `try/after` 就是 dynamic-wind 的诚实替身。
- 解引用动态 var = 读 pdict 栈顶;未绑定回退到间接表里的根绑定(§2.3)。
- **进程边界分歧,文档化**:BEAM 进程不共享 pdict,`binding` 的效果不跨 `future`/agent 动作自动传播。v1 提供显式 `bound-fn`(创建时快照 pdict 绑定帧,调用时重建);`future` 宏用 `bound-fn` 语义实现,与 Clojure JVM 一致。agent 的 action 同理。

## 4. 协议(D9)

### 4.1 分派:impl 模块 + 存在性缓存

```
分派形状(编译产物):
  case clj_rt_protocol:impl('Protocol', TypeTag) of
    {ok, ImplMod} -> apply(ImplMod, Method, [X | Args]);
    error         -> apply('Protocol__Default', Method, [X | Args])
  end
```

- `defprotocol` 生成**协议模块**(方法元数据、默认实现引用)与 `Protocol__Default` impl 模块;`extend-type`/`extend-protocol`/`deftype`/`defrecord` 只编译**新的** `Protocol__Type` impl 模块并 `code:load_binary`,**协议模块与其他 impl 模块一律不动**。
- 存在性缓存:`clj_rt_protocol:impl/2` 查 ETS(key = `{Protocol, TypeTag}`),未命中走 `code:ensure_loaded(ImplMod)` 探测并回填(含负缓存)。BEAM 的 `apply/3` 本身有模块/函数缓存,热路径 = 一次 ETS 读 + 一次 apply。
- `satisfies?` = 存在性探测,同走缓存。

### 4.1a 落地形态(2026-10-11,clojerl2-016)

- **运行时** `clj2_proto`:`dispatch(P, Method, This, Args)` = `impl(P, type_tag(This))`(否则 `impl(P, default)`)+ `apply`;缓存表 `clj2_proto`(ETS,`{{P, Tag}, {ok, Mod} | none}`),未命中经 `code:ensure_loaded` 探测 code path 上的 impl 模块,失败写负项(`insert_new`,不覆盖并发加载刚写入的正项)。
- **协议即 var**:`(defprotocol P ...)` 定义 var `P`(值是描述 `{:name ns.P :methods [...]}`)与每个方法的分派函数 var(普通 var 函数,内部调 `clj2_proto:dispatch`)。原设计的"协议模块"不需要:元数据在 var 里,协议所在命名空间模块在 extend 时同样不重编译。
- **impl 模块** `<ns.P>__<Tag>`:由 `extend-type`/`extend-protocol`/`deftype`/`defrecord` 的方法编译而来,每个方法 clause 一个导出函数;其 on_load 调 `clj2_proto:loaded/3` 写正项,**负缓存随之失效**(§9 未决问题 3 已关闭,有测试)。
- **类型 tag**(`clj2_proto:type_tag/1`):`nil boolean keyword symbol integer float string list vector map set fn ratio tuple pid reference port`,`default` 作兜底;deftype/defrecord 值 `{Tag, Meta, Fields}` 的 Tag 是带命名空间的类型名 `ns.T`。`extend-type` 的类型位置写这些 tag、`ns.T`/本 NS 的 `T`,或 JVM 风格别名 `Object String Long Integer Double Boolean Keyword Symbol`。
- **deftype**:Fields 为 tuple,构造函数 `->T`;**defrecord**:Fields 为 map(`clj2_coll` 的 get/assoc/count/keys/vals/= 视其为 map),构造函数 `->R` 与 `map->R`。方法体里字段名是局部量,同名参数遮蔽字段。var `T` 的值是类型 tag(供 `instance?`)。
- **已知限制**:没有 `reify`;协议方法不能变参(与 Clojure 一致);symbol 无元数据,`^:private` 之类丢失;命名空间加载期(on_load)内若经协议调到本 NS 的 impl 方法、而该方法又远程调用本 NS 的 var,会遇到 on_load 自调用限制;编译期段不含 `extend-type`(宏在展开期不能分派到同文件定义的 impl)。

### 4.2 对比与取舍

| 方案 | extend 成本 | 分派成本 | 否决/采纳理由 |
|---|---|---|---|
| clojerl 1.0:重写+重编译协议模块 | **O(已有类型数 × 方法数),O(n²) 累积** | 模块内 case,快 | 否决:类型一多编译期不可忍([00](00-overview.md) §2.4) |
| **impl 模块(采纳)** | O(本类型方法数) | ETS 读 + apply | extend 与分派解耦;开放扩展是 Clojure 对象模型的本质(jank 从封闭枚举迁移到开放行为位集的教训同向) |
| ETS 方法表(key=`{P,Type,M}`,value=fun/MFA) | O(本类型方法数) | ETS 读 fun + 调 fun | 备选:写放大在 extend 侧同样小,但 fun 存 ETS 跨进程读要拷贝闭包环境,且失去模块热升级;若基准证明 apply 太慢,退回此方案并接受闭包拷贝([00](00-overview.md) §6 风险 2) |

**Spike(M0)**:基准三组——直接远程调用、本方案的 ETS+apply、ETS fun 表——在 100 协议 × 50 类型规模下比分派吞吐。判定:本方案不低于直接调用的 1/3 即采纳。

注意 jank 的 defprotocol 尚未实现,其分派教训只支持"必须开放",不构成 AOT 策略依据([00](00-overview.md) §3.5)。

## 5. 多方法与引用类型(D10)

### 5.1 多方法:保留 clojerl 的分派模块模式

**保留 clojerl 1.0 的按多方法一个分派模块的模式**(`Ns.name__dispatch__`):`defmethod` 时重新生成分派模块并热加载——BEAM 两版本热替换保证旧代码的进行中调用不受影响,新调用走新表。改动仅在生成方式:clojerl 1.0 用 `cerl:abstract(Map)` 把调度 map 转成 Core Erlang,clojerl2 改为直出 **absform**([02](02-beam-backend.md)),与其他编译产物同一条发射路径,消除 cerl 依赖。dispatch fn 值 = `dispatch/1` 的 fun;偏好与祖先链(`derive`/`isa?`)存 ETS 表,`defmethod` 只改这张表 + 重发生派模块,不碰全局状态机。

### 5.2 引用类型:诚实降级总表

| 类型 | 实现 | 语义契合度 |
|---|---|---|
| atom | **ETS 行 + `ets:select_replace` CAS** | `swap!` = CAS 重试循环;`reset!` = 单写;`deref` = ETS 读。watch 列表随行存储,变更后异步通知 |
| agent | **专用进程**(gen_server 风格) | `send`/`send-off` 的顺序性 = 消息队列顺序,天然契合——这是 BEAM 比 JVM 更贴 Clojure 语义的少数点 |
| delay | thunk + 记忆单元(§5.3) | 记忆化需要可变性,见下 |
| ref / STM(dosync) | **v1 不做,raise 信息明确的错误** | BEAM 无多对象事务内存;伪造 STM 违背诚实降级原则(jolt:raise 而非假装) |
| promise / future | 进程 + 消息 | `deref` = `receive`,`deliver` = `send`;future 用 `bound-fn` 语义(§3) |

atom 的备选是"每 atom 一个小进程"——否决:Clojure 程序里 atom 数量大、读密集,每值一进程的内存与消息开销不值;CAS 重试在无争用时一轮成功,热点争用见 §10 风险 5。

### 5.3 不可变堆上的记忆化(delay 与 lazy-seq 共有问题)

BEAM 项不可变,"计算一次后缓存结果"必须借助外部可变单元。候选:

| 方案 | 跨进程共享 | 成本 | 结论 |
|---|---|---|---|
| pdict 记忆单元 | **否**——进程 B 拿到 delay 要重算 | 零 | **v1 默认**,分歧登记:同一 delay/lazy-seq 在不同进程各自 realize 一次;纯函数语义下结果相同,仅副作用型 thunk 可观察差异 |
| ETS 单元(每 delay 一行) | 是 | 每实现一次两行 ETS 操作 | 开关备选;副作用敏感场景可开 |
| 每单元一进程 | 是 | 每 delay 一个进程,过重 | 否决 |

v1 选 pdict + 文档化分歧,ETS 开关留位。**Spike(M0)**:量化 pdict 版与 ETS 版的 lazy-seq 吞吐差,决定开关默认值([00](00-overview.md) §6 风险 4)。

## 6. 惰性序列

> 2026-10-11 落地(clojerl2-019,`clj2_lazy`,基线见 `clojerl2/notes/lazy-seq.md`):
> - 值:`{lazy_seq, Meta, {Key, Thunk}}`(Key 是 `make_ref()`,记忆单元按它存取,不改写值本身——BEAM 项不可变);`delay` 同形 `{delay, Meta, {Key, Thunk}}`,`deref`/`@` 先支持 delay(atom 等随 018)。
> - **实现结果是 nil 或 cons 单元 `[First | Rest]`,Rest 可仍是惰性的**(Erlang 非正规列表),所以 `first`/`rest` 仍是 `hd`/`tl`,`map`/`filter` 链逐元素实现;`clj2_coll:seq/1` 只实现第一个元素,`to_list/1` 全部实现。
> - thunk 返回另一个 lazy-seq 时**迭代**实现(常量栈,对应 JVM `LazySeq.sval` 的循环),`(first (filter #(> % 1000000) (range)))` 不长栈。
> - ETS 开关版:claim 用 `ets:update_counter/4`(恰好一次),**抢占失败者等待赢家的值**(不再自己算),所以 ETS 版是"恰好一次";下文"最多算两次"的退化不再适用。
> - **记忆单元有上限**(`clj2_lazy:set_memo_limit/1`,默认 100000):超限清空,之后再走同一个 lazy-seq 会重新实现——长寿进程不会无限增长;登记为分歧 `:lazy-seq/bounded-memo`。
> - 宏返回值里的惰性部分在宏边界整棵实现成普通形式(`clj2_form:from_value/1`)。
> - eval 模块不再在返回后立即删除(其结果可能持有该模块的闭包/惰性序列),保留最近 100 个(02 §5)。

- `lazy-seq` = `{lazy_seq, Meta, ThunkOrCell}`:未实现时槽位是 fun,实现后按 §5.3 的机制改写为缓存的 seq。
- chunking:v1 不做 JVM 的 chunked-seq(buffered 32),逐元素实现——分歧登记;chunked-seq 是优化而非语义,后续可作为纯性能工作补回。
- 与进程调度交互:惰性链在 pdict 版下不跨进程,无"谁持有锁"问题(JVM 的 realizing 锁在 BEAM 无对应物);ETS 开关版用 `ets:update_counter/4` 占位计数做 realize-once(clojerl2-003 实测:同为恰好一次,比 `ets:select_replace` 便宜约 8 倍;OTP 28 的 select_replace 拒绝预编译 match spec 且 replacement 不能直接放元组值);并发重复实现退化为"最多算两次",对纯 thunk 无害。

## 7. 字符串与字符

- string = **binary(UTF-8)**:内存紧凑、与 Erlang IO 协议(iolist)零转换、与 clojerl 1.0 先例一致。
- **下标 O(n) 分歧**:Clojure JVM 的 `nth`/`charAt` 是 UTF-16 码元 O(1),UTF-8 binary 按码点取下标 O(n)。登记 known-divergences;原语层提供按码点的 `char_at`,文档劝用 seq/reduce 遍历。char = integer 码点(非 UTF-16 码元),surrogate pair 在 clojerl2 中就是单码点——同样登记。
- 拼接:`iolist` 内部累积、最后 `iolist_to_binary`,避免 O(n²) 拷贝;`str` 多参直接产 iolist。

## 8. 运行时的实现语言分层

```
第 0 层  Erlang 写的原语层(clj_rt_*):
         值构造/谓词、Var/NS 注册表、协议分派、引用类型、
         pdict 动态绑定原语、字符串原语、IO(走 Erlang io 协议)
第 1 层  primitives 表(数据,不是代码):
         Clojure core 函数名 → 第 0 层 Erlang MFA 的映射,
         编译期由 emit pass 查表内联为直接远程调用
         (cleat primitives.edn 的对应物)
第 2 层  Clojure 写的 core 库(clojure/core/NN-*.cljc 分层,
         见 [04](04-bootstrap-and-conformance.md) §3):
         所有可在第 0/1 层之上定义的部分(seq 库、高阶函数、宏)
```

> 2026-10-11(clojerl2-014):第 0 层落地为 `clj2_coll`(集合形状的唯一知情者,含集合原语)与 `clj2_rt`(符号/关键字/字符串/apply/invoke)、`clj2_var`、`clj2_ns`。第 1 层 primitives 表暂不需要:kernel 函数直接以 `erlang/+` 等调用 Erlang,用户代码对 core 函数的调用经直接链接成为 `call_ext`;把 `(+ a b)` 内联为 BIF 是后续优化(拟用 Clojure 的 `:inline` 元数据,而不是另建表)。

划分判据:**只有"必须接触 BEAM 机制"的进第 0 层**(ETS、pdict、apply、进程、binary);凡是能用第 0 层原语表达的,一律上移到 Clojure——Erlang 代码量最小化就是自举风险最小化([00](00-overview.md) §6 风险 1)。分层打破"编译器依赖它编译的库"循环的细节归 [04](04-bootstrap-and-conformance.md)。

## 9. 未决问题(open,不阻塞 v1 路线)

1. `kw_dyn` 形态与 atom 形态并存时,`name`/`namespace`/`pr-str` 之外的谓词面是否完全收敛——待 primitives 表定稿时复核。
2. 间接表冻结进 persistent_term 的生产优化(§2.3)的触发条件与构建管线位置。
3. ~~`satisfies?` 负缓存的失效~~(2026-10-11 关闭):impl 模块的 on_load 写正项覆盖负项,`clj2_proto_tests` 的 "negative cache then extend" 用例验证(§4.1a)。

## 10. 风险(按优先级)

1. **协议分派性能**(spike,M0,2026-10-11 已量化:0.61× 直接调用,采纳,见 spike-002):ETS 读 + apply 对直接调用的相对开销;不达标则退回 ETS 方法表并接受闭包拷贝与热升级损失(§4.2)。
2. **lazy-seq/delay 的 pdict 记忆化**:跨进程重实现的语义分歧是否被语料库接受,ETS 开关的性能代价未知([00](00-overview.md) §6 风险 4)。
3. **atom 表耗尽**:运行时 `keyword`/`symbol` 在默认 `binary_to_existing_atom` 下安全,但 `*allow-dynamic-atoms*` 开关打开了滥用面;另外 clojerl2 自身每 NS/var 一个模块函数,大型应用的模块数 + 函数量同样吃 atom 表与模块表,需容量测算。
4. **REPL 写密集下间接表的选择**:ETS 已按写密集选定,但若 REPL 会话持有海量动态 var 重定义,注册表 gen_server 的串行化写是否成为瓶颈,未基准。
5. **热点 atom 的 CAS 争用**:`ets:select_replace` 在单行上的高争用会退化为重试风暴;缓解 = 文档劝用 agent(进程串行化)处理热写,不自动降级。

## 11. 与其他文档的关系

- [00](00-overview.md):本文是 D7/D8/D9/D10 的详述;结论先行 blockquote 的两条运行时教训归纳自其 §2。
- [05](05-erts-target.md):值表示沿用其契合点清单(atom/列表/任意精度整数);其 §3.1 可变性与身份风险经"引用类型装箱 + 诚实降级"(§5)落实,惰性记忆化是其遗留 spike 的缩小版。
- [06](06-scheme-on-erts.md):pdict 动态环境(其 §3)继承为动态绑定(§3);诚实降级哲学继承为 STM/ref 的 raise(§5);其 runtime=gen_server 收敛为 NS 注册表单 gen_server(§2.1)。
- [01](01-nanopass-pipeline.md):D5 显式环境使 fake_fun 可废除(§2.1);primitives 表由 emit pass 消费(§8)。
- [02](02-beam-backend.md):值表示的打标元组即 Labs 的字面元组节点(§1.4);多方法分派模块与协议 impl 模块均由其 absform 路径发射(§4、§5)。
- [04](04-bootstrap-and-conformance.md):core 分层与种子边界(§8);全部分歧(NaN/码点下标/跨进程绑定与记忆化/STM)进 known-divergences 门控。
