# clojerl2-046 数据转换

状态:已完成(2026-10-13)
里程碑:M7
依赖:clojerl2-045

## 工作内容

- [x] `clj2_data:to_erl/1,2`:vector、set、seq → list,Clojure map、record → map,关键字 → binary(`keywords => binary | atom | keep`),
  可选 `nil => null`、`sets => map`
- [x] `clj2_data:from_erl/1,2`:Erlang map → Clojure map,可选 `keys => keyword`、`null => nil`、`lists => vector`
- [x] Clojure 侧 `clj->erl`、`erl->clj`,选项写成 Clojure map(`{:nil :null}`)

## 结论

回归测试 `clj2_embed_tests:data_conversion_test`。
