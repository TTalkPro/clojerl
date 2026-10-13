# clojerl2-048 性能基准

状态:已完成(2026-10-13)
里程碑:M7
依赖:clojerl2-045、047

## 工作内容

- [x] `bench/clj2_bench.erl`,`make bench`:直接调用、`clj2:call`、流式事件规则、请求改写、正则加多方法的规则、`to_erl` 转换

## 结论

本机中位数:直接调用 0.02µs;`clj2:call` 0.44µs;流式事件(`get-in` + `str/includes?`)0.50µs;请求改写(20 条消息)0.09µs;
规则(`count` + 正则 + 多方法)0.75µs;`to_erl` 1.7µs。都在微秒以下到两微秒之间。
