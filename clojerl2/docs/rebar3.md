# rebar3 项目

## 项目设置

clojerl2 项目是普通的 rebar3 项目:依赖 `clojerl2`(运行时和编译器),并启用插件 `rebar3_clojerl2`。

```erlang
%% rebar.config
{deps, [{clojerl2, {git_subdir, "<本仓库 URL>", {branch, "master"}, "clojerl2"}}]}.
{plugins, [{rebar3_clojerl2, {git_subdir, "<本仓库 URL>", {branch, "master"}, "clojerl2/rebar3_clojerl2"}}]}.

{clj2_src_dirs, ["src"]}.     %% 命名空间放在哪里(默认 ["src"])
{clj2_mode, dev}.             %% dev(默认)| release(额外做内联)
```

```erlang
%% src/hello.app.src
{application, hello,
 [{vsn, "0.1.0"},
  {applications, [kernel, stdlib, clojerl2]}]}.
```

命名空间放在 `src/` 下:`hello.core` 对应 `src/hello/core.clj`。

> 上面的 `git_subdir` 写法还没有在推送后的仓库上实测过。已经验证过的是本地 `_checkouts` 方式,见下一段。

本仓库里的示例 `clojerl2/examples/hello` 通过 `_checkouts` 链接到本地的 clojerl2 和插件,`make example` 会建立链接并把三个命令都跑一遍。

## 命令

命令面与 clojerl 1.0 的 rebar3_clojerl 一致,命名空间换成 `clojerl2`:

```sh
rebar3 clojerl2 compile   # 编译项目的命名空间,写入 _build/<profile>/lib/<app>/ebin
rebar3 clojerl2 repl      # 先 compile,再开 REPL;可以 require 项目里的命名空间
rebar3 clojerl2 clean     # 删除编译缓存和构建出的模块
```

```
$ rebar3 clojerl2 compile
===> clojerl2 hello: 3 compiled, 0 cached (1218 ms)
$ rebar3 clojerl2 compile
===> clojerl2 hello: 0 compiled, 3 cached (143 ms)
```

除了项目自己的 app,配置了 `clj2_src_dirs` 的依赖也会被构建。命名空间之间的 `:require` 决定编译顺序,循环依赖会报错。

## 编译缓存

缓存放在 `_build/<profile>/clojerl2_cache/`,以命名空间为单位。一个命名空间直接从缓存取的条件是以下都没变:

- 它的源码;
- 编译器和 clojure.core;
- OTP 主版本;
- 编译选项;
- **它 require 的每个命名空间的接口**:各 var 的种类、元数、`dynamic`/`private` 标记,以及宏的代码。

这意味着:

| 你改了 | 会重新编译 |
|---|---|
| 某个命名空间里函数的函数体或 docstring | 只有它自己 |
| 某个函数的元数,或某个宏 | 它自己,以及 require 它的命名空间 |
| 新命名空间里对已有协议 `extend-type` 新类型 | 只有新命名空间 |
| 升级 clojerl2 或 OTP | 全部 |

宏展开时如果调用了**另一个命名空间**的函数,那个函数改了不会触发重新编译。遇到这种情况,执行一次 `rebar3 clojerl2 clean`。

**实测**:40 个命名空间的项目,命中缓存时 clojerl2 部分的耗时约为首次的 8%。整条 `rebar3` 命令约为 18–24%,其中约 0.7 秒是 rebar3 自身的固定开销。

## 不用 rebar3 的构建

插件只是 `clj2_build` 的一层壳,也可以直接调用:

```erlang
clj2_build:build(#{src_dirs => ["src"], ebin_dir => "ebin", cache_dir => "_build/clj2_cache"}).
%% => #{compiled => [...], cached => [...], removed => [...], ms => ...}
```

## 已知限制

- 生成的 `.app` 文件的 `modules` 列表里没有 clj2 模块。用 relx 打 release 时,需要手动补上。
- rebar3_clojerl 的 `escriptize`/`release`/`run`/`test` 还没有对应的命令。
