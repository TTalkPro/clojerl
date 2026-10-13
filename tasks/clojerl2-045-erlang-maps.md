# clojerl2-045 Erlang 原生 map 作为 Clojure 集合

状态:已完成(2026-10-13)
里程碑:M7
依赖:clojerl2-044

## 目标

宿主的数据(JSON 解码后是 Erlang map、binary、list)原地交给 Clojure 代码,不做整体转换。

## 工作内容

- [x] `clj2_coll`:`get`、`assoc`、`dissoc`、`conj`(entry、map、entry 序列)、`contains?`、`count`、`keys`、`vals`、`seq` 作用于
  Erlang map,结果仍是 Erlang map;`=` 在 Erlang map 与 Clojure map 之间按内容比较
- [x] 打印、哈希、`class`、协议分派(`map` 标签)、作为函数调用 `(m k)`、`ifn?`、`transient`、`empty`(得 `#{}`)
- [x] 由此 `update`、`get-in`、`assoc-in`、`merge`、`select-keys`、`reduce-kv`、`map?`、`cond->` 等都可用
- [x] `get` 对列表接受整数下标(JSON 数组是 Erlang 列表),新登记差异 `:collections/list-index-get`

## 结论

回归测试 `clj2_embed_tests:erlang_maps_test`;corpus 与 eunit 无回归。
