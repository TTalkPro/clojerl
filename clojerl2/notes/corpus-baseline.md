# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 3948 / 4841(81.6%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1680 | 2066 | 81% |
| 01-core | 1991 | 2368 | 84% |
| 02-protocols | 118 | 211 | 56% |
| 03-print | 155 | 192 | 81% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 330 | 364 | 91% |
| numbers | 275 | 339 | 81% |
| seq | 272 | 276 | 99% |
| reader | 194 | 211 | 92% |
| predicates | 177 | 188 | 94% |
| map | 162 | 182 | 89% |
| regex | 142 | 150 | 95% |
| format | 115 | 140 | 82% |
| clojure.core | 116 | 135 | 86% |
| untested | 102 | 120 | 85% |
| macros | 102 | 119 | 86% |
| io | 79 | 119 | 66% |
| control | 90 | 102 | 88% |
| maps | 65 | 98 | 66% |
| host-interop | 26 | 97 | 27% |
| sorted | 86 | 90 | 96% |
| interop | 33 | 90 | 37% |
| set | 65 | 80 | 81% |
| metadata | 64 | 75 | 85% |
| functions | 69 | 70 | 99% |
| exceptions | 54 | 66 | 82% |
| destructure | 63 | 64 | 98% |
| transient | 60 | 63 | 95% |
| forms | 62 | 63 | 98% |
| core | 49 | 60 | 82% |
| namespaces | 49 | 56 | 88% |
| lazy | 17 | 56 | 30% |
| vector | 55 | 55 | 100% |
| seq-type-model | 10 | 53 | 19% |
| protocols | 41 | 51 | 80% |
| string | 45 | 49 | 92% |
| truthiness | 47 | 47 | 100% |
| transducers | 45 | 45 | 100% |
| ns | 39 | 44 | 89% |
| clojure.string | 42 | 42 | 100% |
| collections | 37 | 41 | 90% |
| refs | 1 | 40 | 3% |
| multimethods | 36 | 37 | 97% |
| equality | 31 | 32 | 97% |
| vars | 28 | 31 | 90% |
| state | 3 | 31 | 10% |
| uuid | 30 | 30 | 100% |
| records | 25 | 30 | 83% |
| clojure.edn | 27 | 27 | 100% |
| printer | 25 | 26 | 96% |
| charsets | 0 | 26 | 0% |
| clojure.math | 12 | 25 | 48% |
| hierarchy | 23 | 24 | 96% |
| defn | 20 | 24 | 83% |
| syntax-quote | 13 | 22 | 59% |
| sequences | 21 | 21 | 100% |
| seqs | 19 | 21 | 90% |
| strings | 17 | 20 | 85% |
| regex-parity | 15 | 20 | 75% |
| list | 20 | 20 | 100% |
| errors | 12 | 19 | 63% |
| inst | 16 | 18 | 89% |
| deftype | 13 | 15 | 87% |
| clojure.set | 14 | 14 | 100% |
| arrays | 0 | 14 | 0% |
| clojure.walk | 12 | 12 | 100% |
| interop-fixes | 11 | 11 | 100% |
| integer-box-model | 3 | 11 | 27% |
| edn | 11 | 11 | 100% |
| casts | 4 | 11 | 36% |
| typed-throws | 9 | 10 | 90% |
| reduce | 9 | 10 | 90% |
| print | 10 | 10 | 100% |
| quoted-literal constants | 6 | 9 | 67% |
| iref | 1 | 9 | 11% |
| contracts | 7 | 9 | 78% |
| ISeq call forms | 9 | 9 | 100% |
| murmur3 | 0 | 8 | 0% |
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
| printing | 0 | 5 | 0% |
| eval & load-string as values | 3 | 5 | 60% |
| concurrency | 0 | 5 | 0% |
| chunked-seq | 1 | 5 | 20% |
| time | 0 | 4 | 0% |
| symbols | 4 | 4 | 100% |
| reflect | 2 | 4 | 50% |
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
| lazy-seq | 1 | 3 | 33% |
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
| walk | 0 | 1 | 0% |
| try | 1 | 1 | 100% |
| structmaps | 1 | 1 | 100% |
| sort | 1 | 1 | 100% |
| seq hasheq cache | 1 | 1 | 100% |
| scope | 1 | 1 | 100% |
| reflection | 1 | 1 | 100% |
| realized? | 1 | 1 | 100% |
| quote | 1 | 1 | 100% |
| pprint | 1 | 1 | 100% |
| delay | 0 | 1 | 0% |
| defmulti | 1 | 1 | 100% |
| core vars | 0 | 1 | 0% |
| compare | 0 | 1 | 0% |
| bit-ops | 0 | 1 | 0% |
| binding | 0 | 1 | 0% |
| assoc | 1 | 1 | 100% |

## 失败原因(known-failures 登记)

| cause | 条目 |
|---|---|
| `:host/jvm-classes` | 284 |
| `:state/erlang-concurrency` | 214 |
| `:number/beam-semantics` | 119 |
| `:seqs/class-model` | 49 |
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
| `:host/inst-millis` | 6 |
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
| threw (unexpected) | 320 |
| compile: unresolved symbol | 312 |
| wrong value | 234 |
| expected a throw | 11 |
| compile: link | 7 |
| compile: resolve | 4 |
| :expected does not evaluate | 3 |
| compile: syntax | 2 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `atom` | 154 |
| `ref` | 25 |
| `future` | 20 |
| `byte-array` | 14 |
| `reify` | 12 |
| `agent` | 7 |
| `volatile!` | 6 |
| `aget` | 5 |
| `long-array` | 5 |
| `atom?` | 4 |
| `ref-min-history` | 4 |
| `StringWriter.` | 3 |
| `dosync` | 3 |
| `ref-max-history` | 3 |
| `into-array` | 3 |
| `__reader-features` | 3 |
| `promise` | 3 |
| `chunk-first` | 3 |
| `chunk-buffer` | 3 |
| `compare-and-set!` | 2 |
| `bytes?` | 2 |
| `future?` | 2 |
| `aset` | 2 |
| `volatile?` | 2 |
| `double-array` | 2 |
| `file-seq` | 1 |
| `swap!` | 1 |
| `agent-error` | 1 |
| `shorts` | 1 |
| `booleans` | 1 |
| `ref?` | 1 |
| `future-cancelled?` | 1 |
| `await` | 1 |
| `*agent*` | 1 |
| `future-call` | 1 |
| `char-array` | 1 |
| `ns-imports` | 1 |
| `InputStream` | 1 |
| `user` | 1 |
| `ints` | 1 |
| `chars` | 1 |
| `longs` | 1 |
| `alength` | 1 |
| `java.net.URL.` | 1 |
| `iterator-seq` | 1 |
