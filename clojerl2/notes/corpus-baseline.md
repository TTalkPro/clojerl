# corpus 基线(clojerl2-021/022)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。
生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。

**通过 1952 / 4842(40.3%)**

## 按 core 分层

条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。

| 层 | 通过 | 条目 | 通过率 |
|---|---|---|---|
| 00-kernel | 1305 | 3242 | 40% |
| 01-core | 587 | 1374 | 43% |
| 02-protocols | 13 | 65 | 20% |
| 03-print | 43 | 157 | 27% |
| 04-repl | 4 | 4 | 100% |

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 178 | 364 | 49% |
| numbers | 124 | 339 | 37% |
| seq | 205 | 276 | 74% |
| reader | 87 | 211 | 41% |
| predicates | 116 | 188 | 62% |
| map | 145 | 183 | 79% |
| regex | 2 | 150 | 1% |
| format | 6 | 140 | 4% |
| clojure.core | 83 | 135 | 61% |
| untested | 19 | 120 | 16% |
| macros | 75 | 119 | 63% |
| io | 33 | 119 | 28% |
| control | 86 | 102 | 84% |
| maps | 57 | 98 | 58% |
| host-interop | 5 | 97 | 5% |
| sorted | 0 | 90 | 0% |
| interop | 23 | 90 | 26% |
| set | 55 | 80 | 69% |
| metadata | 6 | 75 | 8% |
| functions | 69 | 70 | 99% |
| exceptions | 33 | 66 | 50% |
| destructure | 46 | 64 | 72% |
| transient | 0 | 63 | 0% |
| forms | 54 | 63 | 86% |
| core | 0 | 60 | 0% |
| namespaces | 12 | 56 | 21% |
| lazy | 17 | 56 | 30% |
| vector | 50 | 55 | 91% |
| seq-type-model | 4 | 53 | 8% |
| protocols | 21 | 51 | 41% |
| string | 20 | 49 | 41% |
| truthiness | 47 | 47 | 100% |
| transducers | 21 | 45 | 47% |
| ns | 4 | 44 | 9% |
| clojure.string | 0 | 42 | 0% |
| collections | 22 | 41 | 54% |
| refs | 0 | 40 | 0% |
| multimethods | 0 | 37 | 0% |
| equality | 29 | 32 | 91% |
| vars | 2 | 31 | 6% |
| state | 3 | 31 | 10% |
| uuid | 0 | 30 | 0% |
| records | 11 | 30 | 37% |
| clojure.edn | 2 | 27 | 7% |
| printer | 14 | 26 | 54% |
| charsets | 0 | 26 | 0% |
| clojure.math | 0 | 25 | 0% |
| hierarchy | 0 | 24 | 0% |
| defn | 1 | 24 | 4% |
| syntax-quote | 4 | 22 | 18% |
| sequences | 16 | 21 | 76% |
| seqs | 19 | 21 | 90% |
| strings | 10 | 20 | 50% |
| regex-parity | 0 | 20 | 0% |
| list | 20 | 20 | 100% |
| errors | 0 | 19 | 0% |
| inst | 0 | 18 | 0% |
| deftype | 3 | 15 | 20% |
| clojure.set | 0 | 14 | 0% |
| arrays | 0 | 14 | 0% |
| clojure.walk | 0 | 12 | 0% |
| interop-fixes | 4 | 11 | 36% |
| integer-box-model | 0 | 11 | 0% |
| edn | 2 | 11 | 18% |
| casts | 0 | 11 | 0% |
| typed-throws | 0 | 10 | 0% |
| reduce | 9 | 10 | 90% |
| print | 0 | 10 | 0% |
| quoted-literal constants | 6 | 9 | 67% |
| iref | 0 | 9 | 0% |
| contracts | 0 | 9 | 0% |
| ISeq call forms | 9 | 9 | 100% |
| murmur3 | 0 | 8 | 0% |
| *ns* | 6 | 8 | 75% |
| locking | 0 | 7 | 0% |
| fn identity | 0 | 7 | 0% |
| chunking-model | 0 | 7 | 0% |
| take | 0 | 6 | 0% |
| string as a seqable of chars | 6 | 6 | 100% |
| streams | 0 | 6 | 0% |
| stdlib | 0 | 6 | 0% |
| nth | 1 | 6 | 17% |
| meta | 0 | 6 | 0% |
| instance? | 0 | 6 | 0% |
| distinct | 4 | 6 | 67% |
| compile-eval | 2 | 6 | 33% |
| calls | 6 | 6 | 100% |
| vectors | 5 | 5 | 100% |
| var-meta | 0 | 5 | 0% |
| resolution | 4 | 5 | 80% |
| printing | 0 | 5 | 0% |
| eval & load-string as values | 3 | 5 | 60% |
| concurrency | 0 | 5 | 0% |
| chunked-seq | 0 | 5 | 0% |
| time | 0 | 4 | 0% |
| symbols | 4 | 4 | 100% |
| reflect | 0 | 4 | 0% |
| read-string | 0 | 4 | 0% |
| for | 2 | 4 | 50% |
| fn | 0 | 4 | 0% |
| dynamic vars | 0 | 4 | 0% |
| defmacro | 0 | 4 | 0% |
| clojure 1.12 | 0 | 4 | 0% |
| tagged literals | 0 | 3 | 0% |
| string-model | 0 | 3 | 0% |
| permissive | 1 | 3 | 33% |
| munging | 3 | 3 | 100% |
| lazy-seq | 1 | 3 | 33% |
| ifn | 3 | 3 | 100% |
| defonce | 1 | 3 | 33% |
| clojure.repl | 0 | 3 | 0% |
| analyze | 1 | 3 | 33% |
| special forms | 2 | 2 | 100% |
| record hasheq cache | 1 | 2 | 50% |
| reader-model | 0 | 2 | 0% |
| identical? lowering | 2 | 2 | 100% |
| fn identity hash | 2 | 2 | 100% |
| defprotocol | 0 | 2 | 0% |
| def | 0 | 2 | 0% |
| concurrency-model | 0 | 2 | 0% |
| clojure.template | 0 | 2 | 0% |
| assert | 0 | 2 | 0% |
| walk | 0 | 1 | 0% |
| try | 0 | 1 | 0% |
| structmaps | 0 | 1 | 0% |
| sort | 1 | 1 | 100% |
| seq hasheq cache | 0 | 1 | 0% |
| scope | 1 | 1 | 100% |
| reflection | 0 | 1 | 0% |
| realized? | 1 | 1 | 100% |
| quote | 0 | 1 | 0% |
| pprint | 0 | 1 | 0% |
| delay | 0 | 1 | 0% |
| defmulti | 0 | 1 | 0% |
| core vars | 0 | 1 | 0% |
| compare | 0 | 1 | 0% |
| bit-ops | 0 | 1 | 0% |
| binding | 0 | 1 | 0% |
| assoc | 0 | 1 | 0% |

## 失败原因(known-failures 登记)

| cause | 条目 |
|---|---|
| `:pending/missing-core-var` | 477 |
| `:pending/triage` | 350 |
| `:pending/strings-io` | 311 |
| `:pending/ref-types` | 241 |
| `:pending/jvm-exception-classes` | 216 |
| `:pending/host-types` | 208 |
| `:pending/compiler` | 167 |
| `:pending/metadata` | 131 |
| `:pending/stdlib-namespaces` | 125 |
| `:pending/reader` | 118 |
| `:pending/sorted-colls` | 114 |
| `:pending/special-forms` | 105 |
| `:pending/transients` | 79 |
| `:pending/multimethods` | 77 |
| `:pending/numbers` | 66 |
| `:pending/runtime-eval` | 59 |
| `:number/beam-semantics` | 33 |
| `:fn/structural-identity` | 6 |
| `:number/no-ratio-arithmetic` | 4 |
| `:char/integer` | 3 |

## 失败类别

| 类别 | 条目 |
|---|---|
| compile: unresolved symbol | 1456 |
| threw (unexpected) | 305 |
| compile: syntax | 271 |
| wrong value | 208 |
| compile: unsupported literal regex | 200 |
| compile: unsupported literal tagged | 100 |
| compile: unsupported special form var | 93 |
| compile: unsupported literal bigdec | 66 |
| compile: link | 43 |
| expected a throw | 38 |
| compile: read | 24 |
| compile: unsupported literal var | 12 |
| compile: unsupported literal syntax_quote | 10 |
| compile: on_load_failure | 10 |
| compile: unsupported special form set! | 8 |
| compile: resolve | 8 |
| compile: driver | 8 |
| compile: declare | 6 |
| compile: unsupported | 5 |
| timeout | 4 |
| compile: unsupported special form . | 4 |
| compile: other | 4 |
| compile: verify | 2 |
| :expected does not evaluate | 2 |
| compile: unsupported literal unquote | 1 |
| compile: unsupported literal fnstar | 1 |
| compile: no such var | 1 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `atom` | 140 |
| `meta` | 105 |
| `class` | 81 |
| `sorted-map` | 51 |
| `persistent!` | 45 |
| `binding` | 44 |
| `sorted-set` | 37 |
| `defmulti` | 35 |
| `derive` | 29 |
| `with-in-str` | 26 |
| `with-meta` | 26 |
| `transient` | 25 |
| `parse-uuid` | 21 |
| `doto` | 20 |
| `ref` | 18 |
| `int` | 18 |
| `re-find` | 17 |
| `future` | 12 |
| `.getName` | 12 |
| `unchecked-add` | 11 |
| `eduction` | 11 |
| `Object.` | 11 |
| `reify` | 11 |
| `with-local-vars` | 10 |
| `random-uuid` | 9 |
| `spit` | 9 |
| `with-open` | 7 |
| `sorted-set-by` | 7 |
| `.getMessage` | 7 |
| `unchecked-multiply` | 7 |
| `unchecked-inc` | 7 |
| `bigint` | 7 |
| `sorted?` | 7 |
| `with-redefs` | 7 |
| `subseq` | 6 |
| `replace` | 6 |
| `agent` | 6 |
| `uuid?` | 6 |
| `alias` | 6 |
| `unchecked-negate` | 6 |
| `volatile!` | 6 |
| `chunked-seq?` | 6 |
| `unchecked-int` | 6 |
| `long` | 6 |
| `defmethod` | 6 |
| `extend` | 5 |
| `long-array` | 5 |
| `String` | 5 |
| `associative?` | 5 |
| `map-entry?` | 5 |
| `NaN?` | 5 |
| `unchecked-long` | 5 |
| `java.util.Random.` | 5 |
| `reader-conditional` | 5 |
| `resolve` | 5 |
| `var?` | 5 |
| `num` | 5 |
| `halt-when` | 5 |
| `counted?` | 4 |
| `.getBytes` | 4 |
