# clojerl2-020 字符串与 IO 原语层

状态:已完成(2026-10-12)
里程碑:M4
依赖:clojerl2-010

## 目标

实现字符串与 IO 原语层:string = UTF-8 binary,IO 走 Erlang io 协议,`*out*`/`*in*`/`*err*` 动态 var 对接。

## 设计依据

- [03](../designs/03-runtime-model.md) §7 — string = binary(UTF-8);char = integer 码点
- [03](../designs/03-runtime-model.md) §7 — 下标 O(n) 分歧:按码点 `char_at`,文档劝用 seq/reduce 遍历
- [03](../designs/03-runtime-model.md) §7 — 拼接走 iolist 累积,避免 O(n²) 拷贝
- [03](../designs/03-runtime-model.md) §8 — 运行时第 0 层:字符串原语与 IO(走 Erlang io 协议)属"必须接触 BEAM 机制"的部分
- [03](../designs/03-runtime-model.md) §1.3 — char 与 JVM UTF-16 的分歧登记

## 工作内容

- [x] 字符串原语:`char_at`(按码点,O(n))、iolist 拼接(`str` 多参直接产 iolist)、`subs`、比较
- [x] `pr-str`/`prn`/`println` 族的第 0 层部分(打印协议本身的 Clojure 侧归 04 §6.1 的 03-print 层)
- [x] `*out*`/`*in*`/`*err*` 动态 var 与 Erlang io 协议对接:`binding [*out* ...]` 重定向生效
- [x] char = integer 码点的字面量与谓词支持(surrogate pair 即单码点)
- [x] known-divergences 条目:UTF-16 下标分歧、char 语义分歧,各带原因与 03 §7 依据

## 验收标准

- 字符串 round-trip 测试:读 → 打印 → 读回相等(含多字节 UTF-8)
- IO 重定向测试:`binding [*out* (StringIO...)]` 内 `println` 输出被捕获
- 全部字符串/char 分歧条目进 known-divergences 注册表且带 03 §7 引用

## 结论

- **字符串**:新增 `clj2_string`,`clojure.string` 作为第一个标准库命名空间,源码在 `priv/clj2/stdlib/clojure/string.clj`,`make` 时预编译。以限定名引用尚未加载的命名空间时会先从源码路径加载,标准库目录总在源码路径里。
  - 所有函数用 `str` 把参数转成字符串(和 Java 的 toString 一样),遇到 nil 报错;`replace` 支持 Java 的 `$1`/`${name}` 替换语法,也支持传函数;`split` 遵循 Java 语义;`index-of` 返回码点下标。
  - `string:trim` 把 `"\r\n"` 当作一个字形簇,所以 CRLF 要单独列为分隔符。
- **正则**:新增 `clj2_re`,实现了 `#"..."` 和 `re-*` 系列函数、`regex?`。
  - Java 语法先改写成 PCRE 再编译,见 designs/03 §7。
  - 不加 `ucp`,所以 `\w`/`\d` 只匹配 ASCII,与 Java 一致。
  - 没匹配上的分组补成 nil:PCRE 会省略末尾未匹配的分组。
  - `re-matches` 用 `(?:…)\z` 包装,保证整串匹配。
  - 写错的字面量在编译期报错。
  对照 JVM 跑了 28 个用例,一致。
- **`format`**:新增 `clj2_format`,实现 java.util.Formatter 的完整语法,包括参数下标、标志位,以及 `b h s c d o x e f g a` 和 `%n`/`%%`。浮点数按最短往返表示做 HALF_UP 舍入,所以 `2.675` 格式化为 `"2.68"`,与 JVM 相同。出错时抛出以 JVM 异常命名的 ex-info。对照 JVM 跑了 26 个用例,一致;只有 `%c` 是有意不同:我们的整数就是字符。
- **IO**:`*out*`/`*err*`/`*in*` 成为动态 var,值是 Erlang io 设备。实现了 `with-out-str`/`with-in-str`(基于 io 协议的字符串设备)、`read-line`、`printf`、`slurp`/`spit`(UTF-8)。
- **char 与 UUID**:实现了 `char`/`char?`/`char-name-string`/`char-escape-string`;`#uuid` 字面量、`random-uuid`/`parse-uuid`/`uuid?`。
- **验收**(`clj2_string_io_tests`):读 → 打印 → 读回的往返测试,覆盖多字节 UTF-8、emoji 和转义字符;`binding [*out* …]` 能捕获 `println`,在 future 里同样有效;字符串和 char 的分歧都已登记,并引用 03 §7。
- **顺带修正的语言 bug**(与 JVM 不符):
  - 顶层 `(do …)` 改为逐个 form 编译执行,`do` 里的 `require` 对后面的 form 立即生效;命名空间文件里的顶层 `require` 在编译期就执行。
  - reader 把 `\e`/`\f`/`\v`/`\0` 读成控制字符;Clojure 里它们就是该字母本身。
  - 以 0 开头的整数应按八进制读取。
  - `-e`/`eval` 遇到读取错误时会崩溃,现在报 "Syntax error reading source"。
  - `(get "abc" 0)` 改为返回码点。
- **char 表示**(用户决定 2026-10-12):保持整数码点。corpus 中测试字符渲染的 21 行用新增的 `test/corpus-overrides.edn` 改写,每条都要引用已登记的分歧(由 `clj2_divergences_tests:overrides_test` 断言)。其中 12 行把 `(str (char N))` 改成字符串字面量 `"\uNNNN"`,并在 JVM 上验证过结果与原 expected 相同。
- **corpus**:2102 → **2506 / 4842**。`:pending/strings-io` 从 311 降到 4,标准库命名空间从 126 降到 18。
- **验证**:eunit 562 条、`make smoke`、`make docs-check`、`make example`、`make certify`(0 new / 0 stale)全部通过。
