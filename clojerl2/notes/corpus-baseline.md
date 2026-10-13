# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 4318 / 4841(89.2%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1779 | 1895 | 94% |
| 01-core | 2236 | 2539 | 88% |
| 02-protocols | 137 | 211 | 65% |
| 03-print | 162 | 192 | 84% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 350 | 364 | 96% |
| numbers | 285 | 339 | 84% |
| seq | 275 | 276 | 100% |
| reader | 196 | 211 | 93% |
| predicates | 181 | 188 | 96% |
| map | 163 | 182 | 90% |
| regex | 143 | 150 | 95% |
| format | 116 | 140 | 83% |
| clojure.core | 135 | 135 | 100% |
| untested | 115 | 120 | 96% |
| macros | 109 | 119 | 92% |
| io | 81 | 119 | 68% |
| control | 101 | 102 | 99% |
| maps | 69 | 98 | 70% |
| host-interop | 78 | 97 | 80% |
| sorted | 86 | 90 | 96% |
| interop | 75 | 90 | 83% |
| set | 65 | 80 | 81% |
| metadata | 67 | 75 | 89% |
| functions | 70 | 70 | 100% |
| exceptions | 65 | 66 | 98% |
| destructure | 64 | 64 | 100% |
| transient | 60 | 63 | 95% |
| forms | 63 | 63 | 100% |
| core | 57 | 60 | 95% |
| namespaces | 49 | 56 | 88% |
| lazy | 50 | 56 | 89% |
| vector | 55 | 55 | 100% |
| seq-type-model | 10 | 53 | 19% |
| protocols | 42 | 51 | 82% |
| string | 48 | 49 | 98% |
| truthiness | 47 | 47 | 100% |
| transducers | 45 | 45 | 100% |
| ns | 43 | 44 | 98% |
| clojure.string | 42 | 42 | 100% |
| collections | 38 | 41 | 93% |
| refs | 2 | 40 | 5% |
| multimethods | 37 | 37 | 100% |
| equality | 32 | 32 | 100% |
| vars | 29 | 31 | 94% |
| state | 30 | 31 | 97% |
| uuid | 30 | 30 | 100% |
| records | 25 | 30 | 83% |
| clojure.edn | 27 | 27 | 100% |
| printer | 25 | 26 | 96% |
| charsets | 13 | 26 | 50% |
| clojure.math | 17 | 25 | 68% |
| hierarchy | 24 | 24 | 100% |
| defn | 20 | 24 | 83% |
| syntax-quote | 17 | 22 | 77% |
| sequences | 21 | 21 | 100% |
| seqs | 21 | 21 | 100% |
| strings | 20 | 20 | 100% |
| regex-parity | 15 | 20 | 75% |
| list | 20 | 20 | 100% |
| errors | 16 | 19 | 84% |
| inst | 18 | 18 | 100% |
| deftype | 14 | 15 | 93% |
| clojure.set | 14 | 14 | 100% |
| arrays | 13 | 14 | 93% |
| clojure.walk | 12 | 12 | 100% |
| interop-fixes | 11 | 11 | 100% |
| integer-box-model | 3 | 11 | 27% |
| edn | 11 | 11 | 100% |
| casts | 4 | 11 | 36% |
| typed-throws | 10 | 10 | 100% |
| reduce | 9 | 10 | 90% |
| print | 10 | 10 | 100% |
| quoted-literal constants | 6 | 9 | 67% |
| iref | 9 | 9 | 100% |
| contracts | 8 | 9 | 89% |
| ISeq call forms | 9 | 9 | 100% |
| murmur3 | 8 | 8 | 100% |
| *ns* | 8 | 8 | 100% |
| locking | 7 | 7 | 100% |
| fn identity | 1 | 7 | 14% |
| chunking-model | 0 | 7 | 0% |
| take | 0 | 6 | 0% |
| string as a seqable of chars | 6 | 6 | 100% |
| streams | 0 | 6 | 0% |
| stdlib | 6 | 6 | 100% |
| nth | 6 | 6 | 100% |
| meta | 4 | 6 | 67% |
| instance? | 6 | 6 | 100% |
| distinct | 6 | 6 | 100% |
| compile-eval | 5 | 6 | 83% |
| calls | 6 | 6 | 100% |
| vectors | 5 | 5 | 100% |
| var-meta | 5 | 5 | 100% |
| resolution | 4 | 5 | 80% |
| printing | 1 | 5 | 20% |
| eval & load-string as values | 4 | 5 | 80% |
| concurrency | 4 | 5 | 80% |
| chunked-seq | 1 | 5 | 20% |
| time | 0 | 4 | 0% |
| symbols | 4 | 4 | 100% |
| reflect | 4 | 4 | 100% |
| read-string | 4 | 4 | 100% |
| for | 4 | 4 | 100% |
| fn | 4 | 4 | 100% |
| dynamic vars | 4 | 4 | 100% |
| defmacro | 2 | 4 | 50% |
| clojure 1.12 | 4 | 4 | 100% |
| tagged literals | 3 | 3 | 100% |
| string-model | 0 | 3 | 0% |
| permissive | 2 | 3 | 67% |
| munging | 3 | 3 | 100% |
| lazy-seq | 3 | 3 | 100% |
| ifn | 3 | 3 | 100% |
| defonce | 3 | 3 | 100% |
| clojure.repl | 3 | 3 | 100% |
| analyze | 2 | 3 | 67% |
| special forms | 2 | 2 | 100% |
| record hasheq cache | 2 | 2 | 100% |
| reader-model | 2 | 2 | 100% |
| identical? lowering | 2 | 2 | 100% |
| fn identity hash | 2 | 2 | 100% |
| defprotocol | 2 | 2 | 100% |
| def | 2 | 2 | 100% |
| concurrency-model | 0 | 2 | 0% |
| clojure.template | 2 | 2 | 100% |
| assert | 2 | 2 | 100% |
| walk | 1 | 1 | 100% |
| try | 1 | 1 | 100% |
| structmaps | 1 | 1 | 100% |
| sort | 1 | 1 | 100% |
| seq hasheq cache | 1 | 1 | 100% |
| scope | 1 | 1 | 100% |
| reflection | 1 | 1 | 100% |
| realized? | 1 | 1 | 100% |
| quote | 1 | 1 | 100% |
| pprint | 1 | 1 | 100% |
| delay | 1 | 1 | 100% |
| defmulti | 1 | 1 | 100% |
| core vars | 1 | 1 | 100% |
| compare | 0 | 1 | 0% |
| bit-ops | 0 | 1 | 0% |
| binding | 1 | 1 | 100% |
| assoc | 1 | 1 | 100% |

## 失败原因(known-failures 登记)

| cause | 条目 |
|---|---|
| `:number/beam-semantics` | 119 |
| `:host/jvm-classes` | 96 |
| `:seqs/class-model` | 49 |
| `:refs/no-stm` | 38 |
| `:collections/map-order` | 36 |
| `:collections/exact-keys` | 24 |
| `:lazy-seq/no-chunking` | 24 |
| `:symbol/no-metadata` | 14 |
| `:pending/corpus-environment` | 14 |
| `:regex/erlang-semantics` | 12 |
| `:protocols/type-designators` | 12 |
| `:char/integer` | 11 |
| `:macros/defmacro-form` | 10 |
| `:number/no-ratio-arithmetic` | 10 |
| `:values/no-identity` | 9 |
| `:transients/wrapped` | 6 |
| `:fn/structural-identity` | 6 |
| `:collections/map-entry-vectors` | 5 |
| `:reader/platform-feature` | 4 |
| `:fn/arity-at-compile-time` | 4 |
| `:string/code-point-indexing` | 3 |
| `:dynamic/per-process-bindings` | 3 |
| `:vars/forward-references` | 2 |
| `:sorted/comparator-calls` | 2 |
| `:vars/core-direct-linked` | 2 |
| `:namespaces/symbols` | 2 |
| `:interop/erlang-module-calls` | 2 |
| `:lazy-seq/per-process-realization` | 1 |
| `:pending/laziness` | 1 |
| `:exceptions/erlang-classes` | 1 |
| `:pending/compiler` | 1 |

## 失败类别

| 类别 | 条目 |
|---|---|
| wrong value | 260 |
| threw (unexpected) | 194 |
| compile: unresolved symbol | 41 |
| expected a throw | 10 |
| compile: link | 7 |
| compile: resolve | 5 |
| :expected does not evaluate | 3 |
| compile: syntax | 2 |
| timeout | 1 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `reify` | 12 |
| `ref-min-history` | 5 |
| `ref-max-history` | 3 |
| `chunk-first` | 3 |
| `chunk-buffer` | 3 |
| `StringWriter.` | 3 |
| `__reader-features` | 3 |
| `ref?` | 2 |
| `ref-history-count` | 1 |
| `ns-imports` | 1 |
| `file-seq` | 1 |
| `java.nio.file.attribute.FileAttribute` | 1 |
| `InputStream` | 1 |
| `java.net.URL.` | 1 |
| `user` | 1 |
