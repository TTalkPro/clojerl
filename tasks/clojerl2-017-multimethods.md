# clojerl2-017 多方法

状态:已完成(2026-10-12;分派模块改为 ETS 方法表,见结论)
里程碑:M4
依赖:clojerl2-015

## 目标

实现多方法:保留 clojerl 1.0 的"每多方法一个分派模块"模式(`Ns.name__dispatch__`),生成方式从 cerl 改为直出 absform。

## 设计依据

- [03](../designs/03-runtime-model.md) §5.1 — 分派模块模式保留,`defmethod` 时重生成并热加载
- [03](../designs/03-runtime-model.md) §5.1 — `derive`/`isa?`/prefer 存 ETS 表,不碰全局状态机
- [02](../designs/02-beam-backend.md) §2 — 分派模块与其他编译产物同一 absform 发射路径,消除 cerl 依赖
- [02](../designs/02-beam-backend.md) §5 — BEAM 两版本热替换语义

## 工作内容

- [x] 分派模块(`Ns.name__dispatch__`)生成:`defmethod` 时按当前方法表重新生成并经 absform 路径热加载
- [x] `derive`/`isa?`/`prefer!` 的 ETS 表:祖先链与偏好查询;`defmethod` 只改表 + 重发分派模块
- [x] dispatch fn 值形态:`dispatch/1` 的 fun;分派结果查方法表,未命中走 `:default`
- [x] 层次查询的缓存与失效(derive 变更后 isa? 缓存刷新)
- [x] pass 侧:`defmulti`/`defmethod` 的展开与运行时 API 对接

## 验收标准

- `defmethod` 增量生效:新增方法后新调用立即可见
- 两版本语义测试:进行中调用旧分派模块的进程不受影响,完成后再调用走新表
- 层次正确性测试:`derive` 多级祖先、`isa?`、冲突时 `prefer!` 生效

## 结论

- **与设计的偏离**:没有采用"每多方法一个生成的分派模块"。原因是 `defmethod` 的方法体是加载时才创建的闭包,absform 没法把它当常量写进生成的模块,生成的模块最终也只能查表。现在方法表直接存在 ETS `clj2_multi` 里,每个方法一行。验收要求的两版本语义照样成立:调用开始时就取走方法,进行中的调用不受影响,下一次调用看到新表。每次 `defmethod` 也不必编译。已修订 designs/03 §5.1。
- **实现**:
  - 多方法的值是 `{multifn, nil, {Ns, Name}}`,`clj2_rt:invoke` 能直接调用,所以可以当 fn 值传递,例如 `(map area shapes)`。
  - **分派路径**:精确的分派值一次 ETS 查找命中;否则由 `clojure.core/find-best-method`(Clojure,沿用 clojure.lang.MultiFn 的 isa? + prefers 逻辑,包括歧义报错)选出方法并缓存。缓存印记由多方法版本和层次版本组成,`defmethod`/`remove-method`/`prefer-method`/`derive`/`underive` 都会让它失效;都不命中时走 `:default`,否则报 "No method in multimethod …"。
  - **API**:`defmulti`(含 `:default`/`:hierarchy` 选项;再次 defmulti 保留已有方法,和 Clojure 一样)、`defmethod`(支持多元数)、`remove-method`、`remove-all-methods`、`prefer-method`(拒绝相互矛盾的偏好)、`prefers`、`methods`、`get-method`。
  - **层次**:`make-hierarchy`/`isa?`/`parents`/`ancestors`/`descendants`/`derive`/`underive` 移植自 jolt(`jolt-core/clojure/core/20-coll.clj`,EPL-2.0,即 clojure.core 的纯 map 实现),保留其断言约定,去掉了 JVM 类分支。`:hierarchy` 选项接受 var、atom 或 map。
- **顺带修正**:
  - **`::kw` 自动解析从未实现**:读出来就是 `'::kw'` 这个 atom,`(namespace ::kw)` 为 nil。现在在 parse 中解析为当前命名空间或别名对应的命名空间,关键字字面量、quote 的数据和语法引用里都会解析。
  - 带显式 `ns` 选项的 eval 期间,`*ns*` 绑定为该命名空间,宏能读到。
- **验收**(`clj2_multi_tests`,4 组):
  - `defmethod` 增量生效;
  - 两版本:一个进程停在旧方法里时重定义方法,它仍返回旧结果,新调用返回新结果;
  - 层次:多级 derive、isa?(包括向量)、更具体的方法优先、歧义报错、`prefer-method` 化解歧义、偏好冲突报错、derive/underive 之后缓存失效、derive 的断言与循环检测。
  另外测了自定义层次、自定义 `:default`、多元数和向量分派值、打印。
- **corpus**:2506 → **2575 / 4842**,`:pending/multimethods` 80 → 0。还发现一个 runner 的局限:每个条目在各自的 `corpus.eN` 命名空间里运行,而 JVM 的结果假定在 `user` 下,约 46 条失败条目受此影响(混在其他原因里)。改为在 `user` 中逐条串行运行会让 corpus 慢好几倍,留作后续。
- **验证**:eunit 566 条、`make smoke`、`make docs-check`、`make certify`(0 new / 0 stale)全部通过。
