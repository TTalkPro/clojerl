# clojerl2-040 reader 尚不接受的写法

状态:已完成(2026-10-13)
里程碑:M6(一致性收尾)
依赖:clojerl2-039

## 目标

清理 `:pending/reader`(100 条)。其中 62 条是 `##Inf`/`##NaN`(BEAM 浮点没有它们,已登记的 `:number/beam-semantics`),其余是真正的 reader 问题。

## 工作内容

- [x] 数字分组下划线:`1_000_000`、`0xFF_FF`、`0_52`、`36rR_Z`、`1_0.5_5`、`1_0e1_0`、`3_000N`、`1_0/3`;下划线只能夹在两个数字之间(`1_`、`0x_52`、`1e_5`、`1_.5` 是 "Invalid number")。EDN 不接受下划线
- [x] `0xFFN` 等十六进制/八进制/二进制的 `N` 后缀
- [x] 读错误按 JVM:"Invalid number: X"(NumberFormatException)、"Unmatched delimiter: )"、map/set 字面量的重复键 "Duplicate key: X"(IllegalArgumentException,reader 本身检查,代码里的字面量也一样)、"arg literal must be %, %& or %integer"(IllegalStateException,`%0`/`%01` 也拒绝)
- [x] `read-string` 只读第一个形式(`"garbage!@"` 读出 `garbage!`);`(read-string opts s)` 支持 `:eof` 与 `:features`
- [x] `#=(...)` 在读的时候求值(`*read-eval*` 为 false 时报错)
- [x] 标签字面量:`*data-readers*`、`default-data-readers`(`inst`/`uuid`)、`*default-data-reader-fn*`;记录字面量 `#ns.Rec{...}`/`#ns.Rec[...]`,值是数据不求值;同一顶层形式里刚定义的记录(编译时还不存在)在运行时构造,嵌套的也一样;宏拿到的记录值可以作为字面量
- [x] 改登记:62 条 `##Inf`/`##NaN` → `:number/beam-semantics`;`(hash \x)`、`"\000"`、`"\ud800"` → `:char/integer`;`#?(:clj ...)` 4 条 → 新差异 `:reader/platform-feature`(平台特性是 `:clje`,见 differences.md)

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `reader_forms_test`

## 结论

- 本机门控:eunit 661 全过;corpus 4152 → **4183**/4841,0 新失败、0 过期;CTS 不变(5733 / 243 / 388,与基线一致)。
- `:pending/reader` 清零。登记差异 31 → 32 条。剩余待办:host-types 54、runtime-eval 31、core-bugs 20、printer 20、var-surface 18、regex-edge 12 ……
