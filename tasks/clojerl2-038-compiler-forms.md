# clojerl2-038 编译器尚不接受的形式

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-033

## 目标

清理 `:pending/compiler`(149 条)。其中 44 条其实是缺标准库命名空间(clojure.edn/pprint/repl),约 40 条属于别的原因(ref、正则、宿主类、reader),真正的编译器问题约 65 条。

## 工作内容

- [x] `loop*`/`loop` 的初值按顺序求值(多个绑定时先 `let*` 再进循环)
- [x] `apply` 只实现到选定元数所需的元素,可变参数函数拿到惰性的 rest(`(apply concat (repeat [1]))`、`(apply f (range))`);超过 20 个参数的报错按 JVM 写 "(> 20)";`vector`/`hash-map`/`hash-set` 接受带惰性尾部的列表
- [x] 语法引用:`read-string`、`quote` 和嵌套语法引用看到的是 JVM reader 的构造代码(`(clojure.core/seq (clojure.core/concat (clojure.core/list ...)))`、`(clojure.core/apply clojure.core/vector ...)`);`` `` `` 嵌套、`~'~x`(数据形式的 unquote 也是 unquote)、`` ``42 `` 字面量折叠、`nil`/布尔被 quote;`~x` 读作 `(clojure.core/unquote x)`;语法引用里的 `#()` 及其 `%` 参数是 gensym
- [x] `deftype`/`defrecord`:方法参数可以解构;`Object` 的 `toString`/`hashCode`/`equals`(`str`、`hash`、`=` 使用它们);跳过 `:no-print`/`:load-ns` 选项
- [x] `defprotocol` 的选项(`:extend-via-metadata true`)与文档字符串;`defmacro` 的参数解构、开头与结尾的 attr-map(attr-map 的 `:doc` 优先于文档字符串);`defn` 结尾的 attr-map
- [x] `declare` 真正 def 出带 `:declared` 的 var;同一单元里声明让位于后面的 def(不把 fn 变成 cell);REPL 里非 fn 的 var 重定义为 fn 时,var 表里也写上 fn
- [x] `defonce` 只在没有 root 时 def(展开为 `if`,名字上的元数据随之进入 def;宏展开结果里更深处的同名 def 也会带上名字的元数据)
- [x] `conj` 一个 entry 或 map 到 record 上(clojure.walk 保留 record 类型);promise 可以作为函数调用(交付值),`ifn?` 为 true

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `compiler_forms_test`

## 结论

- 本机门控:eunit 655 全过;corpus 3975 → **4047**/4841,0 新失败、0 过期;CTS 5454 → 5455(`ifn?` 全过,基线已重写)。
- `:pending/compiler` 剩 2 条(`defrecord`/`extend-protocol` 写在表达式里——它们在这里是顶层形式)。改登记:43 条 → `:pending/stdlib-namespaces`(clojure.edn/pprint/repl,下一个任务);ref 5 条 → `:refs/no-stm`;接口分派、`Class/.method`、ISeq deftype → `:pending/host-types`;Executor、`#inst`、时区 → `:host/jvm-classes`;正则 2 条 → `:pending/regex-edge`;reader 5 条 → `:pending/reader`;其余各归其位。
