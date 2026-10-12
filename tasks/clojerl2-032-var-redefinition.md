# clojerl2-032 var 的运行时重定义:嵌套 def、with-redefs、alter-var-root

状态:已完成(2026-10-12)
里程碑:M6(一致性收尾)
依赖:clojerl2-015, clojerl2-022

## 目标

fn var 是直接链接的(调用方编成 `M:f(...)`),所以"运行时换掉 var 的值"要单独设计。本任务把嵌套 def、同一文件里重复的顶层 def、`alter-var-root`、`with-redefs`/`with-redefs-fn` 统一到一个机制上:**一个 var 一旦要在运行时被改值,就让它的值住进 var 表(cell),以后每次改值只写一次 ETS**,最多换一次代码。

## 设计依据

- [03](../designs/03-runtime-model.md) §2.1a 直接链接、§2.2 两版本语义、§2.3 var 表
- [09](../designs/09-erlang-hosted-compiler.md) §2 var 的编译形态(fn / const / cell / indirect)

## 现状问题(2026-10-12 实测)

1. REPL 里嵌套 `def` 一个 fn var,每次都重新编译加载一个转发模块:200 次 1742 ms(约 9 ms 一次);同样写法换成 cell var 0.09 ms。
2. 有进程停在旧代码里时,第二次重定义失败(`old_code_in_use`)。
3. `(def held f)` 之后再嵌套重定义 `f`,`held` 跟着变(JVM:`held` 是当时那个 fn)。
4. 文件被 `defmacro` 切成编译期段时,后一段里嵌套 `def` 提升出的声明遮住前一段已定义的同名 var,在嵌套 def 执行前读到未绑定(`demo.d`)。
5. 同一编译单元里两次顶层 `def` 同名 var 报 `duplicate_def`(JVM 允许,后者覆盖前者)。
6. `alter-var-root`、`with-redefs`、`with-redefs-fn`、var 的 watch/validator、`locking` 未实现(corpus `:pending/ref-types` 13 条)。

## 工作内容

- [x] 编译:cell var 在值位置直接读 var 表(`clj2_var:root/2`),不经访问器——转发模块里的 `f/0` 不再与访问器冲突
- [x] 运行时转换一次:fn var 第一次被运行时改值时装一个转发模块(旧调用方的 `f/N` 转去读 root),登记为 cell(`redirected`);之后的嵌套 def / 顶层 def 都只是 `set_root`
- [x] 编译期段:提升的声明遇到前面段已定义的同名 var 时,以那个 var 的当前值为初值
- [x] 同一单元重复的顶层 def:第二次起变成对 root 的赋值,var 编成 cell
- [x] 同一单元里被 `alter-var-root` / `with-redefs-fn` 取 `(var x)` 的 var 编成 cell
- [x] `alter-var-root`、`with-redefs-fn`、`with-redefs`;var 的 `add-watch`/`set-validator!`(root 变化时通知、校验);`var-set` 先跑 validator
- [x] `locking`(BEAM 上值没有监视器:求值锁对象,执行主体;`recur` 穿过 `locking` 报编译错误,与 JVM 一致)
- [x] 已加载的命名空间模块里的 var(跨命名空间 `with-redefs`):给模块换一次版本,所有 fn/const var 改读 root,去掉 on_load 重跑
- [x] clojure.core 的 var:直接链接,不支持运行时改值——登记差异

## 验收标准

- 上面 1–5 各有回归测试;嵌套重定义 200 次耗时与 cell var 同量级;有进程停在旧代码时连续重定义不失败
- corpus `:pending/ref-types` 清零(core var 的 2 条转为登记差异)
- `make test`、`make certify`、`make cts` 全绿(远端 `ssh -p 3022 david@192.168.2.7`)

## 结论

- **机制**:var 的值一旦要在运行时改,就搬进 var 表(cell),只换一次代码;以后每次改值只写一次 ETS。
  - 编译:cell var 在值位置直接读 `clj2_var:root/2`(`clj2_p_link`),不经访问器。
  - REPL 定义的 var(独占模块 `<ns>$v$<name>`):fn 换成转发模块,`Name/N` 读表后调用;常量的访问器改读表(`clj2_rt_eval:redirect_var`)。
  - 命名空间模块里的 var:从 debug_info 取 absform,所有 fn/常量 var 一次改完——原函数体改名 `Name$orig/N`(自调用留在体内),`Name/N` 转发,访问器读表,`'__fn__'/1` 读表,on_load 置空;加载时的 beam 存在 `clj2_beam` 表里(`redirect_module`)。
  - 统一入口 `clj2_rt:set_var_root/2`:先跑 validator,写表,再通知 watch;`def_root`、`alter-var-root`、`with-redefs-fn` 都走它。写表前把"指向本 var 自己转发函数"的值换回原函数体(`root_value/3`),`alter-var-root`/`with-redefs-fn` 先转换再读旧值,所以 `(alter-var-root #'f memoize)` 这类包旧值的写法不会绕回自己。
  - 已转换的 var 再遇到 REPL 顶层 `def`(或带 watch/validator 的 var)时只做赋值。
  - 编译单元内:重复的顶层 `def` 从第二次起变成赋值;被 `alter-var-root`/`with-redefs-fn` 取 `(var x)` 的 var 直接编成 cell;编译期段里提升的声明遇到前段已定义的同名 var,以其当前值为初值并放在段首(`clj2_p_declare`)。
  - 新增:`alter-var-root`、`with-redefs-fn`、`with-redefs`、var 的 `add-watch`/`remove-watch`/`set-validator!`/`get-validator`、`var-set` 先跑 validator、`set!` 作用于 var(`*warn-on-reflection*`/`*unchecked-math*` 没有绑定时也可 `set!`)、`locking` 展开为 `try/finally`(`recur` 穿过它报错,与 JVM 一致)。
- **实测**(问题 1–5 的回归测试在 `clj2_stdlib_tests`):200 次嵌套重定义 1742 ms → 7 ms;进程停在旧代码里时连续重定义正常;`held` 保持旧 fn;`demo.d` 输出 `[2 2]`;重复顶层 def 得到后一个值;跨命名空间 `with-redefs` 在执行期间对模块内部调用生效,结束后恢复。
- **门控**(远端 `make test` / `make certify` / `make cts`):eunit 641 全过;corpus 3692 → **3715**/4841,0 新失败,`:pending/ref-types` 清零;CTS 断言通过 4874 → 4882,失败/错误数不变。
- **新登记的差异**(各有佐证测试,`differences.md` 已同步,共 27 条):
  - `:vars/core-direct-linked`:clojure.core 的 fn/常量 var 不能在运行时改值(corpus 2 条);
  - `:vars/self-calls-direct`:命名空间模块里 fn 对自己的调用不经过 var。
  另修订 `:namespaces/hot-code-two-versions`:运行时改值的 var 不再受两版本限制。
- **顺带看到、未处理**(留在 triage):编译期段的顶层副作用会在正式模块加载时再执行一次;宏展开期间嵌套 def 的副作用不带进正式模块;ns 初始化期间经 var 对象读同一模块的 var 会 `undef`;CLI 打印含非 latin1 字节的错误信息时 `io:put_chars` 报 badarg。
