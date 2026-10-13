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
| 向量 `[1 2]` | `{vector, nil, {1, 2}}` | 作为参数调用 Erlang 函数时**自动变成 list**(见下文) |
| map `{:a 1}` | **Erlang map** `#{':a' => 1}` | 带元数据时才包一层 `{map, Meta, Map}`,交给 Erlang 时自动去掉 |
| 集合 `#{1}` | `{set, nil, #{1 => nil}}` | |
| 单元数 fn | Erlang fun | 多元数 fn 是 `{clj2_fn, ...}`,见下文 |
| pid、ref、port | 原样 | |

几条由此而来的规则:

- **Erlang atom 写成带引号的符号**:`(erlang/process_info (erlang/self) 'message_queue_len)`。写成 `:message_queue_len` 传过去的是 atom `':message_queue_len'`,Erlang 会报 `badarg`。
- **map 就是 Erlang map**:Clojure 的 `{...}` 与 Erlang 的 map 是同一种值,`get`、`assoc`、`update`、`get-in`、`merge`、`keys`、`count`、`=` 都可以直接用在 Erlang 交来的 map 上,`maps` 模块也可以直接用在 Clojure 的 map 上。
- **调用 Erlang 函数时,参数里的向量自动变成 list**:`(lists/reverse [1 2 3])` 得 `(3 2 1)`。转换是深层的(map、list、tuple 里的向量也会转),惰性序列会被实现成 list,带元数据的 map 去掉包装;没有需要转换的部分原样传过去,不复制。不转换的情况:
  - Erlang 的运算符与 `is_*` 类型判断(`erlang/+`、`erlang/=:=`、`erlang/is_list` ……);
  - clojerl2 运行时自己的模块(`clj2_*`)与标准库(`clojure.*` 命名空间里的调用)。
- **tuple**:Clojure 里没有 tuple 字面量。要构造用 `(erlang/list_to_tuple [a b])`,读取用 `erlang/element`、`erlang/tuple_to_list`;收消息时,`receive` 的向量模式直接匹配 tuple(见下文)。
- **Erlang 交来的 list 仍是 list**,不会变成向量;需要向量时用 `(vec l)`。

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

用 `bound-fn` 包起来交给 `erlang/spawn` 的 fn 会带上调用方的绑定,所以在 `with-out-str` 里这样启动的进程,它的输出同样会被捕获。Erlang 代码里的 `io:format` 写的是进程的 group leader,不经过 `*out*`。

## 进程与消息

并发就是 Erlang 的进程与消息:clojerl2 不提供 atom、agent、future、promise(见 differences)。

```clojure
(defn counter [n]
  (receive
    ['inc]      (recur (inc n))
    ['get from] (do (erlang/send from n) (recur n))
    ['stop]     n))

(let [me  (erlang/self)
      pid (erlang/spawn (fn [] (counter 0)))]
  (erlang/send pid ['inc])
  (erlang/send pid ['get me])
  (receive x x (after 1000 :timeout)))
;=> 1
```

`(receive 模式 表达式 ... (after 毫秒 表达式 ...))` 编译成 Erlang 原生的 `receive`:按顺序试每个模式,第一个匹配的执行;**不匹配任何模式的消息留在邮箱里**(选择性接收)。没有 `after` 时一直等。

| 模式 | 匹配 |
|---|---|
| `[a b]` | 两个元素的 tuple,**或**两个元素的 list(Clojure 发出的向量到了 Erlang 是 list) |
| `{"type" t, :id id}` | 含这些键的 map(键必须是字面量),多余的键不影响 |
| `x` | 任何值,绑定到新的局部量 `x`;同一模式里出现两次要求两处相等 |
| `_` | 任何值,不绑定 |
| `:ok`、`1`、`"s"`、`nil`、`true` | 等于这个字面量 |
| `'ok` | 等于 Erlang atom `ok`(带引号的符号) |
| `~x` | 等于局部量 `x` 当前的值 |

- Erlang 发来的 `{ok, Value}` 用 `['ok v]` 接;Clojure 发出的 `[:ok v]` 用 `[:ok v]` 接。关键字 `:ok` 与 atom `ok` 是不同的值。
- 不支持 `:when` 守卫:需要按条件区分时,先用模式取出,再在表达式里用 `cond`/`case` 判断。
- 单元数的 fn 就是 Erlang fun,可以直接交给 `erlang/spawn`。旧的 `(clj2_proc/receive_any)` 仍可用:按到达顺序取下一条消息。
- 异常的三类(`:error`、`:exit`、`:throw`)都能捕获:

```clojure
(try (erlang/exit 'boom) (catch :exit e [:exit e]))     ;=> [:exit boom]
(try (/ 1 0) (catch Exception e :caught))               ;=> :caught
```

`(throw x)` 抛出的是 Erlang 的 `error`。`ex-info` 的值就是异常原因本身,Erlang 侧 `catch error:R` 拿到的 `R` 是 `{'clojure.lang.ExceptionInfo', nil, #{':message' => ..., ':data' => ...}}`。

注意:动态绑定(例如 `*ns*`)属于设置它的进程,`erlang/spawn` 启动的进程不会自动带上;交给 `spawn` 的 fn 用 `(bound-fn [] ...)` 包一层,就能带上(见 differences)。

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
maps:get(':port', Map).              %% Clojure 的 map 就是 Erlang map
```

- **调用前要先加载**:模块在 code path 上(`rebar3 clojerl2 compile` 或 `clj2_build` 输出到 ebin)时会自动加载,`on_load` 会注册命名空间。clojure.core 用 `clj2_core:ensure()` 加载。
- **调用 fn 值统一用 `clj2_rt:invoke/2`**:多元数 fn 不是 Erlang fun,`F(...)` 会失败,`clj2_rt:invoke` 两种都能调。
