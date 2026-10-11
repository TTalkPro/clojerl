# clojerl2-024 rebar3 插件与编译缓存

状态:已完成(2026-10-12;M5 判据见结论:clojerl2 阶段 7–8%,整条 rebar3 命令 18%/23.5%)
里程碑:M5
依赖:clojerl2-023

## 目标

实现 rebar3 插件与编译缓存:缓存键覆盖源、编译器版本、OTP 主版本与选项指纹;provider 提供 compile/repl/clean。

## 设计依据

- [02](../designs/02-beam-backend.md) §6 — 缓存键:`sha256(源文本) + 编译器版本 + OTP 主版本 + 编译选项指纹`;产物为 .beam 二进制,命中跳过整条管线
- [02](../designs/02-beam-backend.md) §6 — 粒度 NS 级;extend 只新增 impl 模块,不触发 NS 重编译(D9 红利)
- [02](../designs/02-beam-backend.md) §6 — 缓存目录 `_build/<profile>/clojerl2_cache/`;结构与 `rebar3_clojerl` 对齐
- [04](../designs/04-bootstrap-and-conformance.md) §7 M5 — 判据:插件可对示例项目完成 compile/repl;缓存命中下二次构建 < 首次 20%

## 工作内容

- [x] 缓存实现:键 = sha256(源)+ 编译器版本 + OTP 主版本 + 选项指纹;命中即写回 .beam 产物,跳过管线
- [x] provider `compile`:编译前查缓存,miss 才调编译器
- [x] provider `repl`:启动带项目 code path 的 clojerl2 REPL
- [x] provider `clean`:清缓存目录
- [x] 插件结构与命令面与 `rebar3_clojerl` 对齐,降低用户迁移成本
- [x] 示例项目(含多 NS 依赖)作为验收载体

## 验收标准

- 示例项目 `rebar3 clojerl2 compile` / `rebar3 clojerl2 repl` 可用
- 缓存命中下二次构建时间 < 首次的 20%(M5 判据,实测数据写入结论)
- 改单个 NS 只重编译该 NS;extend 新类型不触发已有 NS 重编译

## 结论

- **构建引擎** `clj2_build`(不依赖 rebar3,eunit 可直接测):
  - 扫描 `.clj`/`.cljc`,只读第一个 `ns` form,按 `:require` 拓扑排序,循环依赖报错;
  - 每个命名空间要么从缓存取模块,要么编译。两种情况都会加载(依赖方要在它之上编译),并写入 ebin;
  - ebin 里的 manifest 记录写过的模块,删掉的命名空间或 extend 的 impl 模块会被清理;
  - 缓存条目先写临时目录再 rename。
- **缓存键**:
  - 包含源码 sha256、编译器指纹(各 `clj2_*` 模块和 clojure.core 的 md5)、OTP 主版本、编译选项,再加上**每个被 require 的命名空间的接口指纹**。
  - 补最后一项的原因:设计里的键只看源码,但 A 的产物取决于 B 的宏和 arity(直接链接)。只看源码的话,B 改宏后 A 会拿到过期的 beam。
  - 接口指纹是 var info 去掉 doc;如果 B 有宏,再加上宏函数及其在本模块内可达函数的抽象代码,行号擦除。这部分按模块 md5 记在磁盘上,避免每次都解码 debug_info。
  - 已知漏洞:宏在展开时调用第三个命名空间的函数,那个函数变了不会触发重编。
- **验收里的"改单个 NS 只重编该 NS"**(`clj2_build_tests` 断言):改函数体或 docstring,只重编它;改宏或 arity,连同依赖方重编;新命名空间对已有协议 extend 新类型,只编它自己。另外断言了:删掉的命名空间的模块离开 ebin;clean 之后全部重编。
- **rebar3 插件** `clojerl2/rebar3_clojerl2`:
  - 命名空间 `clojerl2`,有 compile/repl/clean 三个 provider,配置键 `clj2_src_dirs`/`clj2_mode`,对应 rebar3_clojerl 的 `clje_src_dirs`。
  - 插件自身没有依赖:provider 在项目依赖编译完之后,从依赖的 code path 上调用 clojerl2,做法与 rebar3_clojerl 对 clojerl 一致。
  - 构建 clj2 源码的范围:项目 app,以及配置了 `clj2_src_dirs` 的依赖。
  - 缓存在 `_build/<profile>/clojerl2_cache`。
- **clojerl2 成为 OTP 应用**:加了 `rebar.config` 和 `src/erl/clojerl2.app.src`;Makefile 构建不受影响。clojure.core 源码从 `src/clj2/core` 移到 `priv/clj2/core`。原因是用一份不带 `ebin/` 的干净拷贝模拟真实依赖时,rebar3 只镜像 `src/erl`,core 源码根本拿不到;`priv/` 会随 checkout、依赖和 release 一起带上。没有预编译 core 时,core 也走缓存。
- **示例项目** `examples/hello`:三个命名空间(协议加两个 extend、带宏的工具命名空间、带中文输出的主命名空间)。`make example`(`test/rebar3-example.sh`,已进 CI)依次检查:首次 3 个编译,再次 3 个命中;ebin 产物齐全;`repl` 能 require 并调用;`clean` 清干净。`_checkouts` 被仓库的 .gitignore 忽略,所以由脚本创建链接。
- **M5 判据实测**(40 个命名空间的链式项目,各 25 个 fn 加 1 个宏和 1 个宏调用;各跑三次,结果稳定):

  | 场景 | 首次 | 缓存命中 | 整条 rebar3 命令 | clojerl2 阶段 |
  |---|---|---|---|---|
  | 从零(含 clojerl2 与 core) | 5.78s | 1.04s | **18.0%** | 4490→317ms,7.1% |
  | 只重编项目 | 4.25s | 1.00s | **23.5%** | 3571→299ms,8.4% |

  - clojerl2 自身的部分远低于 20%。命中时剩下的约 0.7s 是 rebar3 自身的启动、依赖分析和 Erlang 源检查,与项目大小无关,所以小项目的整条命令比例在 20% 上下。3 个命名空间的示例是 2.49s 对 0.87s。
  - 实测中做过两处优化:`scan` 改为只读第一个 form,从 106ms 降到 3ms;宏摘要做了磁盘记忆。命中构建因此从 384ms 降到约 300ms,剩下的主要是加载 40 个模块。
- **顺带修正**:`require` 加载的文件出错时,错误位置写的是那个文件(取最内层),不再一律写 `REPL`;没有 `ebin/clj2.build` 时(rebar3 构建),banner 显示应用版本。
- **未做**:`.app` 的 `modules` 列表不包含 clj2 生成的模块,relx release 需要时再补;插件的 escriptize/release/run/test provider(rebar3_clojerl 有)不在本任务范围。
