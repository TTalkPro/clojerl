# 00 Clojerl 2.0:基于 nanopass 的 Clojure on ERTS(总体设计)

状态:设计提案。方向:不修补 clojerl 1.0 的分析器/发射器双巨石,而是另起炉灶——以 nanopass 为编译器骨架、以 Erlang abstract forms 为唯一目标格式的全新实现;编译器(nanopass 框架与 pass 链)用 Erlang 写(2026-10-11 修订,见 [09](09-erlang-hosted-compiler.md))。工作代号:**clojerl2**。

> 结论先行:**可行,且条件比 clojerl 1.0 立项时更好**。三个外部事实改变了权衡:(1) Gleam v1.19 与 Elixir 证明 Erlang abstract forms 是文档化、跨版本稳定的编译目标,直接喂 `compile:forms/2`,跳过 erlc 前半段;(2) 05 号文判定的最大风险(可变对与 `eq?` 身份模拟)**对 Clojure 不成立**——Clojure 值语义全不可变,天然契合 BEAM 的不可变堆;(3) jolt 与 cleat 已经把"nanopass 管线 + 分层 core + 语料库一致性测试"这条路完整走过一遍,本项目是把它们的方法论搬到 ERTS(编译器宿主取 Erlang 而非自寄宿,见 D2)。

## 1. 定位:第三代,不是补丁

| | clojerl 1.0 | 本项目(clojerl2) |
|---|---|---|
| 编译器语言 | Erlang | Erlang(2026-10-11 定,见 [09](09-erlang-hosted-compiler.md));区别不在宿主,而在管线形态 |
| 管线形态 | reader → 3080 行分析器巨石 → 2262 行发射器巨石 | nanopass:形式化语言链 + 小 pass 组合([01](01-nanopass-pipeline.md)) |
| 目标格式 | Core Erlang(cerl 树) | **Erlang abstract forms**([02](02-beam-backend.md)) |
| 顶层求值 | core_eval(839 行 erl_eval fork)+ 编译双轨 | 一律编译执行,废除解释器 |
| 协议分派 | extend 时重写并重编译协议模块,O(n²) | impl 模块 + 模块存在性缓存([03](03-runtime-model.md) §4) |
| 与 Clojure JVM 关系 | 尽量克隆 | 方言,诚实登记分歧(jolt 模式) |

定位类比:Clojure 之于 Common Lisp,jolt 之于 Clojure JVM——借语法与精神,不背兼容包袱。分歧全部进 `known-divergences.edn` 门控注册表([04](04-bootstrap-and-conformance.md) §5)。

## 2. clojerl 1.0 的教训(重写的证据基础)

对 clojerl 1.0 代码库的实证盘点(src/erl,行数为证):

1. **分析器 3080 行巨石**:宏展开、内联、解构、协议方法、BEAM 扩展特殊形式全部交织在 ~60 个互递归函数里,无 pass 边界。
2. **发射器 2262 行巨石**:手工穿线状态;`deftype` 在发射中途编译并加载模块;`fn` 无条件包 letrec(无递归检测)。
3. **双求值器**:编译走 `compile:noenv_forms(from_core)`,顶层 form 却走 core_eval(839 行 Core Erlang 解释器)——整套子系统需要与 Core Erlang 语义保持同步。
4. **协议重编译**:每次 extend-type 重写协议模块的全部分派函数并重编译,类型越多越慢。
5. **运行时状态弥漫**:命名空间/Var 在 ETS gen_server,每模块 7 张 ETS 表,内联缓存与当前文件进进程字典,编译要在受监控子进程里隔离运行。
6. **Var 解引用 = 远程调用**(`Module:Name__val()`),未定义 var 靠 fake_fun + replace_calls 补救。

教训归纳:**把编译期关注点(宏展开、分析、优化、发射)和运行期状态(Var/NS/协议表)混在同一套过程式代码里,是所有痛的根**。nanopass 纪律(形式化 IR + 显式 pass 边界 + 编译器纯函数化)正是对症的药——cleat D5"编译器是纯函数"直接沿用。

## 3. 外部参照的事实清单

### 3.1 Gleam v1.19(目标格式决策的直接依据)

Gleam 从生成 Erlang 源码改为生成 **abstract forms**,经 external term format 二进制编码直接喂编译器:编译显著提速、崩溃栈行号精确到 Gleam 源、代码质量提升。其**不直出 BEAM 字节码**的论证:字节码指令集随 OTP 演进,跟进成本不可持续,且无法复现 erlc 数十年积累的优化。Elixir 同样走 abstract forms。

### 3.2 absform 与 beam_makeops(02 号文的官方依据)

- absform 是 OTP 官方文档化的解析树表示:`{call,ANNO,...}`/`{clause,ANNO,...}` 等元组,ANNO 经 `erl_anno` 携带精确位置;`compile:forms/1,2` 是公开入口。
- beam_makeops 揭示 BEAM 指令三层结构:external generic(genop.tab,跨版本稳定契约)、internal generic(loader 变换规则)、specific(实际执行)。**若未来确需绕过 erlc,接口层是 generic 指令 + `beam_asm`,而不是 specific 指令**——但 Gleam 的成本效益论证同样适用于我们:v1 不碰。

### 3.3 cleat(设计词汇与决策框架来源)

cleat 是"Clojure on CLR",已完成自举不动点。可沿用:D 编号决策体例、L0-L3 宿主无关 IR + 目标分裂、**targets.edn 机器描述表**(我们加 `:beam` 表项)、primitives 表即数据、编译器纯函数化(D5)、core 分层加载、语料库门控。注意(2026-10-11 两次修订):上午一度改走 cleat 路线(自研 Scheme 金属层 + 复用 skeg RNRS 代码,[07](07-scheme-layer.md));同日再次裁决**不建 Scheme 层**,nanopass 框架与 pass 链用 Erlang 写([09](09-erlang-hosted-compiler.md))。cleat 的"stage0 保持朴素、语义决策归 pass"这一分工仍然沿用。

### 3.4 jolt(最接近的姊妹项目:Clojure → Scheme → Chez)

可直接照搬的模式:(1) checked-in seed + 字节级不动点自举;(2) tiered `clojure/core/NN-*.clj` 打破"编译器依赖它编译的库"循环;(3) host-adapter 契约文档 + 诚实降级;(4) corpus.edn(JVM 作 oracle)+ known-divergences 门控注册表;(5) mode-gated pass 管线(dev 模式只跑常量折叠)。差异:jolt 是 "nanopass-lite"(单一 IR + 注解键),本项目走**完整 nanopass**(每条 pass 一对形式化语言),理由见 [01](01-nanopass-pipeline.md) §2。

### 3.5 jank(Clojure on LLVM 的 AOT 经验)

可引用:模块加载函数模式(`jank_load_foo` + 注册表 → 我们映射为模块 `on_load` + NS 注册)、`compilation_target::{module, eval}` 双模发射、开放对象模型的分派教训(jank 从封闭枚举迁移到行为位集——BEAM 上对应"协议分派必须开放可扩展"的结论)。注意 jank 的 defprotocol/deftype 尚未实现,不可引为协议 AOT 策略依据。

### 3.6 IronScheme 设计文档(05/10/11/12/13)与本库 14/15

本库 designs/05、06 源自 IronScheme/designs/14、15（重排编号，其中对 IronScheme 其他文档的引用已改为明文路径）；其引用的 05-bootstrap/10-async/11-portability/12-strings/13-clr-exceptions 在 `~/workspace/IronScheme/designs/`。05 号文的 ERTS 契合点分析（真尾调用、异常、atom、进程模型）对本项目**全部成立且更强**——Scheme 的可变对/`eq?` 风险在 Clojure 不存在。06 号文的 runtime=gen_server 模型、三项删减思路、pdict 动态环境方案，在 [03](03-runtime-model.md) 中按 Clojure 语义重新取舍。

## 4. 关键决策总表

| 编号 | 决策 | 要点 | 详述 |
|---|---|---|---|
| D1 | 方言定位 | 新方言,非 clojerl 1.0 升级、非 Clojure JVM 克隆;分歧诚实登记 | §1 |
| D2 | 编译器语言 | **Erlang**(2026-10-11 第二次修订):reader、nanopass 框架、全部 pass、发射器都是 Erlang 模块;不建 Scheme 金属层([07](07-scheme-layer.md) 作废),不需要种子与不动点门控。Clojure 宏仍用 Clojure 写,由驱动层编译加载后调用。clojerl 1.0 降级为 core.clj 移植参考 | [09](09-erlang-hosted-compiler.md) §0/§4 |
| D3 | nanopass 实现 | **Erlang 内自实现**(`clj2_np` + `clj2_lang`):语言即数据(带 `extends`)、节点为 absform 形状的元组 `{Op, Anno, ...}`、框架自动穿通、每个 pass 边界运行期按输出语言整树校验;pass 即模块,渐进加 pass 即渐进优化 | [09](09-erlang-hosted-compiler.md) §1 |
| D4 | 目标格式 | **Erlang abstract forms** + `compile:forms/2`;不产文本源码、不产 Core Erlang、v1 不碰 BEAM 汇编码 | [02](02-beam-backend.md) |
| D5 | 编译器纯函数 | pass 链不读全局运行时状态;NS/Var 解析结果作为显式环境参数穿线(cleat D5 沿用) | [01](01-nanopass-pipeline.md) §4 |
| D6 | 尾调用与闭包红利 | recur → 本地尾调用(BEAM PTC 原生);fn → Erlang fun 原生闭包,**免 closure conversion pass** | [01](01-nanopass-pipeline.md) §3 |
| D7 | Var/NS 模型 | 每 NS 一个 BEAM 模块;直接链接默认开;动态绑定走进程字典;废除 `__val` 远程调用与 fake_fun | [03](03-runtime-model.md) §2-3 |
| D8 | 值表示 | symbol/keyword = atom;string = binary;vector/map/set = 打标持久结构;record/deftype = 打标 map + 生成的访问器模块 | [03](03-runtime-model.md) §1 |
| D9 | 协议 | impl 模块(`Protocol__Type`)+ 模块存在性缓存分派;extend 只编译新 impl 模块,不重编译协议 | [03](03-runtime-model.md) §4 |
| D10 | 引用类型诚实降级 | atom = ETS + CAS;agent = 进程;STM/ref v1 不做;延迟(lazy-seq)= thunk + pdict 缓存 | [03](03-runtime-model.md) §5 |
| D11 | 求值单轨 | REPL 顶层 form 一律 `compile:forms` + `code:load_binary`;不设解释器 | [02](02-beam-backend.md) §5 |
| D12 | 一致性测试 | 移植 jolt corpus.edn(JVM Clojure 作 oracle)+ known-divergences.edn 门控;CI 拒绝未登记分歧 | [04](04-bootstrap-and-conformance.md) §5 |

## 5. 总体架构

```
reader(Erlang 写,产出 Clojure 数据)
   │
   ▼
Lcore(固定输入文法,reader 输出即合法 Lcore)         ← 编译器与读者的唯一契约
   │
   ▼
nanopass 管线(Erlang 写,pass 链 L0→…→Labs)
   │  每步:形式化语言对 (Lin → Lout),pass 边界按语言整树校验,未写的 op 自动穿通
   ▼
Labs(抽象格式层 IR,与 absform 一一对应)
   │
   ▼
emitter(纯序列化器:Labs → absform 项 → compile:forms/2 → beam)
   │
   ▼
运行时(Erlang 写:值/协议/Var/NS/引用类型 + core 分层 .cljc)
```

三条边界都是数据契约:reader↔编译器是 Lcore 文法,编译器↔emitter 是 Labs 文法,编译产物↔运行时是 absform + 运行时约定(构造函数名、协议表布局)。任何一侧可独立替换——这正是 cleat 14 号文"三层架构"在 ERTS 的实例化。

## 6. 风险总览(按优先级)

1. **core 的冷启动**(原"编译器自寄宿的冷启动",D2 改为 Erlang 后风险缩小):编译器不再自寄宿,只剩 clojure.core 自身的分层加载——00-kernel 层只用 special form,由 Erlang 编译器直接编译([09](09-erlang-hosted-compiler.md) §4,[04](04-bootstrap-and-conformance.md) §6)。
2. **协议分派性能**:impl 模块方案的 `apply` 缓存命中率需基准验证;若不够,退回 ETS 方法表并接受 extend 写放大([03](03-runtime-model.md) §4 备选)。
3. **字符串语义**:binary(UTF-8)下标 O(n) 与 Clojure JVM 的 UTF-16 语义分歧,进 known-divergences 并文档化([03](03-runtime-model.md) §1)。
4. **惰性序列在 BEAM 的成本**:thunk + 缓存的方案与进程调度的交互需 spike(唯一保留自 05 号文的 spike,但范围小得多)。
5. **absform 表达力边界**:fun 子句守卫、`receive`、`try/catch/after` 组合在 absform 的表达已验证(文档完备);剩余风险是编译器诊断信息回溯到 Clojure 源位置的机制(ANNO 约定,见 [02](02-beam-backend.md) §4)。

与 05 号文风险清单的对照:可变对/`eq?` 身份(Clojure 无此语义,**消除**);psyntax 审计(不用 psyntax,**消除**);pdict GC 特性(保留,限动态绑定小数据)。

## 7. 落地顺序

1. **M0 spike**:值表示 + 协议 impl 模块分派基准 + lazy-seq thunk(风险 2/4)。
2. **M1**:reader(Erlang,已完成)+ Erlang 内 nanopass 框架(已完成,[09](09-erlang-hosted-compiler.md) §1)。~~M0.5 Scheme 金属层~~ 作废。
3. **M2**:pass 链打通到 absform → beam → 执行。已完成第一段(parse/resolve/validate-recur/lower-loop/lower-letfn/emit,[09](09-erlang-hosted-compiler.md) §2);剩余 def/NS、解构、ANF、case*、互操作。
4. **M3**:core 分层加载(00-kernel 起,宏 form-at-a-time)。编译器是 Erlang,**没有种子与不动点门控**。
5. **M4**:协议/多方法/引用类型/惰性 + core 全层 + corpus 门控接入 CI。
6. **M5**:REPL、编译缓存、rebar3 插件、`clojerl2` CLI。

## 8. 与其他文档的关系

- [05](05-erts-target.md):ERTS 契合点分析沿用;其"生成 Erlang 源码是唯一正道"的结论被 Gleam/Elixir 实践更新为 abstract forms(D4);其最大风险(可变对/`eq?`)对本项目不适用(§6)。
- [06](06-scheme-on-erts.md):runtime=进程、pdict 动态环境、诚实降级的设计哲学继承到 [03](03-runtime-model.md);其"先自举 Scheme metalayer"路线曾在 [07](07-scheme-layer.md) 短暂重新采纳,同日被 [09](09-erlang-hosted-compiler.md) 否决。
- [07](07-scheme-layer.md):Scheme 金属层方案,**已作废**,保留作历史记录。
- [08](08-nanopass-host-languages.md):nanopass 宿主语言调研,D3 的可行性依据。
- [09](09-erlang-hosted-compiler.md):编译器宿主改为 Erlang 的裁决与框架设计(D2/D3)。
- [01](01-nanopass-pipeline.md):pass 链与语言定义(D2/D3/D5/D6)。
- [02](02-beam-backend.md):目标格式与发射器(D4/D11)。
- [03](03-runtime-model.md):运行时模型(D7/D8/D9/D10)。
- [04](04-bootstrap-and-conformance.md):自举与一致性(D2/D12)。
