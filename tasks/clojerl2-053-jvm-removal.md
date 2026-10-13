# clojerl2-053 删除 Java 类垫片,只留语言自身用到的互操作

状态:已完成(2026-10-14)
里程碑:M7
依赖:clojerl2-050、052

## 工作内容

- [x] `clj2_jvm` 只留:deftype/defrecord 的方法与字段(`__extmap`/`__meta`、`(Rec. ...)`),异常的构造与方法,BigDecimal
  (`BigDecimal.`、方法、`MathContext`、`RoundingMode`),作为 writer 的 io 设备(`.write`/`.append`/`.flush`/`.toString`),
  任何值的 `toString`/`equals`/`hashCode`,`(Object.)`
- [x] 删除:String 与 StringBuilder 方法,Math/StrictMath,Integer/Long/Double/Short/Byte/Character/Boolean 的静态成员,System,
  Thread/Executors/FutureTask,UUID/Random/Objects 类,Iterator 与 Java 集合方法,StringWriter/StringReader 构造器、File 字段,
  字符集与 URLEncoder/URLDecoder(`clj2_charset`),Keyword/Symbol/Var/RT/Murmur3/Util/Numbers 的成员,Java 数组
  (`clj2_array`,`long-array`/`aget`/`into-array`/`make-array`/`amap`/`bytes?` ……),`iterator-seq`
- [x] `clojure.math` 改由 `clj2_math:call/2` 实现;`parse-double` 用 `clj2_math:parse_double/1`;`bound?` 用 `clj2_var:is_bound/1`;
  pprint 的 Java 调用改成 `clojure.string`、Erlang 函数和进程内的字符串缓冲;`clojure.repl/demunge` 不再走 `Compiler`
- [x] `#inst` 读作 Erlang 时间(毫秒整数);`Inst` 扩展到整数。新登记差异 `:host/inst-millis`,`:host/jvm-classes` 改写为新范围

## 结论

eunit 672 全过。corpus 3948 / 4841:新失败 194 条,都是用例源码里用了被删除的 Java 特性,登记到 `:host/jvm-classes`(188)和
`:host/inst-millis`(6)。CTS 通过 4800 / 失败 181 / 错误 419,基线已重写:24 个命名空间在顶层用了 `to-array`/`int-array`,
整个文件编译不过;`edn-test.read-string` 的 `#inst` 断言用了 `.getTime`。docs-check 通过。
