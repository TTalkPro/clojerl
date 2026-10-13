# 10 嵌入式 DSL 与规则引擎

日期:2026-10-13。适用:clojerl2 M7。

## 1. 目标

clojerl2 是一个跑在 BEAM 上的 Clojure 子集。M6 之前的工作追求与 JVM Clojure 逐条一致;从 M7 起,目标改为让它成为
**Erlang 应用里可热加载的自定义 DSL 与规则引擎**:宿主应用(例如网关的中间件、业务规则)在运行时拿到一段
Clojure 源码,编译、加载、调用,改了就重新加载,不停机。

核心能力(用户确认的范围):函数与匿名函数、命名空间、vector / set / map / list、defmulti、宏、与 Erlang 互操作、
热加载、尾调用与 recur、var、Erlang 自身的数学与正则、字符串操作与流程控制。JVM 一致性不再主动扩展。

clojerl2 保持通用:不包含任何特定宿主的代码。宿主怎么接入,写在宿主自己的设计文档里。

## 2. 设计决定

- **不设沙箱**:脚本可以调用任意 Erlang,等同于宿主自己的代码。宿主若要限制,自行决定谁能提交脚本。
- **宿主数据原地使用**:宿主的数据通常是 Erlang 原生 term(JSON 解码后是 map、binary、list、`null`)。
  Clojure 的集合函数直接接受 Erlang map:`get`、`assoc`、`update`、`get-in`、`assoc-in`、`keys`、`seq`、`count`、
  `contains?`、`merge`、`reduce-kv` 等作用于 Erlang map 时,结果仍是 Erlang map。脚本拿到请求体就能改,改完交还宿主,
  边界上不做整体转换(性能:对每条消息、每个事件都要调用的规则,整体深拷贝是最大的开销)。
- **显式转换另备**:需要 Clojure 自身集合时用 `clj2_data:from_erl/1,2` 与 `to_erl/1,2`(Clojure 里 `erl->clj`、`clj->erl`),
  可选把字符串键转成关键字。
- **嵌入 API**:模块 `clj2`。`load(Source)` 编译一个命名空间并热替换,返回 `{ok, Ns}` 或带行列号的结构化错误;
  `call(Ns, Fn, Args)` 调用;`eval/1,2`;`unload/1`。
- **热替换与长请求**:BEAM 每个模块只有两个版本,旧版仍有进程在跑时不能再加载新版。规则脚本可能频繁修改、
  而流式请求可能持续数分钟,因此 `load/2` 提供 `versioned` 模式:每次加载编译成带版本号的模块
  (`<ns>$v<N>`),命名空间指向最新版本,旧版本在没有进程使用时由 `clj2:gc/0` 回收。默认仍是普通的两版本替换。

## 3. 任务

见 TASK.md M7:044 嵌入 API、045 Erlang 原生 map 作为 Clojure 集合、046 数据转换、047 版本化热替换、
048 性能基准、049 嵌入文档与示例。

## 4. 后续决定(2026-10-13)

- **并发与状态用 Erlang**:保留 Clojure 的核心语法体系;atom、volatile、agent、future、promise、ref/STM 一律删除,
  并发就是 Erlang 进程与消息。保留 var(动态绑定、`bound-fn`、watch、validator)。
- **`receive`**:带模式匹配的选择性接收,编译成 Erlang 原生 receive;向量模式匹配 tuple 或 list。
- **数据直接交给 Erlang**:没有元数据的 map 就是 Erlang map;向量在调用 Erlang 函数时自动深层转成 list
  (运行时模块、标准库、运算符与类型判断除外)。

- **JVM 特性只留与语言本身相关的**(053):保留 deftype、defrecord、协议,异常(构造、方法、按类 catch),
  BigDecimal,作为 writer 的 io 设备,以及任何值的 toString / equals / hashCode;删除 Java 类的垫片
  (String、Math、Integer/Long/Double/Character 等静态成员、System、Thread/Executors、StringBuilder、
  Java 集合与 Iterator、UUID/Random 类、字符集与 URL 编码、Keyword/Symbol/Var/RT/Murmur3 的成员)和 Java 数组。
  `clojure.math` 改由 `clj2_math` 实现。`#inst` 读作 Erlang 时间(毫秒整数)。

任务:TASK.md M7 的 050–053。
