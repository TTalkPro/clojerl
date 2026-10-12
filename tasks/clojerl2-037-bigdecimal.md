# clojerl2-037 BigDecimal

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-035

## 目标

实现 `java.math.BigDecimal`:`1.5M` 字面量、算术与 JVM 的类型提升、精确除法、`with-precision`/`*math-context*`、打印、比较与相等、`bigdec`/`decimal?`、`format`,以及常用的 BigDecimal 方法。原先 `1.5M` 读得进来、求值即抛错(corpus `:pending/numbers` 71 条,CTS 约 300 个断言)。

## 设计

- 值 `{decimal, Unscaled, Scale}`,与 BigDecimal 的 unscaledValue/scale 相同(`1.50M` 是 `{decimal, 150, 2}`),新模块 `clj2_decimal`;字面量编译为常量,宏展开结果里的 decimal 也是常量
- 算术:kernel 的 `+ - * / inc dec == quot rem` 保留"两个 Erlang 数字"的快速路径,其余走 `clj2_rt:num_op/3`:有 double 结果是 double,否则有 BigDecimal 结果是 BigDecimal(按 `*math-context*` 舍入);分数仍无算术(`:number/no-ratio-arithmetic`),非数字按 JVM 抛错
- 除法:无精度时精确,首选 scale 为 S1−S2,除不尽抛 ArithmeticException "Non-terminating decimal expansion…";有精度时舍入到 P 位有效数字,再把尾零去到首选 scale。8 种 RoundingMode
- `=` 在 BigDecimal 之间按值(`1.0M` 等于 `1.00M`,同 compareTo),哈希取去尾零后的值;`(= 1M 1)` 为 false、`(== 1M 1)` 为 true,同 JVM
- 打印按 `BigDecimal.toString`(`1E+3M`、`1E-7M`),`pr` 和 `print` 都带 M,`str` 不带

## 工作内容

- [x] `clj2_decimal`:解析、toString/toPlainString、加减乘、精确与带精度的除法、舍入、setScale、stripTrailingZeros、quot/remainder、比较、转 double/整数/分数、哈希
- [x] 接入:reader 常量、打印、`class`(java.math.BigDecimal)、`=`、`compare`/`sort`、`number?`(含分数与 BigDecimal)、`rational?`、`bigdec`、`decimal?`、`abs`、`max`/`min`、`int`/`long`/`double`/`float`(分数截断、非数字 CCE)、`rationalize`、`with-precision`、`format` 的 `%f`(精确 HALF_UP)/`%e`/`%g`
- [x] 宿主:`BigDecimal`/`BigInteger` 作为默认导入的简单类名;`BigDecimal.` 构造、`BigDecimal/valueOf`、`ZERO`/`ONE`/`TEN`、`MathContext.`、`RoundingMode/HALF_UP` 等;方法 scale、precision、unscaledValue、setScale、stripTrailingZeros、toPlainString、add/subtract/multiply/divide(含 MathContext)、remainder、compareTo、equals(scale 有别)、doubleValue/longValue ……
- [x] 顺带:浮点的 `mod` 返回浮点(`(mod 4.0 2)` 为 `0.0`);`unsigned-bit-shift-right` 的结果按有符号 64 位读回

## 验收标准

- `:pending/numbers` 清零;`clj2_decimal_tests`;`make test`、`make certify`、`make cts` 全绿

## 结论

- 本机门控(按用户要求不再用 linux01):eunit 655 全过;corpus 3903 → **3975**/4841(82.1%),0 新失败、0 过期,`:pending/numbers` 清零;CTS 断言通过 5040 → **5454**、失败 294 → 245、错误 700 → 393,无退化(基线已重写);smoke、docs-check 通过。
- 改登记:int 溢出、NaN 商各 1 条 → `:number/beam-semantics`;打印混合集合里的字符 2 条 → `:char/integer`。
- 未做:分数算术(仍是 `:number/no-ratio-arithmetic`,CTS 中约 96 个断言);map 键按项精确比较,所以 `(get {1.0M :a} 1.00M)` 为 nil(`:collections/exact-keys`)。
