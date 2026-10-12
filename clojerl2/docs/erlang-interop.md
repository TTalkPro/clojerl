# 与 Erlang/OTP 互操作

clojerl2 编译出的就是普通 BEAM 模块,互操作没有额外的桥接层:Clojure 调用 Erlang 是直接的函数调用,Erlang 调用 Clojure 也一样。

## 从 Clojure 调用 Erlang

`(模块/函数 参数 ...)` 就是 `模块:函数(参数, ...)`:

```clojure
(erlang/self)                         ;=> #object[pid <0.85.0>]
(lists/seq 1 5)                       ;=> (1 2 3 4 5)
(string/uppercase "abc")              ;=> "ABC"
(timer/sleep 100)                     ;=> ok
(ets/new 'cache (list 'set 'public))  ;=> #Ref<...>
```

这里的 `ok` 是 Erlang atom `ok`,打印出来和 Clojure 的符号 `ok` 一样,因为两者就是同一个值(见下表)。

## 值的对应

| Clojure | Erlang | 注意 |
|---|---|---|
| `nil` `true` `false` | atom `nil` `true` `false` | Erlang 的 `undefined` 不是 `nil` |
| 整数、浮点数 | integer、float | 整数无界;没有 ratio 运算(见 differences) |
| 字符串 `"中文"` | UTF-8 binary `<<"中文"/utf8>>` | 见下文"字符串与字符列表" |
| 字符 `\a` | 整数 97(码点) | 没有单独的 char 类型 |
| 符号 `'ok` | atom `ok` | **Erlang atom 用带引号的符号写** |
| 关键字 `:ok` | atom `':ok'` | 关键字带着冒号,**不是** Erlang 的 `ok` |
| 列表 `'(1 2)`、`(list 1 2)` | list `[1, 2]` | 可以直接传给 `lists` 模块 |
| 向量 `[1 2]` | `{vector, nil, {1, 2}}` | **不是** Erlang list,也不是普通 tuple |
| map `{:a 1}` | `{map, nil, #{':a' => 1}}` | **不是** Erlang map |
| 集合 `#{1}` | `{set, nil, #{1 => nil}}` | |
| 单元数 fn | Erlang fun | 多元数 fn 是 `{clj2_fn, ...}`,见下文 |
| pid、ref、port | 原样 | |

几条由此而来的规则:

- **Erlang atom 写成带引号的符号**:`(erlang/process_info (erlang/self) 'message_queue_len)`。写成 `:message_queue_len` 传过去的是 atom `':message_queue_len'`,Erlang 会报 `badarg`。
- **向量和 map 要转换后才能交给 Erlang**:
  - 列表:`(seq v)` 或 `(apply list v)`;
  - tuple:`(erlang/list_to_tuple (seq v))`;
  - 反方向:`(vec erlang-list)`,`(vec (erlang/tuple_to_list t))`。
- **Erlang 的 map 在 Clojure 里是不透明的值**:`get`/`count`/`seq` 不认它,要用 `maps` 模块,例如 `(maps/get 'port m)`、`(maps/to_list m)`。Erlang tuple 同理,用 `erlang/element`、`erlang/tuple_to_list`。直接把 Erlang map/tuple 当 Clojure 集合用,目前还不支持。

## 字符串与字符列表

Clojure 字符串是 **UTF-8 binary**。Erlang 里还有字符列表(charlist),列表里每个元素是一个 Unicode 码点,中文也能表示。两者转换**必须**经过 `unicode` 模块:

```clojure
(unicode/characters_to_list "中文")      ;=> (20013 25991)   码点列表
(unicode/characters_to_binary (list 20013 25991))  ;=> "中文"
```

不要用 `erlang/binary_to_list` 或 `erlang/list_to_binary` 处理文本:前者把 UTF-8 拆成字节,后者遇到大于 255 的码点直接报错。输出时 `io:format` 要用 `~ts`,不能用 `~s`:

```clojure
(io/format "~ts~n" (list "中文"))
```

## 输入输出:`*out*`、`*err*`、`*in*`

`*out*`、`*err*`、`*in*` 是动态 var,值就是 Erlang 的 io 设备:`standard_io`、`standard_error`,或者任何实现了 io 协议的进程。打印函数写到 `*out*`,`read-line` 从 `*in*` 读,所以重绑定就能重定向:

```clojure
(with-out-str (println "中文"))                      ;=> "中文\n"
(binding [*out* *err*] (println "写到标准错误"))
(let [w (clj2_io/string_writer)] (binding [*out* w] (print "captured")) (clj2_io/contents w))  ;=> "captured"
```

future 和 agent 的动作会带上调用方的绑定,所以在 `with-out-str` 里启动的 future,它的输出同样会被捕获。Erlang 代码里的 `io:format` 写的是进程的 group leader,不经过 `*out*`。

## 进程与消息

单元数的 fn 就是 Erlang fun,可以直接交给 `spawn`:

```clojure
(let [me (erlang/self)]
  (erlang/spawn (fn [] (erlang/send me [:hello "世界"])))
  (clj2_proc/receive_any 1000 :timeout))
;=> [:hello "世界"]
```

- `(clj2_proc/receive_any)` 一直等下一条消息;`(clj2_proc/receive_any 毫秒数 默认值)` 超时返回默认值。
- 消息按到达顺序取,不支持选择性接收。要按内容分派,先取出再用 `case`/`cond` 判断。带模式匹配的 `receive*` 特殊形式还在计划中。
- 异常的三类(`:error`、`:exit`、`:throw`)都能捕获:

```clojure
(try (erlang/exit 'boom) (catch :exit e [:exit e]))     ;=> [:exit boom]
(try (/ 1 0) (catch Exception e :caught))               ;=> :caught
```

`(throw x)` 抛出的是 Erlang 的 `error`。`ex-info` 的值就是异常原因本身,Erlang 侧 `catch error:R` 拿到的 `R` 是 `{'clojure.lang.ExceptionInfo', nil, #{':message' => ..., ':data' => ...}}`。

注意:动态绑定(例如 `*ns*`)属于设置它的进程。`future` 和 agent 会自动带上调用方的绑定,`erlang/spawn` 不会;交给 `spawn` 的 fn 用 `(bound-fn [] ...)` 包一层,就能带上(见 differences)。

## 从 Erlang 调用 Clojure

命名空间 `demo.api` 就是模块 `'demo.api'`,var 就是模块里的函数:

```clojure
(ns demo.api)
(defn greet [who] (str "hello, " who))
(defn total [& xs] (reduce + 0 xs))
(def limit 10)
(defn adder [n] (fn [x] (+ x n)))
```

```erlang
'demo.api':greet(<<"世界"/utf8>>).    %% <<"hello, 世界"/utf8>>
'demo.api':total([1, 2, 3]).          %% 6     剩余参数作为一个列表传入
'demo.api':total(nil).                %% 0     没有剩余参数时传 nil
'demo.api':limit().                   %% 10    值 var 是零元函数
F = 'demo.api':adder(5), F(1).        %% 6
clj2_rt:invoke(F, [1]).               %% 6     对任何 fn 值都可用
clj2_coll:get(Map, ':port').          %% 读 Clojure map
```

- **调用前要先加载**:模块在 code path 上(`rebar3 clojerl2 compile` 或 `clj2_build` 输出到 ebin)时会自动加载,`on_load` 会注册命名空间。clojure.core 用 `clj2_core:ensure()` 加载。
- **调用 fn 值统一用 `clj2_rt:invoke/2`**:多元数 fn 不是 Erlang fun,`F(...)` 会失败,`clj2_rt:invoke` 两种都能调。
