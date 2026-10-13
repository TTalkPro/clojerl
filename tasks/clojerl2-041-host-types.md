# clojerl2-041 宿主类型与方法

状态:已完成(2026-10-13)
里程碑:M6(一致性收尾)
依赖:clojerl2-040

## 目标

清理 `:pending/host-types`(54 条):宿主垫片(`clj2_jvm`)缺的类与成员,以及 deftype/defrecord 声明 JVM 接口。

## 工作内容

- [x] Keyword 的 `.sym`/`.getName`/`.getNamespace`(带不带类型提示都行);`Keyword/find` 接受字符串
- [x] `clojure.lang.Murmur3`(`hashLong`/`hashInt`/`hashUnencodedChars`/`mixCollHash`/`hashOrdered`/`hashUnordered`)、`Util/hashCombine`/`hasheq`/`equiv`;`RT/classForName`、`Class/forName`(未知类抛 ClassNotFoundException)
- [x] 命名字符集(新模块 `clj2_charset`):`(String. bytes [off len] charset)`,UTF-8 坏字节按 JVM 解码器替换(每个最长合法前缀一个 U+FFFD,编码的代理一个,BOM 保留);ISO-8859-1、US-ASCII、windows-1252、UTF-16(BE/LE/BOM)、ISO-2022-JP 的 ASCII 部分;未知字符集抛 UnsupportedEncodingException;`.getBytes` 按字符集编码,结果是有符号字节;`URLEncoder/encode`、`URLDecoder/decode`
- [x] `Thread`:`(Thread. f)` 的 `.start` 在新进程里运行 f(不传递动态绑定,`bound-fn` 才传),`.join`、`.run`、`.isAlive`
- [x] `Executors/newFixedThreadPool` 等:`submit`/`execute`/`invokeAll`/`invokeAny`/`shutdown`;任务的 `.get` 把任务抛出的异常包成 ExecutionException(`.getCause` 是原异常),`.isDone`
- [x] `.iterator` 返回 `java.util.Iterator`(`hasNext`/`next`,走完再 `next` 抛 NoSuchElementException);`iterator-seq` 接受它
- [x] `ArrayList`/`LinkedList` 构造;向量的 `.get` 越界按 JVM 报 "Index 3 out of bounds for length 0"
- [x] `satisfies?` 的第一个参数是类或接口时按 `instance?` 回答
- [x] `(Rec/create m)`:记录类的静态工厂(即 `map->Rec`),小写的记录名也一样
- [x] deftype/defrecord 可以声明不是协议的 JVM 接口(`clojure.lang.IReduceInit`、`ISeq`、`IPersistentVector` ……):方法归在接口名下,`.method` 能调用;接口及其祖先成为类型的超类(`instance?`),扩展到接口的协议能分派到这个类型(类型自己的扩展优先)
- [x] 实现 `ISeq`(`first`/`next`)或 `Seqable` 的 deftype 可以当 seq 用(`seq`/`vec`/`reduce`/`map`/`count` ……);`count` 先用类型自己的 `count` 方法
- [x] 修正:deftype/extend 的方法在命名空间加载期间调用本命名空间的函数(例如方法里构造自己的类型)不再 undef(`clj2_rt:call_loading/3`,经 `'__var__'/1` 取本地函数)
- [x] 改登记:java.io 文件/URL/reader 6 条 → `:host/jvm-classes`;`StringWriter.`/`InputStream` 4 条 → `:pending/corpus-environment`(JVM 的 user 命名空间没有导入它们,corpus 保留的是 jolt 的期望值);`Float/intBitsToFloat`(-0.0、NaN)→ `:number/beam-semantics`;语法引用里 `~*ns*` → `:namespaces/symbols`

## 验收标准

- `make test`、`make certify`、`make cts` 全绿;回归测试 `host_types_test`

## 结论

- 本机门控:eunit 662 全过;corpus 4183 → **4228**/4841(87.3%),0 新失败、0 过期;CTS 不变(5733 / 243 / 388,与基线一致)。
- `:pending/host-types` 清零。剩余待办:runtime-eval 31、core-bugs 20、printer 20、var-surface 18、regex-edge 12、corpus-environment 12 ……
