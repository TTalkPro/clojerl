# 在 Erlang 应用里嵌入 clojerl2

clojerl2 可以作为 Erlang 应用里的 **可热加载的 DSL 与规则引擎**:应用在运行时拿到一段 Clojure 源码(来自配置、数据库、
管理界面),编译成 BEAM 模块并加载,按函数名调用;源码改了再加载一次,不停机。设计见 `designs/10-embedded-dsl.md`。

## 快速开始

```erlang
ok = clj2:ensure(),                                   %% 启动运行时、加载 clojure.core(幂等)
{ok, 'rules.demo'} = clj2:load(<<"
  (ns rules.demo (:require [clojure.string :as str]))
  (defn classify [req]
    (cond (> (count (get req \"messages\")) 10) :long
          (re-find #\"(?i)test\" (get req \"prompt\" \"\")) :tests
          :else :default))">>),
{ok, ':tests'} = clj2:call('rules.demo', classify, [#{<<"messages">> => [], <<"prompt">> => <<"write tests">>}]).
```

| 函数 | 作用 |
|---|---|
| `clj2:ensure()` | 启动运行时并加载 clojure.core |
| `clj2:load(Src)` / `load(Src, Opts)` | 编译并加载一个命名空间(源码第一个形式是 `ns`),返回 `{ok, Ns}`;再次加载同名命名空间即热替换。`Opts`:`file`(报错里显示的文件名)、`versioned`(见下文) |
| `clj2:call(Ns, Fn, Args)` | 调用命名空间里的函数,`Fn` 可以是 atom 或 binary,返回 `{ok, Value}` |
| `clj2:eval(Src)` / `eval(Src, #{ns => Ns})` | 求值一段源码,返回最后一个形式的值 |
| `clj2:unload(Ns)` | 删除命名空间及其模块(包括所有版本) |
| `clj2:gc()` / `gc(Ns)` | 回收版本化命名空间里已经没有进程在用的旧版本 |
| `clj2:module(Ns)` | 命名空间对应的模块;性能敏感处可以直接 `M:Fn(...)` 调用 |

错误不抛异常,以数据返回:

```erlang
{error, #{kind := read | syntax | load | runtime,   %% 读错误、编译错误、加载失败、运行时异常
          message := binary(),                      %% 可直接展示给用户的说明
          line => pos_integer(), column => pos_integer(),
          reason := term()}}                        %% 原始原因
```

## 数据:宿主的数据原地使用

宿主的数据通常是 Erlang 原生 term(JSON 解码后是 map、binary、list、`null`)。Clojure 代码可以直接操作它们:

- **Erlang map 就是 Clojure map**:`get`、`assoc`、`dissoc`、`update`、`get-in`、`assoc-in`、`update-in`、`keys`、`vals`、`seq`、
  `count`、`contains?`、`merge`、`select-keys`、`reduce-kv`、`map?`、`=`,以及把 map 当函数用 `(m "k")`。修改 Erlang map
  得到的仍是 Erlang map,交还宿主不需要转换。
- **字符串是 binary**,`clojure.string` 与正则直接可用。
- **JSON 数组是 Erlang 列表**:序列函数直接可用;`get`/`get-in` 也接受下标,`(get-in body ["messages" 0 "content"])`
  (与 JVM 不同,见 differences.md `:collections/list-index-get`)。
- **键保留原样**:JSON 的键是 binary,就写 `"model"`;不会转成关键字,不产生新的 atom。
- **`null`** 是 atom `null`,在 Clojure 里是符号 `'null`,不是 `nil`。

Clojure 代码用字面量和函数新建的值是 Clojure 自己的结构(`[...]` 是 vector、`{...}` 是 Clojure map、`:k` 是关键字)。
要交给只认 Erlang term 的宿主(例如 JSON 编码器)时,在边界上转换一次:

```erlang
clj2_data:to_erl(V)                    %% vector、set、seq → list;Clojure map → map;:k → <<"k">>
clj2_data:to_erl(V, #{nil => null})    %% 另把 nil 转成 null
clj2_data:from_erl(T, #{keys => keyword, null => nil, lists => vector})   %% 反方向
```

在 Clojure 里是 `(clj->erl x)`、`(clj->erl x {:nil :null})`、`(erl->clj x {:keys :keyword})`。只改动宿主 map 里的
字段、值仍是 binary / 数字 / Erlang map 时,不需要转换。

## 热替换

`clj2:load/1` 再次加载同名命名空间时,新代码替换旧代码:之后的调用走新版本,正在执行的调用在旧版本上跑完。
这是 BEAM 的两版本代码模型:每个模块同时最多两个版本,**如果还有进程停在"旧版本"里,再次加载会失败**
(`{error, #{kind := load, reason := {old_code_in_use, _}}}`)。

规则会频繁修改、而调用可能持续很久(例如一条持续几分钟的流式请求)时,用 **版本化加载**:

```erlang
{ok, Ns} = clj2:load(Src, #{versioned => true}),   %% 每次编译成独立的模块 <ns>$v<N>
...
clj2:gc().                                          %% 定期回收没有进程在用的旧版本
```

版本化的命名空间通过 `clj2:call/3`(或 `clj2:module(Ns)` 取当前模块)调用;其他命名空间里直接引用它的函数,
会停在编译那一刻的版本上,所以版本化适合作为"叶子":宿主调用它,它不被别的 Clojure 代码直接引用。

## 性能

`make bench` 的结果(本机,单次调用的中位数):

| 场景 | 每次 |
|---|---|
| 直接调用 `M:noop/1` | 0.02 µs |
| `clj2:call/3`(按名字查找) | 0.44 µs |
| 流式事件:`get-in` 取文本 + `str/includes?` | 0.50 µs |
| 请求改写:换模型名 + 加一条系统消息(20 条消息) | 0.09 µs |
| 规则:`count` + 正则 + 多方法 | 0.75 µs |
| `clj2_data:to_erl` 转换改写后的请求 | 1.7 µs |

热路径上用 `clj2:module(Ns)` 取模块后直接调用,可以省掉按名字查找的开销(热替换不受影响:模块名不变)。
版本化命名空间的模块名随版本变化,要在每次加载后重新取。

## 安全

脚本可以调用任意 Erlang 函数(`(erlang/halt)`、`(file/delete ...)`),与宿主自己的代码同等权限。是否允许、允许谁提交脚本,
由宿主决定。运行时间与内存的限制也由宿主施加(例如在独立进程里调用、设 `max_heap_size`、超时即结束进程)。

## 示例:一个规则引擎

```clojure
(ns rules.gateway
  (:require [clojure.string :as str]))

(def blocked-words #{"password" "secret"})

(defn text-of [body]
  (str/join " " (keep #(get % "content") (get body "messages"))))

(defmulti on-request (fn [body ctx] (get ctx :format)))

(defmethod on-request :default [body ctx]
  (cond
    (some #(str/includes? (str/lower-case (text-of body)) %) blocked-words)
    [:reject 403 "blocked"]

    (= "gpt-4" (get body "model"))
    [:ok (assoc body "model" "gpt-4o")]

    :else :continue))
```

宿主约定返回值的形状(这里是 `[:reject 状态 消息]`、`[:ok 新请求体]`、`:continue`),调用后用 `clj2_data:to_erl/1`
或按需匹配。
