# 08 nanopass 宿主语言调研:SBCL/CLOS 与 Erlang 的可行性对比

状态:调研结论。回答"离开 Scheme 之后,nanopass 风格的多 pass 编译器能否在 SBCL(Common Lisp)或 Erlang 上实现同等功能"。证据基础为 nanopass-framework-scheme 仓库源码取证。结论服务于 [00](00-overview.md) D3 的宿主选择。

> 2026-10-11 修订:原 §5 的结论("宿主是 Clojure、自造 define-language 宏层")与同日采纳的 [07](07-scheme-layer.md) 冲突,且 07 随后也被推翻。现行裁决是 [09](09-erlang-hosted-compiler.md):**nanopass 框架与 pass 长期用 Erlang 写**。§1-§4 的调研不变;§5 已按现行裁决重写。

> 结论先行:**两者都能实现,但"能实现"和"不亏本"是两回事**。SBCL/CLOS 路线赢了分发的声明式表达(上下文维度提升为 method 特化),Erlang 路线赢了模式匹配的原生度(函数子句即 syntax-case 子句)与 TCO/并行;两者共同失去的是 nanopass 最值钱的一半——**编译期文法校验与 ellipsis 模板**。clojerl2 选择 Erlang 宿主并接受这一损失([09](09-erlang-hosted-compiler.md)):编译期校验改为**每个 pass 边界的运行期整树校验**,ellipsis 模板改为列表推导;换来的是 Erlang 函数子句即 pass 子句、TCO 语言保证、无自举冷启动。

## 1. 取证:nanopass 到底依赖 Scheme 的什么

对 nanopass-framework-scheme 仓库全量检索 `define-record-type|syntax-case|with-syntax|quasisyntax|define-language|define-pass`,共 **636 处匹配,分布 32 个文件**,集中在:

| 依赖特性 | 出现位置 | 性质 |
|---|---|---|
| `syntax-case` + ellipsis 模板 | pass.ss / meta-syntax-dispatch.ss / nano-syntax-dispatch.ss 等,600+ 处 | 核心,不可替代性最高 |
| 卫生的模式分发(matcher) | nano-syntax-dispatch.ss | 算法可移植,输出的是 syntax object |
| R6RS `define-record-type` | records.ss | 易替代(defstruct/defclass/Erlang record) |
| 模块系统(library) | 全部文件 | 易替代(ASDF/package、Erlang module) |
| 尾调用保证 | 隐式依赖 | Scheme 保证;SBCL 不保证;BEAM 保证 |

**pass 的本质**(pass.ss:388-459 `make-processor-clauses`):每个 clause 左值在宏展开期被 meta-parser 解析为 nano-meta AST,生成按"输入 term 的产生式 alternative(record tag)+ 嵌套模式 + guard"选择执行体的 matcher;未覆盖的 alternative 自动生成递归穿通的 system clauses(pass.ss:461 起)。即:

> processor = 以 (节点类型, 结构模式, guard) 为分发键的转换函数集合 + 手动穿线的上下文参数。

真实例证(tests/compiler.ss:567 `convert-closure`):processor `Expr` 携带额外形参 `direct`,两条 `(app ...)` clause 属于同一 alternative、靠子节点模式 + `(guard (assq x direct))` 区分。

## 2. SBCL/CLOS 路线

### 2.1 为什么多分派能表达 pass

把每个非终结符 alternative 建成类,processor 建成 generic function,则:

- **单分派 = processor 按 alternative 分发**。PCL 按首参的类选 method,与 nanopass 按 record tag 选 clause 同构;兜底的 default method 恰好扮演自动生成的 system clauses(默认递归遍历)。
- **多分派 = 把上下文维度从手动穿线提升为声明式特化**。nanopass 里 `direct`、`binding*` 靠形参穿线、上下文分支靠 guard;CLOS 可同时特化第二参:`(defmethod process-expr ((n app-node) (ctx direct-context)))`,分发键从 `(节点类型)` 升级为 `(节点类型 × 上下文类型)`。
- **红利**:`call-next-method` + 节点类继承 ⇒ 增量 pass(nanopass 只能整个 processor 复制);`:around`/`:before` ⇒ 横切关注点;新增节点与新增 pass 两个维度都开放(visitor 模式在"新增节点"维度封闭)。

### 2.2 映射边界(必须诚实)

1. **嵌套模式分发不掉**:同一 alternative 内的子结构区分(如 `(app (var ,x) ...)` vs `(app ,e0 ...)`)仍需方法体内用 trivia/optima 补一层模式匹配。
2. **编译期完备性检查丢失**:nanopass 宏展开期校验"每个 alternative 有 clause 或可自动生成";CLOS 是运行时 `no-applicable-method`。
3. **TCO 不保证**:需 `(optimize (debug 0) (safety 0))` 或改写,深递归有风险。
4. **ellipsis 模板要自己造**:600+ 处 syntax-case 依赖意味着完整移植 ≈ 重写;务实做法是只取思想(CLOS + trivia),不做 API 兼容。

## 3. Erlang 路线

### 3.1 映射表

| nanopass 成分 | Erlang 对应 | 保真度 |
|---|---|---|
| processor clause `[pattern guard rhs]` | 函数子句 + `when` guard | ✅ 几乎一一对应 |
| AST term | 标记元组 `{app, Op, Args}` / record | ✅ |
| 上下文穿线 | 函数参数累积器 | ✅ 手感相同(均不可变数据) |
| 多值返回 `-> Expr (binding*)` | 返回元组 `{Expr, Bindings}` | ⚠️ 手动打包 |
| ellipsis `,e1 ...` | ❌ 写 `lists:map` / 列表推导 | ⚠️ 噪音变多 |
| 自动 system clauses | 手写兜底子句 / `erl_syntax_lib:mapfold` 式通用遍历 | ⚠️ |
| 编译期文法校验 | ❌ 运行时 `function_clause`(Dialyzer 部分挽回) | ❌ 最大损失 |
| define-language/define-pass 宏 | parse transform + merl 准引用 | ⚠️ 能做但痛苦 |
| TCO | ✅ BEAM 语言级保证 | ✅ 比 SBCL 稳 |

### 3.2 代码对照

`convert-closure`(tests/compiler.ss:567)的 Erlang 形态:

```erlang
expr({app, {var, X}, Args}, Direct) ->
    case lists:keyfind(X, 1, Direct) of           % Scheme guard 里的 assq 在
        {X, CodeName} ->                          % Erlang guard 中非白名单,
            {app_direct, CodeName, {var, X},      % 只能挪进函数体 case
             [expr(A, Direct) || A <- Args]};     % ,e1 ... ⇒ 列表推导
        false -> ...
    end;
expr({app, E0, Args}, Direct) ->
    {anonymous_call, expr(E0, Direct), [expr(A, Direct) || A <- Args]};
expr({letrec, Bindings, Body}, Direct) -> ...
```

子句选择、guard、递归转换的结构与 Scheme 原版完全同构。**函数头模式匹配就是 Erlang 程序员的 syntax-case。**

### 3.3 生态证据:存在性证明

- `erlang/otp` 的 `lib/compiler` 自身即多 pass 架构:`v3_core`(AST → Core Erlang)、`beam_core_to_ssa`(Core → SSA;新版 OTP 中取代原 `v3_kernel`,本机 OTP 28 已无 `v3_kernel`)、`beam_ssa_*` 系列,每个 pass 都是对 term 的多子句函数变换。
- LFE(Lisp Flavoured Erlang)编译器:多 pass、纯 Erlang 实现的 BEAM 上 Lisp。

"用 Erlang 写多 pass 编译器"是该生态的主流实践,不是理论推演。

### 3.4 额外红利

- TCO 语言保证,深递归无忧;
- pass 内对模块/函数粒度天然可并行(独立编译单元),supervisor 可给编译器本身加容错;
- 热代码加载适合交互式编译器实验(改一个 pass 立即重载)。

## 4. 三方对比

| | Scheme (nanopass 原版) | SBCL/CLOS | Erlang |
|---|---|---|---|
| 模式分发 | 编译期,ellipsis 模板 | 类多分派 + 方法体内补模式 | 函数子句,原生 |
| 上下文维度 | 手动穿线 + guard | **声明式多分派** | 手动穿线 + case |
| 文法静态检查 | ✅ 编译期 | ❌(可自造) | ❌(Dialyzer 部分挽回) |
| TCO | 语言保证 | 不保证 | 语言保证 |
| 造 define-pass 的宏能力 | syntax-case,原生 | defmacro,能造 | parse transform,痛苦 |
| 生态证据 | 框架本体 | SICL/Cleavir | Erlang 编译器自身、LFE |

## 5. 对本项目(clojerl2)的启示(2026-10-11 按 [09](09-erlang-hosted-compiler.md) 重写)

1. **Erlang 是长期宿主,不是过渡 stage0**。nanopass 的 pass 在 Erlang 里就是"多子句函数 + 累积器 + 兜底子句",OTP 编译器自身即先例;Clojure 局部量不可变、无 call/cc,对宿主的要求正好落在 Erlang 的原生能力内(不可变数据 + 函数子句匹配 + TCO)。
2. **"自动 system clauses"在 Erlang 里用数据驱动实现**,不需要宏:语言定义是数据(`clj2_lang`),框架按字段表重建节点(`clj2_np:descend/mapfold`),pass 只写自己关心的 op。§3.1 映射表里标 ⚠️ 的"自动 system clauses"由此变成 ✅。
3. **两块损失的处置**:编译期文法校验 → 每个 pass 边界的**运行期**整树校验(dev/测试默认开,报错带节点路径);ellipsis 模板 → 列表推导与 `lists:mapfoldl`,接受噪音。parse transform/merl 的"造宏"路线不走。
4. **旧 stage0 审查的教训**(Scheme 子集编译器 `sk_*`,已删除):它在 Erlang 里手写了三套平行遍历(捕获扫描、装箱改写、自由变量),并在发射器里做 lambda lifting、SSA phi 合并等语义决策,实测有 try 后丢环境、`or` 写死变量名、实参语句逆序、letfn 自由变量越界、try 内变量外泄等 bug。根因是没有框架提供的通用遍历,以及发射器越界做语义决策。新框架用"通用遍历 + 每 pass 一件事 + 发射器只序列化"把这两个根因结构性地消掉,旧 bug 已改写为 Clojure 回归测试。
5. **CLOS 的教训作为设计输入**:"上下文即分发维度"在 Erlang 里就是 pass 函数的额外参数(如 `clj2_p_loop` 的 recur 目标、`clj2_p_letfn` 的替换表),与 nanopass 原版手感相同。
