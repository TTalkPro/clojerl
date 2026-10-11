# 02 BEAM 后端:目标格式、发射器与求值模型(D4/D11)

状态:设计提案。覆盖 clojerl2 编译器的最后一层:把 [01](01-nanopass-pipeline.md) 的末端 IR(Labs)变成可执行的 BEAM 模块,以及 REPL/eval 的单轨求值模型。值表示、协议分派、Var/NS 语义见 [03](03-runtime-model.md),不在此重述。

> 结论先行:**目标格式选 Erlang abstract forms(absform),经 `compile:forms/2` 交付 erlc 后半段**。这是 Gleam v1.19 与 Elixir 已验证的工业化路线:文档化、跨 OTP 版本稳定、免费获得 beam_ssa 全套优化、崩溃栈行号可精确到 Clojure 源行。发射器退化为纯序列化器(Labs → absform 项)。求值单轨化(D11):不维护解释器,REPL 每个 form 走同一条编译路径 `compile:forms` + `code:load_binary`。**v1 不生成 BEAM 汇编码、不生成 Erlang 文本源码、不生成 Core Erlang**。

## 1. 目标格式决策(D4)

### 1.1 候选格式对照

| 候选 | 稳定性 | erlc 优化 | 源位置精度 | 维护成本 | 先例 |
|---|---|---|---|---|---|
| Erlang 文本源码 | 语言级稳定 | ✅ 全套 | 需手工对齐生成代码行号,脆弱 | 中(再解析一轮,pretty-print 细节多) | clojerl 1.0 未走;05 号文曾主张 |
| Core Erlang(cerl) | ⚠️ 非官方外部格式,内部 API 可漂移 | ✅ 全套 | 有注解机制但工具链支持弱 | 中高 | clojerl 1.0 |
| **Erlang abstract forms** | ✅ OTP 官方文档化,`erl_parse`/`compile:forms` 公开 | ✅ 全套(过 erlc 前端即入 beam_ssa) | ✅ ANNO 携带 line/col/file,贯穿至栈回溯 | 低 | **Gleam v1.19、Elixir** |
| BEAM 汇编码(specific) | ❌ 每 OTP 版本演进(见 §1.3) | ❌ 需自行复现 beam_ssa 数十年积累 | 手工维护 | 不可持续 | 无主流语言走此路 |

### 1.2 Gleam v1.19 的证据(2026-10)

Gleam 从生成 Erlang 源码改为生成 abstract forms,经 external term format 二进制直接喂编译器,跳过 erlc 前半段(扫描/解析/展开)。其实测收益:编译提速、崩溃报告行号精确到 Gleam 源、生成代码质量提升。其**拒绝直出 BEAM 字节码**的论证逐条适用于我们:(a) 指令集随 OTP 演进,跟进成本不可持续;(b) 复现 erlc 的优化积累不可行。Elixir 同样经 abstract forms 交付。两个生产级语言背书,决策风险已从"格式赌错"降为"映射写错"。

### 1.3 直出 BEAM 的精确逃逸口(文档化非目标)

beam_makeops(erts 内部文档)揭示 BEAM 指令三层结构:

1. **external generic**:genop.tab 定义,跨版本稳定契约(OTP 20 有 159 条);
2. **internal generic**:loader 变换规则产生的中间形态;
3. **specific**:实际执行的指令(OTP 20 有 389 条)。

loader 把 generic 重写为 specific,做类型推断、指令打包与融合(如多条 move 融合为 move2/move3)。**推论:若未来确需绕过 erlc,稳定接口是 generic 指令 + `beam_asm`(经 beam_opcodes.erl),绝不是 specific 指令**。v1 不启用此路径——Gleam 的成本论证(§1.2)成立,且走 absform 可白得 beam_ssa 全套优化——但接口边界在此精确记录,避免将来重新考古。

## 2. 发射器架构:Labs → absform → compile:forms/2

```
Labs([01] 末端 IR,与 absform 一一对应)
  │  emit/1:纯序列化,无语法分析、无优化决策
  ▼
absform 项列表(module = form 列表)
  │  term_to_binary(external term format,可省文本往返)
  ▼
compile:forms(Forms, [return_errors, debug_info, ...])
  │
  ▼
{ok, Module, Binary} ──► 写 .beam 文件 / code:load_binary(§5)
```

关键性质:

- **发射器是纯函数**(D5 的末端体现):Labs 树进、Erlang 项出,不读全局状态。所有语义决策(协议分派、Var 解析、闭包)都已在 [01](01-nanopass-pipeline.md) 的 pass 链中完成;发射器不做任何"聪明事"。
- **模块粒度**:一个 Clojure 命名空间 → 一个 BEAM 模块;另加 [03](03-runtime-model.md) 的每对 `Protocol__Type` impl 模块与每个 multimethod 的分派模块。
- **优化边界**:所有目标级优化交给 erlc(beam_ssa:内联、死代码、move 融合、类型特化)。我们自己的优化只在 [01](01-nanopass-pipeline.md) 的源级 pass 做(mode-gated,dev 模式只跑常量折叠)。

## 3. 名称改编、字面量与模块布局

### 3.1 名称改编(name mangling)

Clojure 标识符字符集超出 Erlang atom 安全集,统一编码(小写十六进制转义,可读性优先):

| Clojure 字符 | 编码 | 例 |
|---|---|---|
| `?` | `_Q` | `nil?` → `nil_Q` |
| `*` | `_S` | `*out*` → `_Sout_S` |
| `!` | `_B` | `swap!` → `swap_B` |
| `<` `>` `=` | `_L` `_G` `_E` | `<=` → `_L_E` |
| `+` `-` `/` `.` | `_P` `_D` `_F` `_O` | `foo-bar` → `foo_Dbar`,`a/b` → NS 分隔,不出现 |

规则:

- **arity 进函数名**:`f/N` 与 `f/M` 分属不同导出,函数名改编后附加 `_N`(如 `map_1`、`map_2`),与 Erlang `Name/Arity` 不冲突且便于诊断阅读。
- **多 arity 函数的入口**:编译出一个变长分派函数 `fname__vararg`,内部 case 按实参个数跳到 `fname_1`/`fname_2`/rest-arg 版本(D6 的 recur 尾调用在分派后保持)。
- **私有生成函数**:`__` 前缀 + 序号(`__lambda_3`、`__case_7`),不导出;与 [03](03-runtime-model.md) 的 impl 模块命名(`Protocol__Type`)同一约定族。
- NS 模块名:`clje.user` → atom `'clje.user'`(带点 atom 合法,与 clojerl 1.0 一致)。

### 3.2 字面量编码

absform 的原子/数字/字符串有直接构造子,但**没有任意项的字面量形式**。Clojure 的 vector/map/set/keyword/symbol 字面量([03](03-runtime-model.md) D8 的打标持久结构)走两条路:

1. **常量折叠路径**:编译期已知的字面量经 `erl_parse:abstract/1` 技巧——它对任意 Erlang 项生成构造形式(cons/tuple/atom 组合的 absform 树)。发射器先把 Clojure 字面量翻译为运行时 Erlang 表示项,再 `erl_parse:abstract` 得构造树。erlc 常量折叠会把无副作用的构造收进 **beam literal pool**,零运行时开销。
2. **运行时构造路径**:含非字面量子项时退化为对运行时构造函数的 `{call,...}`(如 `clje_rt:vector([...])`)。

### 3.3 模块布局(每 NS 一个 .beam)

```
-module('clje.user').            % {attribute,ANNO,module,...}
-export([...]).                 % 公开 var 对应函数 + '__ns_init'/0
-on_load(__ns_init__/0).        % 见 §3.4
-compile({no_auto_import,...}). % 按需要
%% 函数区:改编后 var 函数、__vararg 分派、__lambda_N 私有
%% debug_info:abstract_code chunk 存 {raw_abstract_v1, Forms}(§4)
```

### 3.4 模块初始化(on_load)

jank 的 `jank_load_foo` + 模块注册表模式映射为:每 NS 模块生成 `__ns_init__/0`,经 `-on_load` 在 `code:load_binary` 完成时自动执行,完成 var 注册与 NS 注册([03](03-runtime-model.md) §2-3 的注册语义)。`on_load` 内禁止远程调用的限制由设计规避:注册只写本模块的 persistent_term/ETS 表项,不调用未加载模块。

## 4. ANNO 纪律:源位置从 reader 到栈回溯

目标:编译期诊断与运行时栈回溯都精确到 Clojure 源(file/line/col)。机制:

- **每个 IR 节点带位置注解**:reader 产出即带 `{file,line,col}`;每个 pass 重写节点时**必须保留注解字段**,形式化语言的 spec 校验把"丢注解"定为管线错误。先例:jolt 的 `:pos`/`:inline-chain` 在全部 pass 后存活;inline 场景保留调用链以便诊断展开多层。
- **发射时转 erl_anno**:Labs 注解 → `erl_anno:new({Line,Col})`(file 经 `compile:forms` 的 file 属性或 ANNO 内 file 项)。absform 每个表达式节点都要求 ANNO,发射器**禁止**用 `erl_anno:new(0)` 兜底。
- **收益闭环**:erlc 告警/错误行号 → Clojure 源行;beam `Line` chunk → 异常栈 `[{Mod,Fun,Arity,[{file,...},{line,...}]}]` → Clojure 源行;`debug_info` 选项把 absform 存入 `abstract_code` chunk(`{raw_abstract_v1,Forms}`),cover/dialyzer/debugger 等工具链直接可用。

这是 Gleam v1.19"崩溃栈精确到 Gleam 源行"同款机制,无自研成分。

absform 片段示例:

```erlang
{call,ANNO,{atom,ANNO,foo},[{integer,ANNO,1}]}           %% foo(1)
{'fun',ANNO,{clauses,[{clause,ANNO,[{var,ANNO,'X'}],[],[{var,ANNO,'X'}]}]}}  %% fun(X)->X end
{named_fun,ANNO,rec,[{clause,ANNO,[],[],[...]}]}         %% 自递归 fn(recur 命名)
```

## 5. 求值模型:单轨编译(D11)

**不设解释器**。REPL/eval 与文件编译走同一条管线:

```
read → 管线([01]) → emit → compile:forms → code:load_binary(eval_mod_N, Bin)
```

- **per-eval 生成模块**:每个顶层 form 编译进 `__eval_N` 模块(N 单调递增),导出 `__eval/0` 返回 form 值;`def`/`defn` 的副作用经 §3.4 的注册路径写入当前 NS([03](03-runtime-model.md) §2)。
- **与 clojerl 1.0 的对照**:1.0 是双轨——编译走 `compile:noenv_forms(from_core)`,顶层走 core_eval(839 行 erl_eval fork),整套子系统要与 Core Erlang 语义保持同步,是持续维护负担。D11 用"每 form 一次编译"换"删掉整个解释器"。
- **REPL 延迟**:增量单位是单 form,absform 路径跳过了扫描/解析,单 form 编译在毫秒量级;与解释器启动开销相当,可接受。`compile:forms` 在专用编译进程执行,避免污染 REPL 进程的 code server 状态(沿用 clojerl 1.0 的隔离直觉,但原因从"状态弥漫"变为"干净工程")。
- **热代码两版本语义**:重定义 var = 重新加载该 NS 模块;BEAM 保证**旧进程继续跑旧代码**,新调用走新代码。这是已知行为,文档化:REPL 里持有旧 fun 值的进程看到旧定义,与 Erlang 原生语义一致,不模拟 JVM 的"全局立即生效"。
- **eval 的模块泄漏**:`__eval_N` 模块累计,定期 `code:purge`/`code:delete`(N 超阈值或值已被读取后)。

## 6. 编译缓存与增量编译

- **缓存键**:`sha256(源文本) + 编译器版本 + OTP 主版本 + 编译选项指纹`,产物为 .beam 二进制;命中即跳过整条管线。
- **粒度**:NS 级。跨 NS 依赖经 [03](03-runtime-model.md) 的协议 impl 模块存在性缓存自然失效(extend 只新增 impl 模块,不触发 NS 重编译——D9 的直接红利)。
- **rebar3 插件**:provider 在 compile 前查缓存目录(`_build/<profile>/clojerl2_cache/`),miss 才调编译器;`clean` 清缓存。结构与 `rebar3_clojerl` 对齐,降低用户迁移成本。

## 7. 风险清单(按优先级)

1. **映射 bug,而非格式风险**:absform 表达力已验证——guard 上下文、带守卫的 fun 子句、`receive ... after`、`try/of/catch/after` 组合全部文档化可表示([00](00-overview.md) §6 风险 5 复核)。残余风险是**我们的 Labs→absform 映射写错**(如 guard 里混入非 guard-safe 调用)。对策:Labs 文法把 guard-safe 子语言做成独立非终结符,spec 校验在发射前拒绝。
2. **双层 IR 的诊断质量**:错误要穿过 absform→Labs→源 两层回溯。ANNO 纪律(§4)覆盖行号,但 erlc 告警措辞是 Erlang 词汇("function foo_2 undefined"),用户体验需一层告警翻译器。接受为打磨项,不阻塞。
3. **eval-compile 延迟**:单 form 毫秒级预期基于 Gleam 提速证据外推;若 REPL 体感不足,先 profile 编译进程启动与 `code:load_binary` 路径,再考虑复用编译进程池——不提前优化。
4. **OTP 版本地板**:**要求 OTP 27+**。理由:(a) `erl_anno` 列信息与 `compile:forms` 行为在新版本稳定;(b) beam_ssa 近年重写收益只在 26+ 完整;(c) Gleam/Elixir 工具链现状以 27 为基线,对齐可复用其排错经验;(d) 新方言无存量用户,无兼容包袱。
5. **on_load 限制**:on_load 阶段不可远程调用、不可阻塞;NS 初始化若将来需要触发其他 NS 加载(循环依赖),需把注册拆成"on_load 登记 + 首次访问惰性完成"两段。当前设计单 NS 自足,标记为已知边界。

## 8. 开放问题

- eval 模块的 GC 策略(§5):固定滑动窗口 vs LRU,待 REPL 实测后定。
- 告警翻译器(风险 2)是否纳入 v1,还是先发原始 erlc 措辞。
- `debug_info` 是否默认开:工具链收益大、.beam 体积代价小,倾向默认开,待 04 号文 CI 体积预算确认。

## 9. 与其他文档的关系

- [05](05-erts-target.md):ERTS 契合点分析沿用;**其"生成 Erlang 源码是唯一正道"的结论被 Gleam v1.19/Elixir 实践更新为 abstract forms(D4)**——05 号文写作时 absform 作为外部目标尚无生产级先例,现已不同。
- [06](06-scheme-on-erts.md):其"目标 IR 选 Core Erlang"的判断同样被 D4 取代;absform 比 Core Erlang 更靠近 erlc 公开契约(cerl 是内部 API),且 ANNO/工具链支持更好。
- [00](00-overview.md):本文是 D4(§1-4)与 D11(§5)的详述;决策编号以 00 号文为准。
- [01](01-nanopass-pipeline.md):Labs 文法是本文发射器的唯一输入契约;guard-safe 子语言(风险 1)需在 01 号文 Labs 定义中落地。
- [03](03-runtime-model.md):值表示(D8)、协议 impl 模块(D9)、Var/NS 注册(D7)决定 §3 的具体构造函数名与初始化语义,本文只引用不重复。
- [04](04-bootstrap-and-conformance.md):stage0 直译编译器同样走 absform(同一发射器,子集输入);编译缓存键纳入种子不动点校验。
