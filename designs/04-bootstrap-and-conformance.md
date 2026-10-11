# 04 自举策略与一致性测试(D2 / D12)

状态:设计提案。覆盖 [00](00-overview.md) §4 的 D2(编译器自寄宿 + 入库种子)与 D12(语料库门控一致性)。自举方法照搬 jolt 的 checked-in seed + 字节级不动点模式;一致性照搬 jolt 的 corpus.edn + known-divergences 门控。本文的核心决策是 **stage0 的来源**(§2)。

> **(2026-10-11)本节 stage0 决策已修订**:clojerl 1.0 种子模型废除,stage0 = 自研 Scheme 金属层([07](07-scheme-layer.md) §5),Clojure 层自举梯子见 [07](07-scheme-layer.md) §6。以下原文保留作历史记录。

> 结论先行:**stage0 采用 clojerl 1.0 作为种子宿主(方案 b),Erlang 直译编译器(方案 a)作为回退**。理由:clojerl 1.0 已经是一个能编译 defrecord/deftype/协议/多值函数到 beam 的完整实现,用它一次性生成首枚种子,省掉一个一次性 Erlang 编译器的全部工作量;代价是种子血统耦合于 clojerl 1.0 的方言怪癖——用"编译器源码子集纪律"(§2.4)+ 不动点门控(§4)把耦合封死在种子生成这一步,之后 clojerl 1.0 永久退场。种子提交入库,fresh clone 即可构建;`make selfhost` 门控字节级不动点,`make remint` 收敛重铸种子。

## 1. 自举链总览

```
stage0  clojerl 1.0(现成宿主,仅用于首枚种子的生成;之后冻结、退场)
  │     编译:编译器源码(Clojure,§2.4 子集)+ core kernel 层
  ▼
seed    入库的 beam 文件集 + manifest(§3)——fresh clone 的直接起点
  │     用 seed 编译器编译编译器源码
  ▼
stage2  seed 编译的 clojerl2 编译器
  │     用 stage2 再编译同样的源码
  ▼
stage3  stage2 编译的 clojerl2 编译器 ──► 不动点:normalize(stage2) == normalize(stage3)(§4)
```

与 [06](06-scheme-on-erts.md) §2 的三段结构同构,但两点更新:(1) 06 号文的"Erlang stage0 解释器跑文本种子"被 D2 取代——解释器路线要求编译器源码可解释执行,约束比"可被子集编译"更苛刻;(2) 目标格式从 Core Erlang 换成 abstract forms(D4,见 [02](02-beam-backend.md)),发射器是纯序列化器,降低了子集编译器(回退方案 a)的成本。

## 2. stage0 来源:本文的核心决策

### 2.1 三个候选方案

| | (a) Erlang 直译子集编译器 | (b) clojerl 1.0 作宿主 | (c) 手写种子 |
|---|---|---|---|
| 内容 | 用 Erlang 写一个一次性编译器,覆盖编译器源码所需的最小 Clojure 子集,产 absform → beam;生成种子后冻结 | 用现成的 clojerl 1.0 编译 clojerl2 编译器源码(限制在 1.0 支持的子集内),产 beam 种子 | 手工构造编译器的 beam/absform 并入库 |
| 前期成本 | 高(一个真实的编译器前端:reader 复用、分析、发射,估 2–4 周) | 低(clojerl 1.0 就在本库,`make` 即可) | 不可行(编译器数千行,手工不现实) |
| 血统风险 | 零(完全独立) | 种子语义继承 clojerl 1.0 的怪癖(分析器巨石的边界行为) | 极高(无源可溯) |
| 子集约束力 | 子集由自己定义,边界清晰 | 子集 = clojerl 1.0 已支持的特性集,边界由对方历史决定 | — |
| 退场后影响 | 无 | 无(种子生成后 1.0 仅作考古参考) | — |

### 2.2 推荐:方案 (b),(a) 作回退

clojerl 1.0 已支持本方案所需的全部特性:`defrecord`/`deftype`、协议、多值函数、宏、多方法。clojerl2 的编译器源码把自己限制在这个交集内,(b) 就是纯复用。不动点门控(§4)保证:无论种子血统如何,只要 stage2==stage3,自编译链从此自洽,1.0 的怪癖无法穿透种子之外——这正是 jolt"种子可信任因为它能再生自己"的论证。

回退触发条件:若 clojerl 1.0 的方言分歧(如其 core_eval 双轨语义、协议重编译时序)导致编译器源码即使遵守子集纪律也无法正确编译,则启动方案 (a)。(a) 的范围已被 D4 收窄:只需产 absform,不碰 Core Erlang,不写优化。

### 2.3 与 doc 00 的表述关系

doc 00 §4 D2 写的是"首枚种子由 Erlang stage0(直译式子集编译器)生成"。本文将"Erlang stage0"细化为:**stage0 的逻辑角色是"一次性子集宿主"**,其首选实现是 clojerl 1.0(其本身即是 Erlang 实现的 Clojure 子集编译器),自写 Erlang 直译器为等价回退。D2 的实质(seed 入库、自我再生)不变;实现选择记录于此,doc 00 相应措辞以本节为准(见 §8 开放问题 O1)。

### 2.4 编译器源码子集纪律(书面约定)

编译器与 nanopass 框架源码(§6 的 00-kernel 消费者)只准使用下列特性——这些是 clojerl 1.0 与任何合理 stage0 的交集:

| 允许 | 禁止 |
|---|---|
| `defn`(含多值)、`def`、`let`/`loop`/`recur`、`if`/`when`/`cond`/`case` | 惰性序列高阶组合子的非常规用法(`lazy-seq` 允许,无限流作为编译器内部数据结构禁止) |
| `defrecord`/`deftype`、协议(`defprotocol`/`extend-type`)、多方法 | `defprotocol` 的运行时重 extend(编译期一次性 extend 允许) |
| 宏(`defmacro` + syntax-quote)、`resolve`/`ns` 显式操作 | `eval`、运行时 `load-string`、`*read-eval*` |
| 持久数据结构全量、瞬态(`transient!`/`persistent!`) | `volatile!`/`atom` 的并发依赖语义(单线程使用允许) |
| 宿主互操作(Erlang 调用,编译期可枚举的固定集合) | Java 互操作形式、clojerl 1.0 独有的 BEAM 扩展特殊形式 |
| `binding` 动态绑定 | `alter-var-root`、 Var 根绑定热替换 |

执行机制:仓库内置 `script/check-subset`(静态 lint,白名单特殊形式 + 黑名单符号线查),CI 对每个提交运行。子集边界变更必须连同本文档一起修改。

## 3. 种子格式与入库

种子 = **编译后的 beam 文件集 + 一份 manifest**,提交在 `bootstrap/seed/` 下。

- **布局**:`bootstrap/seed/beam/*.beam`(编译器各模块 + 00-kernel 的运行时部分)+ `bootstrap/seed/manifest.edn`。
- **manifest 内容**(示意):

```clojure
{:clojerl2-version "0.1.0"
 :stage0 {:kind :clojerl-1 :version "0.7.1"}   ; 首枚种子之后改为 {:kind :self}
 :sources {"src/clj2/compiler/passes.cljc" "sha256:…"} ; 全部输入源文件的哈希
 :core-layers ["00-kernel"]                     ; 种子内含哪些 core 层(§6)
 :built-at "git:abcdef12"                        ; 提交号,不含墙钟时间(§4 确定性)}
```

- **fresh clone 加载路径**:rebar3 pre-compile hook 检测 `bootstrap/seed/beam`,加入 code path;`make` 第一步用 seed 编译器重建全部源码。无 seed 则报错并提示 `make remint`(回退路径,需 clojerl 1.0 环境)。
- **不提交**:任何含绝对路径/时间戳的中间产物;beam 内嵌的 `debug_info` 保留(开发体验)但不动点比较时剥离(§4)。

## 4. 不动点验证与确定性

### 4.1 定义

`stage2 = compile(seed, src)`,`stage3 = compile(stage2, src)`。通过判据:**normalize(stage2) 与 normalize(stage3) 逐文件字节相等**。

### 4.2 确定性措施与 normalization

`compile:forms/2` 的确定性已知边界:同一 OTP 版本 + 同一编译选项下输出确定;风险点在三处——

1. **时间戳/构建信息**:不写入 absform;manifest 的 `:built-at` 用 git 提交号而非墙钟(见 §3)。
2. **匿名 fun 命名**:Erlang 编译器为 fun 生成 `-module-fun/Arity-` 风格的内部名,计数器顺序由 forms 顺序决定——我们的 emitter 必须**确定性遍历**(map 按键序遍历,禁止依赖 `maps:to_list` 的未定义序;编译期计数器全部显式穿线,符合 D5 纯函数约束)。
3. **OTP 版本间漂移**:不动点只在同一 OTP 版本内断言;manifest 记录 OTP 版本,CI 矩阵固定版本。

normalization(比较前处理):剥离 `debug_info` chunk、剥离 `Docs` chunk、按 chunk 名排序后比较。**判定标准保留保守口径**:若剥离 debug_info 后仍不等,视为不动点破坏,不做进一步豁免。

### 4.3 命令与 CI 门控

- `make selfhost`:构建 stage2、stage3,执行 4.2 的规范化比较。CI 必跑,失败即红。
- `make remint`:迭代编译至收敛(jolt 模式:反复编译直到输出稳定),将新 seed 覆盖 `bootstrap/seed/`,并校验新 seed 通过 `make selfhost`。**陷阱(jolt 已记录)**:改了编译器或 core 而忘了 remint,seed 静默过期,后续构建用的还是旧编译器——改动看似无效果。缓解:(1) CI 加 `make remint --check`:重算 manifest 中的源哈希,与入库 manifest 不一致即失败;(2) 编译器启动时打印自身 seed 的 git 提交号。

## 5. 一致性测试(D12)

### 5.1 架构

```
corpus/*.edn ──► runner ──► clojerl2 编译并求值 ──► 实际值 ─┐
   (宿主无关:表达式 + 期望值)                                ├─ EDN 规范化后比较 ─► pass/fail
JVM Clojure(oracle)求值同一表达式 ──► 期望值 ──────────────┘
   ▲
known-divergences.edn:已登记分歧的豁免注册表(门控)
```

- **语料格式**(移植 jolt corpus.edn):每条目 `{:expr "…" :expected "…" :tags [:core :seq]}`;`expected` 由 JVM Clojure 求值生成(oracle 模式 `make corpus-regen`),入库后作为静态期望,日常 CI 不依赖 JVM。
- **规范化比较**:两边结果都经 EDN 读回再比较——浮点打印格式、map 键序、集合序的差异在 EDN 层消解;不可 EDN 化的值(fun、atom)按打印表示比较,并在语料 schema 中标注。
- **known-divergences.edn 门控**(jolt `make certify` 模式):runner 产出的每个 failure 若不在注册表中 → CI 失败;注册表中的条目若意外通过 → 同样失败(防止分歧静默修复后注册表腐烂)。每条登记必须带原因与 doc 00 §1 的方言定位一致(如 UTF-8 binary 下标,见 [03](03-runtime-model.md) §1)。
- **次级来源**:clojure-test-suite(社区一致性套件,按标签筛选后转 corpus 条目)与 clojerl 1.0 自有测试套件(回归参考,语义分歧处按 known-divergences 登记,不盲目继承)。移植工作量估计见 §7 风险 3。

### 5.2 分层接入

corpus 按 §6 的 core 分层打标签;CI 先跑 kernel 层语料(M3 起),全量门控自 M4 起强制。

## 6. 分层 core 与宏自举

### 6.1 分层(jolt 的 NN-*.clj 模式)

| 层 | 内容 | 在种子里? |
|---|---|---|
| `00-kernel` | **仅编译器自身使用的结构函数**:序列基本操作、map/set 操作、symbol/keyword 构造、`defn`/`defmacro` 展开所需的最小宏集 | 是(编译进 seed beam) |
| `01-core` | clojure.core 其余函数(高阶、transducer、字符串) | 否,seed 启动后由 seed 编译器编译加载 |
| `02-protocols` | 核心协议及内建类型的 extend | 否 |
| `03-print` | `pr`/`print-method`/`prn` | 否 |
| `04-repl` | REPL 支持函数 | 否 |

`00-kernel` 打破"编译器依赖它要编译的库"的循环:编译器源码(§2.4 子集)只准依赖 kernel;kernel 只准依赖 Erlang 运行时原语([03](03-runtime-model.md))。加载顺序由 `core/boot-order.edn` 显式声明(每层的文件列表与依赖层),不做隐式文件序。

### 6.2 宏自举:form-at-a-time 驱动

`defmacro` 需要编译期执行 Clojure 代码,而宏体本身要先被编译——这要求驱动器严格 form-at-a-time:每读一个顶层 form,立即(宏展开 → 编译 → 加载)后再读下一个,使 `defmacro` 建立的宏对后续 form 立即可见(驱动器与 macroexpand 的边界见 [01](01-nanopass-pipeline.md))。推论:**stage0 宿主也必须满足同一边界**——clojerl 1.0 的顶层求值已是逐 form(clje 编译器架构),满足;回退方案 (a) 的 Erlang 直译器若采用批量编译则必须改为逐 form,否则 kernel 的宏集无法自展。

## 7. 里程碑验收标准(对应 [00](00-overview.md) §7)

| 里程碑 | 客观验收判据 |
|---|---|
| M0 spike | 值表示 + 协议 impl 模块分派基准报告入库;lazy-seq thunk 微基准相比 clojerl 1.0 同级代码不快于 ×0.5 以内即通过(阈值在报告中固化) |
| M1 | reader(Erlang)通过 Lcore 文法 golden 测试集;nanopass 框架的 define-language/define-pass 最小版可定义并运行一个玩具 pass 对 |
| M2 | `(fn [x] (+ x 1))` 级程序 e2e:reader → pass 链 → absform → `compile:forms` → beam → ERTS 执行返回 2(对输入 1);全程 CI 可复现 |
| M3 | stage0 产出 seed 并入库;`make selfhost` 绿(stage2==stage3,§4);kernel 标签的 corpus 条目全绿 |
| M4 | 协议/多方法/引用类型/惰性齐备;core 全层(§6.1)加载;corpus 全量 + known-divergences 门控进 CI,无未登记分歧 |
| M5 | `clojerl2` CLI 与 REPL 冒烟脚本通过;rebar3 插件可对示例项目完成 compile/repl;编译缓存命中下二次构建时间 < 首次的 20% |

## 8. 开放问题

- **O1**:doc 00 §4 D2 的"Erlang stage0"措辞与本文 §2.3 的细化(clojerl 1.0 作为首选实现)需在 doc 00 下次修订时对齐。
- **O2**:00-kernel 的确切函数清单需实测划定(doc 00 §6 风险 1 已预留);划定结果回填 §6.1。
- **O3**:corpus 的浮点/比值表示在 BEAM(无 JVM ratio 原生类型)下的规范化规则,待 [03](03-runtime-model.md) §1 数值塔定稿后补充。

## 9. 风险

1. **stage0 子集边界蠕变**:编译器源码在开发中静默超出 §2.4 子集,直到下次 remint 才爆雷。缓解:CI 每提交跑 `script/check-subset`(§2.4)+ `make remint --check`(§4.3),双门;子集变更必须与本文同 PR。
2. **不动点因 beam 非确定性抖动**:fun 内部命名或 map 遍历序引入的 stage2≠stage3 假阳性。缓解:§4.2 的确定性遍历纪律 + normalization;出现抖动先修 emitter 的确定性,禁止放宽比较口径。
3. **语料移植工作量**:jolt corpus + clojure-test-suite 筛选转换估计 1–2 人周;BEAM 特有分歧(数值塔、字符串下标)的逐条登记会随 M4 推进持续增长。缓解:按 §6 分层标签分阶段接入,kernel 层先行,避免 M4 大爆炸。
4. **种子过期(jolt remint 陷阱)**:改了编译器/core 忘了 remint,seed 静默不生效。缓解:§4.3 的 remint --check CI 门 + 编译器启动打印 seed 提交号,使"我在跑哪个编译器"永远可见。
5. **clojerl 1.0 血统污染**:方案 (b) 的种子语义继承 1.0 怪癖。缓解:不动点门控保证 stage2 之后 1.0 无影响;若 M3 不动点反复失败且归因于 1.0 的语义怪癖,触发 §2.2 的回退 (a)。

## 10. 与其他文档的关系

- [00](00-overview.md):本文实现其 D2(§1–4、§6)与 D12(§5);里程碑编号沿用其 §7;风险 1 是其 §6 风险 1 的落地细化。
- [06](06-scheme-on-erts.md):三段自举骨架的来源;其"Erlang stage0 解释器"被本文 §2 的"一次性子集宿主"取代(§1)。
- [05](05-erts-target.md):其 §5 的不动点检验思路(自编译 == 交叉编译产物)在本文 §4 具体化为规范化字节比较。
- [01](01-nanopass-pipeline.md):驱动器 form-at-a-time 与 macroexpand 边界(本文 §6.2 引用);D5 纯函数约束是 §4.2 确定性穿线的前提。
- [02](02-beam-backend.md):absform 目标格式(D4)是回退方案 (a) 成本收窄的原因(§1);其编译选项约定是 §4.2 确定性的载体。
- [03](03-runtime-model.md):00-kernel 依赖的 Erlang 运行时原语(§6.1);字符串/数值分歧进 known-divergences 的登记依据(§5.1)。
