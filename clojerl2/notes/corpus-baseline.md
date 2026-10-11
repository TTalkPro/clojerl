# corpus 基线(clojerl2-021)

语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0),只计 `:portability :common` 条目。
生成:`clj2_corpus:report(clj2_corpus:run(), Path)`。判定见 `src/erl/clj2_corpus.erl`。

**通过 1714 / 4842(35.4%)**

## 按 suite

| suite | 通过 | 条目 | 通过率 |
|---|---|---|---|
| conformance | 167 | 364 | 46% |
| numbers | 120 | 339 | 35% |
| seq | 180 | 276 | 65% |
| reader | 48 | 211 | 23% |
| predicates | 113 | 188 | 60% |
| map | 134 | 183 | 73% |
| regex | 0 | 150 | 0% |
| format | 6 | 140 | 4% |
| clojure.core | 81 | 135 | 60% |
| untested | 13 | 120 | 11% |
| macros | 51 | 119 | 43% |
| io | 33 | 119 | 28% |
| control | 80 | 102 | 78% |
| maps | 54 | 98 | 55% |
| host-interop | 4 | 97 | 4% |
| sorted | 0 | 90 | 0% |
| interop | 3 | 90 | 3% |
| set | 55 | 80 | 69% |
| metadata | 5 | 75 | 7% |
| functions | 56 | 70 | 80% |
| exceptions | 23 | 66 | 35% |
| destructure | 42 | 64 | 66% |
| transient | 0 | 63 | 0% |
| forms | 45 | 63 | 71% |
| core | 0 | 60 | 0% |
| namespaces | 5 | 56 | 9% |
| lazy | 17 | 56 | 30% |
| vector | 50 | 55 | 91% |
| seq-type-model | 4 | 53 | 8% |
| protocols | 21 | 51 | 41% |
| string | 15 | 49 | 31% |
| truthiness | 47 | 47 | 100% |
| transducers | 21 | 45 | 47% |
| ns | 0 | 44 | 0% |
| clojure.string | 0 | 42 | 0% |
| collections | 21 | 41 | 51% |
| refs | 0 | 40 | 0% |
| multimethods | 0 | 37 | 0% |
| equality | 29 | 32 | 91% |
| vars | 2 | 31 | 6% |
| state | 2 | 31 | 6% |
| uuid | 0 | 30 | 0% |
| records | 11 | 30 | 37% |
| clojure.edn | 0 | 27 | 0% |
| printer | 14 | 26 | 54% |
| charsets | 0 | 26 | 0% |
| clojure.math | 0 | 25 | 0% |
| hierarchy | 0 | 24 | 0% |
| defn | 1 | 24 | 4% |
| syntax-quote | 0 | 22 | 0% |
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
| ISeq call forms | 3 | 9 | 33% |
| murmur3 | 0 | 8 | 0% |
| *ns* | 0 | 8 | 0% |
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
| compile-eval | 0 | 6 | 0% |
| calls | 6 | 6 | 100% |
| vectors | 5 | 5 | 100% |
| var-meta | 0 | 5 | 0% |
| resolution | 1 | 5 | 20% |
| printing | 0 | 5 | 0% |
| eval & load-string as values | 0 | 5 | 0% |
| concurrency | 0 | 5 | 0% |
| chunked-seq | 0 | 5 | 0% |
| time | 0 | 4 | 0% |
| symbols | 4 | 4 | 100% |
| reflect | 0 | 4 | 0% |
| read-string | 0 | 4 | 0% |
| for | 0 | 4 | 0% |
| fn | 0 | 4 | 0% |
| dynamic vars | 0 | 4 | 0% |
| defmacro | 0 | 4 | 0% |
| clojure 1.12 | 0 | 4 | 0% |
| tagged literals | 0 | 3 | 0% |
| string-model | 3 | 3 | 100% |
| permissive | 2 | 3 | 67% |
| munging | 3 | 3 | 100% |
| lazy-seq | 1 | 3 | 33% |
| ifn | 3 | 3 | 100% |
| defonce | 1 | 3 | 33% |
| clojure.repl | 0 | 3 | 0% |
| analyze | 0 | 3 | 0% |
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
| sort | 0 | 1 | 0% |
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

## 失败类别

| 类别 | 条目 |
|---|---|
| compile: unresolved symbol | 1536 |
| compile: error | 633 |
| compile: syntax | 282 |
| threw (unexpected) | 248 |
| wrong value | 232 |
| compile: unsupported special form var | 92 |
| compile: link | 43 |
| compile: recur | 11 |
| compile: on_load_failure | 8 |
| compile: driver | 8 |
| timeout | 6 |
| compile: declare | 6 |
| compile: unsupported special form set! | 5 |
| compile: resolve | 5 |
| compile: unsupported special form . | 4 |
| compile: other | 4 |
| expected a throw | 3 |
| compile: verify | 2 |

## 最常见的未解析符号(缺失的 core 函数/宏的线索)

| 符号 | 条目 |
|---|---|
| `require` | 130 |
| `meta` | 95 |
| `class` | 81 |
| `read-string` | 55 |
| `sorted-map` | 51 |
| `persistent!` | 45 |
| `sorted-set` | 37 |
| `atom` | 36 |
| `defmulti` | 35 |
| `binding` | 35 |
| `load-string` | 32 |
| `derive` | 29 |
| `with-meta` | 26 |
| `with-in-str` | 26 |
| `transient` | 25 |
| `parse-uuid` | 21 |
| `doto` | 19 |
| `int` | 18 |
| `re-find` | 17 |
| `macroexpand-1` | 16 |
| `eval` | 14 |
| `future` | 11 |
| `unchecked-add` | 11 |
| `eduction` | 11 |
| `Object.` | 11 |
| `reify` | 10 |
| `with-local-vars` | 10 |
| `spit` | 9 |
| `random-uuid` | 9 |
| `.getName` | 8 |
| `bigint` | 7 |
| `unchecked-multiply` | 7 |
| `with-open` | 7 |
| `unchecked-inc` | 7 |
| `sorted?` | 7 |
| `sorted-set-by` | 7 |
| `with-redefs` | 6 |
| `unchecked-negate` | 6 |
| `ns-name` | 6 |
| `ref` | 6 |
| `replace` | 6 |
| `subseq` | 6 |
| `defmethod` | 6 |
| `chunked-seq?` | 6 |
| `unchecked-int` | 6 |
| `extend` | 5 |
| `halt-when` | 5 |
| `reader-conditional` | 5 |
| `map-entry?` | 5 |
| `NaN?` | 5 |
| `java.util.Random.` | 5 |
| `String` | 5 |
| `associative?` | 5 |
| `long-array` | 5 |
| `unchecked-long` | 5 |
| `long` | 5 |
| `uuid?` | 5 |
| `num` | 5 |
| `counted?` | 4 |
| `Throwable->map` | 4 |
