# clojerl2-039 其余标准库命名空间

状态:已完成(2026-10-13)
里程碑:M6(一致性收尾)
依赖:clojerl2-038

## 目标

清理 `:pending/stdlib-namespaces`(69 条):提供 `clojure.edn`、`clojure.math`、`clojure.pprint`、`clojure.repl`,以及它们牵出的 `#inst`、打印限制和 reader 的严格性。

## 工作内容

- [x] `clojure.edn`(`src/erl/clj2_edn.erl` + `priv/clj2/stdlib/clojure/edn.clj`):`read-string`/`read` 支持 `:readers`/`:default`/`:eof`;reader 的 EDN 模式拒绝 `` ` `` `~` `@` 开头与符号内部的这些字符、`::kw`、`#(` `#"` `#'` `#?` `#=` 等分派,`#_` 丢弃的形式也要校验(标签同样要有 reader 函数);集合元数据保留,重复键/元素报错;错误映射到 RuntimeException / NumberFormatException / ArithmeticException
- [x] reader 两种模式共同的修正:`#<` 报 "Unreadable form",`#!` 注释,`#^` 等同 `^`,`skip_to_eol` 停在 `\r`;以 `/` 开头或结尾、含多个 `/` 的符号与关键字被拒绝(`ns//` 除外);八进制转义每位都须是八进制;比率约分(`6/4` → `3/2`,`4/2` → `2`)
- [x] `#inst`(`src/erl/clj2_inst.erl`):按 clojure.instant 校验 RFC 3339,值为 `java.util.Date`,打印为 `#inst "yyyy-MM-ddTHH:mm:ss.SSS-00:00"`;`inst?`/`inst-ms`、`.getTime`、`(java.util.Date. ms)`
- [x] `clojure.math`(`src/erl/clj2_math.erl` + `clojure/math.clj`):`next-up`/`next-down`/`next-after`/`ulp`/`get-exponent`/`scalb`/`copy-sign`/`IEEE-remainder`/`*-exact`(溢出抛 "long overflow"),`sinh`/`cosh`/`tanh`/`expm1`/`log1p`;数值语义按 BEAM
- [x] `clojure.pprint`(移植自 jolt @ d9d454a2,EPL-2.0):字符按码点处理(`cstr`、指令大小写、字符参数),位置参数按 `:param-keys` 保序,`pprint`/`cl-format` 在 `*out*` 绑定之外输出;`isa?` 支持类层次(`clj2_class:is_subclass/2`);任意协议实现的方法可经 `.write` 调用(`clj2_proto:type_method/3`),`*out*` 可绑定到 pprint 的 writer(`clj2_io` 写钩子)
- [x] `clojure.repl`(移植自 jolt):`doc`/`source`/`dir`/`apropos`/`find-doc`/`pst`
- [x] 打印:`*print-length*`、`*print-level*`、`*print-namespace-maps*`(`lift-ns`),BigDecimal、`#inst`、`tagged-literal`、`reader-conditional` 的打印

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `stdlib_namespaces_test`

## 结论

- 本机门控:eunit 659 全过;corpus 4047 → **4152**/4841(85.8%),0 新失败、0 过期;CTS 5455 → **5733**(失败 243、错误 388,基线已重写)。
- `:pending/stdlib-namespaces` 清零。剩余待办:reader 100、host-types 54、runtime-eval 31、core-bugs 20、printer 20、var-surface 18、regex-edge 12 ……
- 已知未做:`cl-format` 的 `~R` 英文基数词;core var 缺文档字符串、arglists 显示 `_`;EDN 的 `##Inf`/`##NaN`/`-0.0`(BEAM 语义);带 `ns` 形式的 `load-string` 会改调用者的 `*ns*`。
