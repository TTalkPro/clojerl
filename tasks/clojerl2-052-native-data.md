# clojerl2-052 map 改为原生 Erlang map,向量交给 Erlang 时自动变 list

状态:已完成(2026-10-13)
里程碑:M7
依赖:clojerl2-045、051

## 工作内容

- [x] 没有元数据的 map 就是 Erlang map(`hash-map`、字面量、`assoc` ……都产生原生 map);带元数据时才包成 `{map, Meta, Map}`,
  `with-meta` 去掉元数据时还原为原生 map;所有读 map 的地方两种形状都接受(ex-info 数据、var 元数据、记录、EDN、宏边界 ……)
- [x] 键的元数据规范化(`nk/1`)作用于原生 map;带元数据的 map 作为键时规范成原生 map
- [x] 用户代码调用 Erlang 函数(`模块/函数`)时,参数经 `clj2_data:arg/1`:向量深层转成 list、带元数据的 map 去包装、惰性序列实现成 list;
  没有需要转换的部分原样返回;常量在编译期转换。运行时模块(`clj2_*`)、标准库(`clojure.*` 命名空间)和 Erlang 的运算符与 `is_*` 不转换
- [x] 修正:`Var.fn` 接受 map;transient 不被当作记录;`(into {} [[1]])` 的报错;sorted 集合与原生 map 相等

## 结论

eunit 671 全过;corpus 4142(无变化);CTS 5530(无变化,基线一致)。回归测试 `clj2_interop_tests`;文档 `docs/erlang-interop.md`、`docs/embedding.md`。
