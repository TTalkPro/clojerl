# 上手

## 安装

需要:

- **Erlang/OTP 27 或更新**(在 OTP 28 上开发和测试);
- `make` 和 `git`;
- 可选:`rebar3`(用于 rebar3 项目,见 [rebar3.md](rebar3.md))。

```sh
git clone <本仓库> && cd <仓库>/clojerl2
make          # 编译编译器和运行时,并预编译 clojure.core,产物放在 ebin/
make test     # 可选:跑全部测试
```

之后命令行工具就是 `bin/clojerl2`,可以把 `clojerl2/bin` 加进 `PATH`。

## REPL

```sh
$ bin/clojerl2
clojerl2 9f444ec (Erlang/OTP 28)
Exit: Ctrl-D or :repl/quit
user=> (defn greet [who] (str "你好," who))
#'user/greet
user=> (greet "世界")
"你好,世界"
user=> (map greet ["甲" "乙"])
("你好,甲" "你好,乙")
```

- 一个 form 可以跨多行,读完整了才求值;一行也可以写多个 form。
- `*1` `*2` `*3` 是最近三个值,`*e` 是最近一次异常。
- `(doc map)` 显示 var 的元数和文档,`(dir clojure.core)` 列出命名空间里的 var。clojure.core 的函数目前大多还没有 docstring,`doc` 只能显示元数。
- `def`/`defn`/`defmacro`、`ns`/`in-ns`、`require`、`eval`、`macroexpand` 都可以在 REPL 里用。
- 在终端里有行编辑和历史,历史跨会话保存。
- 退出:Ctrl-D,或输入 `:repl/quit`。

**重定义**:重定义 `f` 之后,直接调用 `(f ...)` 走新版本;之前取走的 fn 值(比如 `(def g f)`)继续运行旧代码。这是 BEAM 的两版本热代码语义,细节和限制见 [differences.md](differences.md) 中的 `:namespaces/hot-code-two-versions`。

**错误报告**:

```
user=> (greet "a" "b")
Syntax error compiling at (REPL:1:1).
Wrong number of args (2) passed to: user/greet
user=> (/ 1 0)
Execution error (error:badarith).
```

编译期发现的错误(未解析的符号、元数不对)在运行前就报告;运行时错误保留 BEAM 的原名(`badarith`、`badarg` ……)。

## 运行代码

```sh
bin/clojerl2 -e '(+ 1 2)'                 # 求值并打印每个非 nil 的结果
bin/clojerl2 script.clj a b               # 逐个 form 求值脚本;*command-line-args* 为 ("a" "b")
bin/clojerl2 -p src -m my.app x y         # 从源码路径 require my.app,调用 (my.app/-main "x" "y")
```

- **源码路径**(`require` 在哪里找命名空间):`-p dir1:dir2`,或环境变量 `CLJ2_PATH`,默认是 `src:.`。命名空间 `my.app-util` 对应 `my/app_util.clj`(或 `.cljc`)。
- **退出码**:未捕获的异常时为 1,并把错误报告写到 stderr。

一个程序的样子:

```clojure
;; src/my/app.clj
(ns my.app
  (:require [my.util :as u]))

(defn -main [& args]
  (println "参数:" (vec args))
  (println (u/shout "hello")))
```

```clojure
;; src/my/util.clj
(ns my.util)
(defn shout [s] (str s "!"))
```

```sh
$ bin/clojerl2 -p src -m my.app 1 2
参数: [1 2]
hello!
```

参数都是字符串:`println` 打印时不带引号,所以显示为 `[1 2]`;用 `prn` 打印会显示 `["1" "2"]`。

## 下一步

- 与 Erlang 互操作:[erlang-interop.md](erlang-interop.md)
- 用 rebar3 管理项目:[rebar3.md](rebar3.md)
- 从 JVM Clojure 迁移时要注意的差异:[differences.md](differences.md)
