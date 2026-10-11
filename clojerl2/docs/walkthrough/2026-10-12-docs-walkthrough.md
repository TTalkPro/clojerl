# 文档走查记录 2026-10-12(clojerl2-025)

**走查人**:Claude(开发助手),**不是**外部试用者。真实用户的试用尚未进行,见文末"待办:真实用户试用"。

**方法**:从一份干净拷贝开始,模拟新克隆的仓库:没有 `ebin/`、`_build/`、`_checkouts/`,也没有预编译的 core。逐字照着 `docs/` 的步骤做,不看源码,不用文档没写的命令。环境:Linux,Erlang/OTP 28,rebar3 3.24。

## 步骤与结果

| # | 文档 / 步骤 | 结果 |
|---|---|---|
| 1 | getting-started「安装」:`make` | 通过,9 秒,ebin 下 35 个模块,含预编译的 clojure.core |
| 2 | getting-started「REPL」:greet、`map`、`*1`、`doc`、`dir`、两个错误示例、`*e` | 通过,输出与文档一致(中文正常);`doc` 的问题见 W2 |
| 3 | getting-started「运行代码」:`my.app`/`my.util` 两个文件,`-p src -m`、脚本参数、`CLJ2_PATH`、默认源码路径 | 都能运行;`println` 的输出与 JVM 不同,见 W3 |
| 4 | erlang-interop:全部 `;=>` 示例,外加 spawn/receive 和从 Erlang 调用 Clojure | 示例全部一致;为写这一页做探查时发现 W4、W7 |
| 5 | rebar3:`make example`(compile 两次、repl、clean) | 通过 |
| 6 | rebar3.md:照文档的 `rebar.config` 和 `.app.src` 从零新建项目,compile 后在 repl 里调用 | 通过 |
| 7 | differences:逐条核对替代写法里的代码 | 发现 3 处不能运行或不准确,已改,见 W8 |

## 发现与处理

| 编号 | 级别 | 发现 | 处理 |
|---|---|---|---|
| W1 | 轻微 | 不在 git 仓库里构建时,`--version` 显示 `dev` | 符合预期:构建戳取自 `git describe`,真实克隆会显示提交号 |
| W2 | 文档 | `(doc map)` 只显示元数:297 个公开 core var 中只有 5 个有 docstring | getting-started 已如实说明;补 docstring 是 core 的后续工作 |
| W3 | **缺陷** | `print`/`println` 打印集合时,里面的字符串带了引号,`(println ["1"])` 显示 `["1"]`,JVM 显示 `[1]` | **已修**:`clj2_print` 加了 readably 参数;corpus 里 2 条因此通过;冒烟测试原来的期望值是错的,一并改正 |
| W4 | **阻塞**(互操作) | Clojure 代码收不到消息:`receive` 是 Erlang 语法而不是函数,`receive*` 特殊形式还没做 | **已补过渡方案**:`clj2_proc:receive_any/0,2`,按到达顺序取下一条消息,可设超时;文档写明不支持选择性接收。`receive*` 仍是后续工作 |
| W5 | **缺陷** | `(nth "abc" 1)` 抛出越界异常,字符串不支持 `nth` | **已修**:按码点取值,O(n),登记为 `:string/code-point-indexing` |
| W6 | **缺陷**(与设计不符) | `ref`/`dosync` 是未解析符号;designs/03 §5.2 要求抛出说明清楚的错误 | **已修**:7 个函数和宏都抛 ex-info,登记为 `:refs/no-stm` |
| W7 | 限制 | Erlang 的 map/tuple 在 Clojure 里不透明,`get`/`count` 不认 | erlang-interop 写明限制和变通写法;直接支持是后续工作 |
| W8 | 文档 | 替代写法里的代码有 3 处问题:`(unicode/characters_to_binary [c])` 传了向量(Erlang 要的是 list);推荐了还不存在的 atom;arity 的写法不明确 | 已改为能运行的写法,并逐条实测 |
| W9 | 登记表 | `(= 0.0 -0.0)` 为 false、`##NaN` 读不进来,都没有登记 | 已并入 `:number/beam-semantics` |
| W10 | 登记表 | 43 条元数编译错误中,有 42 条其实是 clojure.core 缺少该元数(transducer 形式等),之前被算成了 `:fn/arity-at-compile-time` | 改回 `:pending/missing-core-var`;只有用户自定义函数的才算这条差异 |
| W11 | 文档 | rebar3.md 里的 `git_subdir` 依赖写法没有在推送后的仓库上验证过 | 文档已标明未实测;验证过的是 `_checkouts` 方式 |

阻塞级发现都已修复或有过渡方案(W3–W6),非阻塞的都已写进文档(W2、W7、W11)。

## 待办:真实用户试用

本任务的验收要求有真实用户试用。这一步需要你邀请试用者,我无法代劳。建议的走查路径(约 30 分钟):

1. 克隆仓库,按 `clojerl2/docs/getting-started.md` 执行 `make`,打开 REPL,把文档里的每个例子都输入一遍。
2. 照 `getting-started.md` 写一个两个命名空间的小程序,用 `-m` 运行。
3. 照 `rebar3.md` 新建一个 rebar3 项目,执行 compile 和 repl。
4. 挑一个熟悉的 Clojure 小程序(100 行以内)移植过来,对照 `differences.md` 记录遇到的每个差异,看文档里有没有。
5. 记录:卡住的地方、看不懂的说明、文档没覆盖到的差异。写到本目录,文件名格式为 `YYYY-MM-DD-<试用者>.md`。

## designs/05、06 读者的走查

任务里原来有一项"05/06 号文用户(IronScheme 文档受众)走查记录归档",**不适用**:
- 05(ERTS 作为目标平台)是 IronScheme 系列的提案,未立项;
- 06 已作废,由 07 的 Scheme 层路线取代,而 07 又在 2026-10-11 作废。

编译器最终用 Erlang 实现(designs/09),没有面向 Scheme 层读者的产物,因此没有可走查的对象。
