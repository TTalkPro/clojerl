# spike-003 惰性记忆化基准报告(clojerl2-003)

状态:已完成。对应 [designs/03-runtime-model.md](../../designs/03-runtime-model.md) §5.3/§6 的 spike 判据
(量化 pdict 版与 ETS 版 lazy-seq 吞吐差,决定 ETS 开关的**默认值**)。
基准代码:[`../bench/spike-003-lazy-memo.escript`](../bench/spike-003-lazy-memo.escript)。

## 1. 判据与结论(先行)

designs/03 §5.3 已定 v1 默认 pdict 记忆单元,ETS 共享单元作开关备选;本 spike 负责量化两者差距,
并验证 ETS 版 realize-once 的可行原语。

实测(OTP 28,i9-13900H,8 调度器在线):

| 路径 | pdict (A) | ETS (B) | B/A |
|---|---|---|---|
| memo hit(取缓存) | 30.2 ns | 87.6 ns(rc)/ 45.5 ns(no-rc) | **2.9x / 1.5x** |
| miss + realize(净) | 75.6 ns | 249.3 ns | **3.3x** |
| 64 步 lazy 链首次 realize / 步 | 81.0 ns | 995.1 ns | **12.3x** |
| 64 步 lazy 链重走(全命中)/ 步 | 17.0 ns | 460.3 ns | **27.2x** |
| realize-once(claim+insert,净) | — | 682.4 ns | vs pdict realize **9.0x** |

**结论:维持 designs/03 §5.3 原判 —— v1 默认 pdict,ETS 为开关备选。**
性能差距在链式场景(真实 lazy-seq 形态)达 12–27 倍,开关默认值无任何悬念。
pdict 的语义分歧(跨进程各自 realize)在纯 thunk 下不可观察——实测 4 进程观察同一
`pure_payload` delay,**值全部一致**,只是 body 各跑了一次(§3)。

## 2. 环境与复现

| 项 | 值 |
|---|---|
| OTP | release 28 / ERTS 16.4.0.3,x86_64,`smp:128:8` |
| 微基准 | 2,000,000 次/格,best-of-5,1024 单元轮换池 |
| 链基准 | 64 步/链 × 20,000 链 = 1,280,000 步/格 |
| 并发校验 | 8 racer 经 barrier 同抢一个单元,slow thunk 50 轮 + fast thunk 200 轮 |

```sh
escript clojerl2/bench/spike-003-lazy-memo.escript
```

## 3. 跨进程语义实测(4 进程观察同一 delay)

| 策略 | body 执行次数 | 观察值 | 判定 |
|---|---|---|---|
| pdict | 4(每进程一次) | 全相同(纯 payload) | 分歧不可观察 ✓ |
| ets-plain(lookup+insert) | 4 | 4 个不同值 | **无保证,naive 实现是错的** |
| ets-claim(占位+CAS) | 1 | 1 个值 | realize-once ✓ |

结论:**ETS 开关版绝不能用 lookup+insert 的 naive 形态**(并发下观察者会看到不同值);
必须用 claim 形态(先占位,再 CAS/update_counter 提交)。

## 4. ETS realize-once 原语对比(并发实测)

| claim 原语 | 净成本 | slow thunk body 次数 | 判定 |
|---|---|---|---|
| `ets:select_replace` CAS | 469.3 ns | 50/50(恰好一次) | PASS |
| `ets:update_counter/4` 占位计数 | **57.4 ns** | 50/50(恰好一次) | PASS |
| compute+CAS(先算再提交) | — | 400/50(可重复算) | PASS(值唯一,但副作用 thunk 会重复执行) |

**选定原语:`ets:update_counter/4`** —— 比 select_replace 便宜 8 倍且同样恰好一次。

### OTP 28 的坑(已实测确认,写实现时注意)

1. `select_replace` 的 replacement 里**不能直接放元组值** → badarg;须用 match 变量抄出。
2. `select_replace` **拒绝预编译 match spec** → badarg;每次调用都重新解析,这是它贵的主因。
3. `ets:update_counter/4` 返回**新值**(不是旧值)。

## 5. 对设计的回填

- designs/03 §5.3 表格维持不变;"ETS 开关留位"现在的默认值为 **关**(pdict),性能依据 = 本文件 §1。
- §6 中"ETS 开关版用 `ets:select_replace` 做 realize-once CAS"应改为
  **`ets:update_counter/4` 占位计数**(同为恰好一次,便宜 8x);select_replace 留作注释。
- §10 风险 5(热点 atom 的 CAS 争用)与 delay 无关,不受影响;lazy 场景争用极低
  (每单元至多争用一次)。
