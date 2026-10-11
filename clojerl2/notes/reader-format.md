# clojerl2 Reader 输出契约(Lcore 边界)

> **结论先行**:reader(`clj2_reader`,Erlang)把 Clojure 源码读成带位置包装器的数据树。这份文档是 reader 与编译器(parse pass,designs/01 §1)之间的**唯一契约**;改动任何一条都要同步本文件与 `include/clojerl2.hrl`。

任务:clojerl2-004。实现:`src/erl/clj2_reader.erl`;测试:`test/clj2_reader_tests.erl`(293 用例)。

## 1. API

```erlang
read(Src, Opts)     -> {ok, Form, {Line, Col}, Rest} | {eof, {Line, Col}} | {error, {Line, Col}, Msg}
read_all(Src, Opts) -> {ok, [Form], {Line, Col}} | {error, {Line, Col}, Msg}
strip(Form)         -> term()   %% 递归去掉包装器,容忍裸形式(宏生成)
loc(Form)           -> {Line, Col} | nil
```

- `Src`:`binary() | string() | chardata()`。非 UTF-8 输入报 `{1,1}` 错。
- `Opts`:`#{file => binary()|string()}` 或 proplist;`file` 只用于错误消息前缀(`"f.clj: ..."`),不进入位置。
- `Rest`:未读的余量(**不**吃掉尾部空白)。作为新输入再读时位置从 {1,1} 重计。
- EOF 位置约定:所有输入消费完之后的下一个位置(one-past-end),REPL 续行要用。

## 2. 位置包装器

```erlang
{clj2_loc, Line, Col, Form, Meta}
```

- `Line`/`Col`:1-based;`Col` 按 **Unicode 码点**计(tab=1 列)。
- 每个读出的形式(含集合元素、map 的键与值)都各自带包装器。
- **不变量:`read` 返回的 `{Line,Col}` 恒等于 `loc(Form)`。**
- `^m f`:包装器保留 **f 自身的位置**(`^` 不占位);`read` 返回的位置同上不变量。

## 3. 形式表(strip 后所见)

| 语法 | 形式 |
|---|---|
| `nil` `true` `false` | 同名 atom |
| 整数/浮点 | Erlang integer/float(`123N`、`2r1010N` 等 BIGINT 后缀不产生新类型,BEAM 整数即大整数) |
| 字符串 | UTF-8 binary |
| 字符 | 码点整数(`\newline` → `10`,`\u{1F600}` → 码点) |
| symbol | atom:`foo` → `foo`,`ns/name` → `'ns/name'` |
| **keyword** | **带冒号前缀的 atom**:`:a` → `':a'`,`::a` → `'::a'`(auto-resolve,由展开器解析) |
| 列表 | Erlang list(元素各自带包装) |
| `[...]` | `{vector, [], Items}` |
| `{...}` | `{map, [], [{K, V}]}`,键必须是字面量 |
| `#{...}` | `{set, [], Items}` |
| `1/2` | `{ratio, N, D}`(读时约分交给编译器;`1/0` 读期报错) |
| `1.5M` | `{bigdec, [], Bin}`(BEAM 无 BigDecimal,保留文本) |
| `'f` | `{var, [], StrippedForm}`(quote 的内容不含包装器) |
| `` `f `` | `{syntax_quote, [], StrippedForm}` |
| `~f` / `~@f` | `{unquote, [], StrippedForm}` / `{unquote_splicing, [], StrippedForm}` |
| `@f` | `{deref, [], StrippedForm}` |
| `^m f` | f 的包装器,`Meta` 槽填规范化后的 map(见 §4) |
| `#(...)` | `{fnstar, [], [{arity, [], [{vector, [], Args}, Body]}]}` |
| `#"..."` | `{regex, [], Bin}` |
| `#inst`/`#uuid`/`#tag` | `{tagged, [], Tag, StrippedValue}` |
| `##Inf`/`##-Inf`/`##NaN` | `{tagged, [], 'Inf'|'-Inf'|'NaN', nil}` |
| `#:ns{...}` | `{map, [], Pairs}`,键在 reader 里直接限定:`:a` → `':ns/a'`(symbol 键不加冒号);`#::{...}` 键加 `::` 前缀交给展开器 |
| `#!` | 仅 offset 0 是 shebang(跳过该行);其余位置按 tagged literal 读 |
| `#_` | 丢弃下一个形式(可在集合内使用) |
| `%` `%N` `%&` | `#()` 内:atom `%1`/`%N`/`%&`;`#()` 外报错 |

### `#()` 参数登记

- 裸 `%` **永远是 `%1`**(重复出现指向同一参数,与 JVM Clojure、clojerl 1.0 一致)。
- `%N` 按最大 N 补齐 `%1..%N`;`%&` 放参数表末尾。
- 嵌套 `fn*` 不吞 `%N`(`#(fn* [%1] %1)` 的 `%1` 登记到外层 `#()` 帧)。
- **嵌套 `#()` 允许**,内层帧遮蔽外层(与 JVM 的 "Nested #()s not allowed" 不同,有意保留,记入 known-divergences)。
- `%+`、`%foo` 等非法形式读期报错(与 JVM、clojerl 1.0 一致)。

## 4. Meta 规范(`^m`)

一律规范化为 map 或 `nil`(JVM Clojure 语义):

| 写法 | Meta 槽 |
|---|---|
| `^:a` | `#{':a' => true}` |
| `^sym` | `#{tag => sym}` |
| `^"s"` | `#{tag => <<"s">>}` |
| `^{:a 1}` | 该 map 本身(键值均 strip,keyword 键保持冒号前缀) |
| `^m1 ^m2 f` | 两 map 合并,**外层(先写的)键冲突时优先** |

## 5. 错误

- 形状:`{error, {Line, Col}, Msg}`,`Msg` 为可读 binary(带 `file:` 前缀若给了 `file` 选项)。
- 内容错误(非法数字、非法转义、非字面量 map 键、stray 分隔符等)报在**出错形式的起始位置**;map 非字面量键报在**键的位置**。
- EOF 类错误报在**输入耗尽处**(one-past-end)。
- 集合闭合符不匹配(`(1 2]`)报明确 `unmatched delimiter`。

## 6. 明确不做(读期报错或打标,交给后续阶段)

| 特性 | 行为 |
|---|---|
| `#?` / `#?@` reader conditional | 读期报错(clojerl2 单宿主,无平台分支需求) |
| `#=` read-eval | 读期报错(安全) |
| `*data-readers*` 解析 | `{tagged, [], Tag, Value}` 打标,展开器/驱动查表 |
| BigDecimal 求值 | 保留 `{bigdec, [], Bin}`,运行期库决定 |

## 7. 与 JVM Clojure 的已知差异(known-divergences)

1. 嵌套 `#()` 允许(遮蔽语义),JVM 报错。
2. keyword 在 Lcore 树里是冒号前缀 atom——这是**编译期数据表示**,不是运行期值表示(D8 的运行期 keyword 是另一回事,见 designs/03)。
3. `%` 后接非数字非 `&` 直接报错(同 JVM / clojerl 1.0)。
