# clojerl2-035 JVM 异常类与参数检查

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-033

## 目标

清掉分诊出的两大类:`:pending/jvm-exceptions`(52,抛了错但不是 JVM 的异常类或信息)和 `:pending/arg-checks`(49,core 函数的参数检查与 JVM 不同)。

## 工作内容

- [x] **按失败的调用细化 Erlang 错误**(`clj2_rt:refine_error/3`):按类 catch 时,先用栈顶帧(带参数)细化 `badarith`/`badarg`/`function_clause`:有 nil 操作数 → NullPointerException;算术的非数字操作数 → ClassCastException;位运算的非整数 → IllegalArgumentException;字符串/正则/数学和运行时模块里的类型不符 → ClassCastException。细化本身出错时原样返回原错误。没有 catch 匹配时重新抛出细化后的错误
- [x] clj2 错误项的 JVM 类:不能比较、不能 deref、不是 IPending → CCE;nil 下标 → NPE;字符串下标 → StringIndexOutOfBoundsException
- [x] 比较运算 `<`/`>`/`<=`/`>=` 与 `zero?`/`pos?`/`neg?`:快速路径两个 Erlang 数字直接比;慢速路径(`clj2_rt:num_compare/3`)按值比较分数,非数字按 JVM 抛错(原先按 Erlang 项序静默得出 true/false)
- [x] 集合:`nth` 对不支持的类型抛 UnsupportedOperationException、`(nth nil i)` 为 nil;`assoc` 越界 IOOBE;map 的 `conj` 接受 sorted map、record 和 entry 的 seq(逐个推进,遇到非 entry 立即失败,`(merge nil (range))` 不再吃满内存),拒绝非二元组向量;字符串的 `contains?` 只收下标;ex-info 不能 `seq`/`count`
- [x] core 函数:`find`/`select-keys`(只收可关联集合,select-keys 保留元数据)、`num`、`even?`/`odd?`、`parse-boolean`、`symbol`/`keyword`/`name`/`namespace` 的边界、`peek`/`pop`/`rseq`/`shuffle`/`nthrest`(按 1.12)、`sorted-map` 缺值、`assoc!` 末尾缺值、`repeat` 的计数检查与截断、`mapcat` 调用时先实现前 4 个结果(同 JVM 的 `apply concat`)、`key`/`val`、`run!` 遵守 reduced、`rand-nth`/`rand-int 0`、单参数 `+`/`*`、浮点的 `rem`/`mod`/`quot`、关键字与符号按命名空间优先排序、`special-symbol?` 含 `&`、`(eval f)` 对函数值返回它自己、元数 > 20 的消息
- [x] 宿主方法:整数解析的 JVM 消息(radix、范围、decode)、String 方法拒绝 nil 参数与错类参数、`StringBuilder.` nil、`System/getProperty` 非字符串、`format` 的非字符串格式与参数类名

## 验收标准

- 两类条目清零或改登记;`make test`、`make certify`、`make cts` 全绿

## 结论

- 远端门控:eunit 651 全过;corpus 3739 → **3853**/4841,0 新失败、0 过期;CTS 断言通过 4882 → **5040**、失败 417 → 294、错误 741 → 700(基线已重写);smoke、docs-check 通过。
- `:pending/jvm-exceptions` 与 `:pending/arg-checks` 清零。改登记:转换函数的范围检查 4 条 → `:number/beam-semantics`(项目决定:数值按 BEAM,不做范围检查;差异文本改为写明这一点,并删去"比较不检查类型"——现在检查了);future 的 ExecutionException 1 条 → `:exceptions/erlang-classes`;`#error` 打印 1 条 → `:pending/printer`;ArrayList、iterator 2 条 → `:pending/host-types`;分数计数 1 条 → `:number/no-ratio-arithmetic`。
- 过程中修掉的两处隐患:`is_keyword('')` 对空符号崩溃(导致 catch 处理器自己抛 badarg);CTS 跑出的 `merge` 无限 seq 吃满内存。
- 已知未做:`number?` 对分数为 false(分数比较已支持,但谓词与算术仍归 `:number/no-ratio-arithmetic`)。
