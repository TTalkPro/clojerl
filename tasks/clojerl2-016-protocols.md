# clojerl2-016 协议运行时

状态:已完成(2026-10-11)
里程碑:M4
依赖:clojerl2-015, clojerl2-002

## 目标

实现协议运行时:impl 模块(`Protocol__Type`)+ ETS 存在性缓存分派,`extend` 只编译新 impl 模块,协议模块与其他 impl 模块一律不动。

## 设计依据

- [03](../designs/03-runtime-model.md) §4.1 — 分派形状:`clj_rt_protocol:impl/2` + `apply`,Default 回退
- [03](../designs/03-runtime-model.md) §4.2 — 方案取舍与退回 ETS fun 表的备选
- [03](../designs/03-runtime-model.md) §9 未决问题 3 — 负缓存:impl 模块在负缓存写入之后才加载的场景,加载时主动清负缓存
- [02](../designs/02-beam-backend.md) §2 — impl 模块经同一 absform 路径发射
- [00](../designs/00-overview.md) §6 风险 2 — 分派性能基准判据(不低于直接调用的 1/3)

## 工作内容

- [x] `defprotocol`:协议 var(描述)+ 每方法一个分派函数 var;~~协议模块~~ 不需要(见结论);默认实现 = `extend-type default`
- [x] `extend-type`/`extend-protocol`/`deftype`/`defrecord` 的 pass 侧与运行时侧:只编译新 `Protocol__Type` impl 模块并 `code:load_binary`
- [x] impl 模块经 absform 路径发射,与其他编译产物同一管线(`unit => impl`)
- [x] 存在性缓存:ETS(key = `{Protocol, TypeTag}`),未命中走 `code:ensure_loaded` 探测并回填,含负缓存
- [x] 负缓存失效:impl 模块加载时主动清对应负缓存(03 §9 未决问题 3,有测试)
- [x] `satisfies?` = 存在性探测,同走缓存
- [x] ~~退回 ETS fun 表~~:002 判据已通过(0.61 > 1/3),不需要

## 验收标准

- extend N 个类型后协议模块零重编译:与 clojerl 1.0 的 O(n²) 累积重编译对比,extend 成本为 O(本类型方法数)
- `satisfies?`/分派正确性测试,含 Default 回退路径
- REPL 交错加载场景测试:负缓存写入后再 extend,`satisfies?` 立即转真

## 结论

2026-10-11 完成,落地形态见 [designs/03](../designs/03-runtime-model.md) §4.1a、[designs/09](../designs/09-erlang-hosted-compiler.md) §4.1。

- 代码:`clj2_proto`(分派、缓存、类型 tag、记录);parse 的内核形式 `defprotocol`/`extend-type`/`extend-protocol`/`deftype`/`defrecord`;语言新增顶层节点 `extend`/`method`;驱动的 impl 单元与 `compile_ns_modules/2`;lower-labs 的 impl 模块布局;core 新层 `02-protocols`(`type instance? satisfies? extends? record?`)。顺带:关键字/map/set/vector 可作函数调用(`clj2_rt:invoke`),常量调用头不再走 fun 分派。
- 验收(`clojerl2/test/clj2_proto_tests.erl`):
  - extend 20 个类型(各在自己的命名空间)后,协议所在命名空间模块与已有 impl 模块的 md5 不变——extend 只编译本类型的 impl 模块;
  - 分派正确性:deftype、defrecord、vector/nil/string 等内建类型、同名参数遮蔽字段;无实现时报 `{clj2_no_protocol_impl, ...}`,extend `default` 后回退;
  - REPL 交错:`satisfies?` 写下负项后再 extend,立即为真;code path 上的 impl 模块由探测加载。
- 偏离:协议不生成模块(元数据在协议 var 里);`Protocol__Default` 写作 `extend-type default`(或 `Object`)。
- 限制:见 03 §4.1a(无 `reify`、symbol 元数据、on_load 自调用、编译期段不含 extend)。
