%%%-------------------------------------------------------------------
%%% @doc clj2_corpus — the conformance corpus and its gate (designs/04 §5,
%%% D12; clojerl2-021, clojerl2-022).
%%%
%%% test/corpus.edn is jolt's corpus, its `:expected' sourced from JVM
%%% Clojure (tools/regen-corpus.clj, `make corpus-regen'): entries
%%% `{:suite :label :expected :actual :portability}'. Only `:common'
%%% entries apply to clojerl2 (`:jvm' ones test host interop).
%%%
%%% Judging, as jolt does it: `:actual' and `:expected' are both source.
%%% The entry is compiled as its own namespace
%%% `(ns corpus.eN) <forms...> (def __result__ <last form>)', `:expected'
%%% as `corpus.eN.x', and the two values compared with clojure.core `='
%%% (a vector :expected equals a seq :actual). `:expected :throws' means
%%% evaluating `:actual' must raise.
%%%
%%% Isolation: each entry runs in a fresh process with output discarded,
%%% a time limit and a heap cap (binaries included). The cap is also the
%%% VM-wide default during the run, so processes an entry spawns are
%%% capped too, and everything left under the entry's group leader is
%%% killed afterwards: one runaway entry (an infinite seq realized or
%%% printed) must not take the host down. Run it through `make corpus' /
%%% `make certify', which also cap the whole VM's memory.
%%%
%%% Gate (`certify/1', jolt's `make certify' model): every failing entry
%%% must be listed in test/corpus-known-failures.edn with a cause — a
%%% registered divergence id (test/known-divergences.edn) or a `:pending'
%%% cause (work not done yet, with its task). An unlisted failure fails
%%% the gate, and so does a listed entry that passes (the list must not
%%% rot). `rebaseline/1' rewrites the list, keeping causes already given.
%%%-------------------------------------------------------------------
-module(clj2_corpus).

-export([run/0, run/1, entries/1, raw_entries_for_test/1, overrides/0, report/2,
         certify/0, certify/1, rebaseline/0, rebaseline/1,
         known_failures/0, divergence_ids/0]).

run() -> run(#{}).

%% Opts: file, workers (8), timeout (ms, 10000), limit (entries),
%% max_heap (bytes per process, 256 MiB)
%% → [{I, Entry, pass | {fail, Why}}]; Entry has `layer' (its core tier)
run(Opts) ->
    {ok, _} = clj2_core:boot(),
    File = maps:get(file, Opts, default_file()),
    Entries0 = [E || E = #{portability := common} <- entries(File)],
    Entries1 = case maps:get(limit, Opts, all) of
                   all -> Entries0;
                   N -> lists:sublist(Entries0, N)
               end,
    Tag = layer_tagger(),
    Entries = [E#{layer => Tag(A)} || E = #{actual := A} <- Entries1],
    Indexed = lists:zip(lists:seq(1, length(Entries)), Entries),
    %% entries that change namespaces other than their own (ns, in-ns,
    %% eval, require ...) run one at a time, and what they create is
    %% removed after each: run in parallel they would redefine each
    %% other's vars mid-run
    %% entries that name the user namespace (user/x, #user.R, in-ns
    %% 'user) run in it, as on the JVM, one at a time too
    Indexed1 = [{I, case in_user(E) of true -> E#{ns => user}; false -> E end} || {I, E} <- Indexed],
    {Global, Local} = lists:partition(fun({_, E = #{actual := A}}) ->
                                              global_effects(A) orelse is_map_key(ns, E)
                                      end, Indexed1),
    MaxHeap = #{size => maps:get(max_heap, Opts, 256 bsl 20) div erlang:system_info(wordsize),
                kill => true, error_logger => false, include_shared_binaries => true},
    Old = erlang:system_flag(max_heap_size, MaxHeap),
    Timeout = maps:get(timeout, Opts, 10000),
    try lists:keysort(1, pool(Local, maps:get(workers, Opts, 8), Timeout, false) ++ pool(Global, 1, Timeout, true))
    after erlang:system_flag(max_heap_size, Old)
    end.

in_user(#{actual := A, expected := E0}) ->
    E = case is_binary(E0) of true -> E0; false -> <<>> end,         % or :throws
    %% user/x, #user.R, (in-ns 'user), or the namespace named: (ns-map 'user)
    %% *ns*: the JVM evaluated each entry at a REPL in user
    re:run([A, " ", E], "user[/.][^ ]|\\(quote user\\)|'user[) \\]]|\\*ns\\*", [unicode]) =/= nomatch.

global_effects(Src) ->
    %% spit too: rows share temp file names (/tmp/jolt-spit-test.txt)
    re:run(Src, "\\((ns|in-ns|load-string|load-file|eval|require|create-ns|remove-ns|intern|use|refer|refer-clojure|spit) ",
           [unicode]) =/= nomatch.

default_file() -> test_file("corpus.edn").

test_file(Name) ->
    filename:join([filename:dirname(code:which(?MODULE)), "..", "test", Name]).

read_edn(Path) ->
    {ok, Bin} = file:read_file(Path),
    {ok, [Form], _} = clj2_reader:read_all(Bin),
    clj2_form:to_data(Form).

%% @doc The corpus entries as Erlang maps. `{Suite, Label}' identifies an
%% entry in the gate, so a repeated one gets its label suffixed " (2)" ...
entries(File) ->
    {Es, _} = lists:mapfoldl(
                fun(#{suite := S, label := L} = E, Seen) ->
                        N = maps:get({S, L}, Seen, 0) + 1,
                        L1 = case N of
                                 1 -> L;
                                 _ -> iolist_to_binary([L, " (", integer_to_list(N), ")"])
                             end,
                        {E#{label := L1}, Seen#{{S, L} => N}}
                end, #{}, raw_entries(File)),
    Overrides = overrides(),
    [case Overrides of
         #{{S, L} := O} -> maps:merge(E, O);
         _ -> E
     end || E = #{suite := S, label := L} <- Es,
            %% a row whose outcome a registered divergence leaves undefined
            not maps:get(skip, maps:get({S, L}, Overrides, #{}), false)].

%% @doc test/corpus-overrides.edn: #{{Suite, Label} => #{actual, expected,
%% because}} — rows rewritten for a registered divergence.
overrides() ->
    Path = test_file("corpus-overrides.edn"),
    case filelib:is_file(Path) of
        false -> #{};
        true ->
            maps:from_list(
              [{{clj2_coll:get(O, ':suite'), clj2_coll:get(O, ':label')},
                maps:from_list([{K, V} || {K, Key} <- [{actual, ':actual'}, {expected, ':expected'},
                                                      {because, ':because'}, {skip, ':skip'}],
                                          V <- [clj2_coll:get(O, Key)], V =/= nil])}
               || O <- clj2_coll:to_list(read_edn(Path))])
    end.

%% @doc The rows with their own labels, overrides not applied (skipped
%% rows included): for checking the overrides file.
raw_entries_for_test(File) -> raw_entries(File).

raw_entries(File) ->
    [#{suite => clj2_coll:get(E, ':suite'),
       label => clj2_coll:get(E, ':label'),
       expected => clj2_coll:get(E, ':expected'),
       actual => clj2_coll:get(E, ':actual'),
       portability => case clj2_coll:get(E, ':portability') of
                          ':common' -> common;
                          ':jvm' -> jvm;
                          nil -> unspecified;
                          P -> P
                      end}
     || E <- clj2_coll:to_list(read_edn(File))].

%% An entry's tier (designs/04 §5.2): the latest core layer defining a
%% symbol it mentions; the first layer when it mentions none.
layer_tagger() ->
    Vars = clj2_core:layer_vars(),
    Order = maps:from_list(lists:zip(clj2_core:layers(), lists:seq(1, length(clj2_core:layers())))),
    [First | _] = clj2_core:layers(),
    fun(Src) ->
            Syms = try {ok, Fs, _} = clj2_reader:read_all(Src), symbols(Fs, [])
                   catch _:_ -> []
                   end,
            Ls = [maps:get(S, Vars) || S <- Syms, maps:is_key(S, Vars)],
            lists:foldl(fun(L, Acc) ->
                                case maps:get(L, Order) > maps:get(Acc, Order) of
                                    true -> L;
                                    false -> Acc
                                end
                        end, First, Ls)
    end.

symbols({clj2_loc, _, _, F, _}, Acc) -> symbols(F, Acc);
symbols(L, Acc) when is_list(L) -> lists:foldl(fun symbols/2, Acc, L);
symbols({Coll, [], Items}, Acc) when is_list(Items), (Coll =:= vector orelse Coll =:= set) ->
    symbols(Items, Acc);
symbols({map, [], Pairs}, Acc) when is_list(Pairs) ->
    symbols([X || {K, V} <- Pairs, X <- [K, V]], Acc);
symbols(A, Acc) when is_atom(A) -> [A | Acc];
symbols(_, Acc) -> Acc.

%%====================================================================
%% Running
%%====================================================================

%% Isolate: the pool runs alone (one worker, nothing else running), so
%% the namespaces that appear during an entry are that entry's.
pool(Indexed, Workers, Timeout, Isolate) ->
    Self = self(),
    Queue = spawn_link(fun() -> queue(Indexed) end),
    Ws = [spawn_link(fun() -> worker(Queue, Self, Timeout, Isolate) end) || _ <- lists:seq(1, Workers)],
    Results = collect(length(Indexed), []),
    [unlink(W) || W <- Ws],
    unlink(Queue),
    lists:keysort(1, Results).

queue([]) -> receive {next, W} -> W ! done, queue([]) end;
queue([Job | Rest]) -> receive {next, W} -> W ! {job, Job}, queue(Rest) end.

worker(Queue, Parent, Timeout, Isolate) ->
    Queue ! {next, self()},
    receive
        done -> ok;
        {job, {I, Entry}} ->
            Before = clj2_ns:all(),
            R = run_entry(I, Entry, Timeout),
            [drop_ns(N) || Isolate, N <- clj2_ns:all() -- Before],
            Parent ! {result, I, Entry, R},
            worker(Queue, Parent, Timeout, Isolate)
    end.

drop_ns(Ns) ->
    Mods = case clj2_ns:info(Ns) of
               {ok, #{module := M, vars := Vars}} -> [M | [VM || #{module := VM} <- maps:values(Vars)]];
               error -> []
           end,
    clj2_ns:remove(Ns),
    [begin code:purge(M), code:delete(M), code:purge(M) end
     || M <- lists:usort(Mods), M =/= 'clojure.core', code:is_loaded(M) =/= false,
        not lists:prefix("clj2_", atom_to_list(M))].

collect(0, Acc) -> Acc;
collect(N, Acc) ->
    receive {result, I, Entry, R} -> collect(N - 1, [{I, Entry, R} | Acc]) end.

%% → pass | {fail, Why}. Judged in the child so only a small term crosses
%% back; a killed child (heap cap) shows up as {crashed, killed}.
run_entry(I, #{actual := Actual, expected := Expected} = Entry, Timeout) ->
    Ns = case Entry of
             #{ns := N} -> N;
             _ -> list_to_atom("corpus.e" ++ integer_to_list(I))
         end,
    Self = self(),
    Sink = sink(),
    {Pid, Ref} = spawn_monitor(fun() ->
                                       group_leader(Sink, self()),
                                       Self ! {verdict, self(), judge(Ns, Actual, Expected)}
                               end),
    Verdict = receive
                  {verdict, Pid, V} -> erlang:demonitor(Ref, [flush]), V;
                  {'DOWN', Ref, _, _, R} -> {fail, {crashed, brief(R)}}
              after Timeout ->
                  exit(Pid, kill),
                  receive {'DOWN', Ref, _, _, _} -> ok end,
                  {fail, timeout}
              end,
    kill_group(Sink),
    cleanup(Ns),
    Verdict.

%% Kill every process the entry left behind (they inherit its group leader).
kill_group(Sink) ->
    [exit(P, kill) || P <- processes(), P =/= Sink,
                      process_info(P, group_leader) =:= {group_leader, Sink}],
    exit(Sink, kill).

brief(T) -> iolist_to_binary(io_lib:format("~P", [T, 12])).

judge(Ns, Actual, ':throws') ->
    case evaluate(Ns, Actual) of
        {threw, _} -> pass;
        {value, _} -> {fail, no_throw};
        %% the JVM raises these at compile time too (CompilerException);
        %% a missing var or form is a gap, not the expected throw
        {compile_error, Why} ->
            case raises_on_jvm(Why) of
                true -> pass;
                false -> {fail, {compile_error, Why}}
            end
    end;
judge(Ns, Actual, Expected) ->
    case evaluate(Ns, Actual) of
        {threw, R} -> {fail, {threw, R}};
        {compile_error, Why} -> {fail, {compile_error, Why}};
        {value, V} ->
            case evaluate(list_to_atom(atom_to_list(Ns) ++ ".x"), Expected) of
                {value, E} ->
                    %% `=' realizes lazy seqs, which may raise
                    try clj2_coll:equals(V, E) of
                        true -> pass;
                        false -> {fail, {mismatch, printed(V)}}
                    catch C:R -> {fail, {threw, brief({C, R})}}
                    end;
                _ -> {fail, expected_error}
            end
    end.

%% a symbol no JVM namespace defines either is the JVM's compile error too;
%% one JVM Clojure has (priv/clj2/jvm-docs.eterm) is a gap here
raises_on_jvm({resolve, {unresolved_symbol, S}}) -> not clj2_rt:is_jvm_var(S);
raises_on_jvm({resolve, _}) -> false;
raises_on_jvm({unsupported, _}) -> false;
raises_on_jvm(_) -> true.

printed(V) ->
    P = try clj2_print:pr_str(V) catch _:_ -> <<"#<unprintable>">> end,
    binary:part(P, 0, min(byte_size(P), 300)).

%% → {value, V} | {threw, Brief} | {compile_error, Why}
evaluate(Ns, Src) ->
    try
        Forms = case clj2_reader:read_all(Src) of
                    {ok, Fs, _} -> Fs;
                    {error, _, Msg} -> throw({read, Msg})
                end,
        Body = flatten_do(Forms),
        case lists:any(fun is_ns_form/1, Body) of
            %% an entry that switches namespaces (ns forms) is what a REPL
            %% session does on the JVM: evaluate it form by form, as the
            %% clojerl2 REPL and load-string do (a namespace module has one
            %% ns form)
            true -> evaluate_forms(Ns, Body);
            false -> evaluate_unit(Ns, Body)
        end
    catch
        throw:{read, Msg2} -> {compile_error, {read, Msg2}};
        error:{clj2_compile, _, Why2} -> {compile_error, Why2};
        %% a literal handed to a macro that has no data form yet
        error:{clj2_form, {no_data_form, K}} -> {compile_error, {unsupported, {literal, K}}};
        C3:R3 -> {compile_error, {C3, brief(R3)}}
    end.

evaluate_unit(Ns, Body) ->
    {Init, [Last]} = lists:split(length(Body) - 1, Body),
    Prog = {forms, [[ns, Ns] | Init] ++ [[def, '__result__', Last]]},
    case clj2_compiler:load_ns(Prog) of
        {ok, Ns} ->
            try {value, Ns:'__result__'()}
            catch C:R -> {threw, brief({C, R})}
            end;
        {error, {ns_init_failed, _, R2}} -> {threw, brief(R2)};
        {error, Why} -> {compile_error, Why}
    end.

evaluate_forms(Ns, Body) ->
    clj2_ns:ensure(Ns),
    try {value, clj2_compiler:eval({forms, Body}, #{ns => Ns})}
    catch
        error:{clj2_compile, _, Why} -> {compile_error, Why};
        error:{clj2_read, _, Msg} -> {compile_error, {read, Msg}};
        C:R -> {threw, brief({C, R})}
    end.

is_ns_form(F) ->
    case unwrap(F) of
        [H | _] -> unwrap(H) =:= ns;
        _ -> false
    end.

flatten_do([]) -> [nil];
flatten_do([F]) ->
    case unwrap(F) of
        [H | Rest] -> case unwrap(H) of
                          'do' -> flatten_do_all(Rest);
                          _ -> [F]
                      end;
        _ -> [F]
    end;
flatten_do(Fs) -> Fs.

flatten_do_all([]) -> [nil];
flatten_do_all(Fs) -> Fs.

unwrap({clj2_loc, _, _, F, _}) -> F;
unwrap(F) -> F.

%% An entry's modules: `corpus.eN', `corpus.eN.x' and the like, `corpus.eN$ctK'
%% (not `corpus.eN0': parallel workers own those).
cleanup(Ns) ->
    Name = atom_to_list(Ns),
    Mine = fun(M) ->
                   S = atom_to_list(M),
                   S =:= Name orelse lists:prefix(Name ++ ".", S) orelse lists:prefix(Name ++ "$", S)
           end,
    [clj2_ns:remove(N) || N <- clj2_ns:all(), Mine(N)],
    [begin code:purge(M), code:delete(M), code:purge(M) end
     || {M, _} <- code:all_loaded(), Mine(M)],
    ok.

sink() ->
    spawn(fun Loop() ->
                  receive
                      {io_request, From, R, _} -> From ! {io_reply, R, ok}, Loop()
                  after 600000 -> ok
                  end
          end).

%%====================================================================
%% Gate
%%====================================================================

known_failures_file() -> test_file("corpus-known-failures.edn").

%% @doc The known-failures registry: #{pending => #{Cause => Info},
%% entries => #{{Suite, Label} => Cause}}.
known_failures() ->
    case filelib:is_file(known_failures_file()) of
        false -> #{pending => #{}, entries => #{}};
        true ->
            D = read_edn(known_failures_file()),
            Pending = maps:from_list(clj2_form:map_pairs(clj2_coll:get(D, ':pending'))),
            Entries = maps:from_list([{{clj2_coll:get(E, ':suite'), clj2_coll:get(E, ':label')},
                                       clj2_coll:get(E, ':cause')}
                                      || E <- clj2_coll:to_list(clj2_coll:get(D, ':entries'))]),
            #{pending => Pending, entries => Entries}
    end.

%% @doc The ids registered in test/known-divergences.edn.
divergence_ids() ->
    [clj2_coll:get(E, ':id') || E <- clj2_coll:to_list(read_edn(test_file("known-divergences.edn")))].

certify() -> certify(#{}).

%% @doc Run the corpus and gate it. → {ok | fail, Summary}; prints a report.
certify(Opts) ->
    Results = run(Opts),
    #{pending := Pending, entries := Known} = known_failures(),
    Causes = divergence_ids() ++ maps:keys(Pending),
    Key = fun(#{suite := S, label := L}) -> {S, L} end,
    Failing = [{Key(E), Why} || {_, E, {fail, Why}} <- Results],
    Passing = [Key(E) || {_, E, pass} <- Results],
    New = [{K, Why} || {K, Why} <- Failing, not maps:is_key(K, Known)],
    Stale = [K || K <- Passing, maps:is_key(K, Known)],
    BadCause = lists:usort([C || C <- maps:values(Known), not lists:member(C, Causes)]),
    io:format("corpus: ~b/~b pass, ~b known failures, ~b new, ~b stale, ~b unregistered causes~n",
              [length(Passing), length(Results), length(Failing) - length(New),
               length(New), length(Stale), length(BadCause)]),
    [io:format("  NEW   ~ts / ~ts: ~ts~n", [S, L, brief(Why)]) || {{S, L}, Why} <- New],
    [io:format("  STALE ~ts / ~ts (passes now: drop it from the list)~n", [S, L]) || {S, L} <- Stale],
    [io:format("  CAUSE ~ts is neither a divergence id nor a :pending cause~n", [C]) || C <- BadCause],
    Status = case New ++ Stale ++ BadCause of [] -> ok; _ -> fail end,
    {Status, #{results => Results, new => New, stale => Stale, bad_cause => BadCause}}.

rebaseline() -> rebaseline(#{}).

%% @doc Rewrite test/corpus-known-failures.edn from a fresh run: every
%% failing entry is listed; one listed before keeps its cause, a new one
%% gets a first guess (cause/2). Opts `reclassify': causes whose entries
%% are guessed afresh (after the work a pending cause stood for is done,
%% its leftovers fail for other reasons).
rebaseline(Opts) ->
    Results = run(Opts),
    #{entries := Known0} = known_failures(),
    Again = maps:get(reclassify, Opts, []),
    Known = maps:filter(fun(_, C) -> not lists:member(C, Again) end, Known0),
    Rows = [{S, L, maps:get({S, L}, Known, cause(E, Why))}
            || {_, #{suite := S, label := L} = E, {fail, Why}} <- Results],
    ok = file:write_file(known_failures_file(), unicode:characters_to_binary(known_failures_text(Rows))),
    #{failures => length(Rows), total => length(Results)}.

%% The pending causes and the work that removes them. Unresolved names map
%% to the task that provides them; the rest by failure kind.
pending_legend() ->
    [{':pending/multimethods', <<"defmulti/defmethod and hierarchies are not implemented yet.">>, <<"clojerl2-017">>},
     {':pending/ref-types', <<"Atom construction options (:meta, a :validator that rejects the initial value) and alter-meta! on atoms; atom validator failures are not IllegalStateException. (Var-root operations came with clojerl2-032.)">>, <<"clojerl2-033 triage">>},
     {':pending/var-surface', <<"Var objects: the Java surface of clojure.lang.Var (isBound, hasRoot, bindRoot, alterRoot, setMacro, ns/sym, getRawRoot, unbindRoot, set, Var/intern, fn), thread-bound?/get-thread-bindings; core vars carry no :doc. (Using a namespace's vars through var objects while it loads came with clojerl2-034.)">>, <<"clojerl2-033 triage">>},
     {':pending/jvm-exceptions', <<"An error is raised, but not as the JVM's exception class or message. (Erlang errors refined by the failing call, clj2 error terms, casts, String methods and parse messages came with clojerl2-035.)">>, <<"clojerl2-035">>},
     {':pending/arg-checks', <<"A core fn accepts an argument the JVM rejects, or rejects one the JVM accepts. (find, nth, peek, pop, rseq, shuffle, nthrest, numeric predicates, symbol/keyword, odd kvs, counts, contains? on strings, keyword ordering ... came with clojerl2-035.)">>, <<"clojerl2-035">>},
     {':pending/laziness', <<"Realization timing differs: iterate calls f early, mapcat/dedupe realize late, pmap is not semi-lazy, sequence realizes its first element only when walked, an eduction is a seq, ~@ realizes a spliced seq while building the template.">>, <<"clojerl2-033 triage">>},
     {':pending/printer', <<"Printing: the print-method multimethod (user methods for records and host classes), *print-length*/*print-level* on records and sorted collections and nested levels, *print-meta*, *print-namespace-maps*, str of a Class (class X), subnormal doubles, str of an ex-info, a caught host fault printed as #error.">>, <<"clojerl2-033 triage">>},
     {':pending/records', <<"Records: map?/coll? of a record, conj of an entry or a map onto a record, deftype vs defrecord map?, __extmap/__meta fields.">>, <<"clojerl2-033 triage">>},
     {':pending/regex-edge', <<"Edge cases of the Java regex translation (clj2_re): control escapes (backslash-c) with (?x), backslash-Q inside them, look-behind bound checks, empty intersections, quantified empty flag groups.">>, <<"clojerl2-033 triage">>},
     {':pending/format-edge', <<"Edge cases of format (java.util.Formatter): # with zero padding, + on unsigned conversions, argument index 0, width on %n, %a rounding and subnormals.">>, <<"clojerl2-033 triage">>},
     {':pending/core-bugs', <<"Wrong results of core macros and fns: for's :while after :let/:when, definline, cond-> expansion shape, destructuring a map with a rest pattern, the multi-input map transducer, case with mixed constants, with-open on a non-closeable, a protocol miss on nil when Object is extended, transient nil keys, attr-map :doc over the docstring, *suppress-read*.">>, <<"clojerl2-033 triage">>},
     {':pending/corpus-environment', <<"The expected value depends on where the corpus was generated (a README the JVM run read, a deref the regeneration timed out on, *ns*: the JVM evaluated each entry at a REPL in user, the harness loads it as a namespace of its own and loading binds *ns* to it; a class the JVM run could not resolve without an import, StringWriter or InputStream, so the row kept jolt's value); needs a corpus override, not a fix.">>, <<"clojerl2-033 triage">>},
     {':pending/strings-io', <<"regexes, format, string/char functions and reader/writer IO are not implemented yet.">>, <<"clojerl2-020">>},
     {':pending/runtime-eval', <<"Namespace reflection is not implemented yet: ns-publics/ns-map/ns-aliases/ns-unmap/intern/resolve, var objects (var-get, var?), alias/refer as functions, an ns form inside a namespace file. (eval, read-string, require, in-ns came with clojerl2-023.)">>, <<"clojerl2-023 follow-up">>},
     {':pending/metadata', <<"meta/with-meta/vary-meta on values are not implemented yet; conj/pop/into on a list and select-keys drop metadata.">>, <<"clojerl2-021 follow-up">>},
     {':pending/sorted-colls', <<"sorted maps and sets are not implemented yet.">>, <<"clojerl2-021 follow-up">>},
     {':pending/transients', <<"transient/persistent! and the bang ops are not implemented yet.">>, <<"clojerl2-021 follow-up">>},
     {':pending/host-types', <<"class/type/instance? and other host type queries are not implemented yet; JVM class names need a mapping onto clj2 type tags; host classes and members not shimmed yet (Thread, Math statics, Keyword methods ...).">>, <<"clojerl2-021 follow-up; cleared by clojerl2-041">>},
     {':pending/stdlib-namespaces', <<"A standard library namespace or var not ported yet (clojure.data, clojure.zip, clojure.datafy ...). (clojure.edn, clojure.math, clojure.pprint and clojure.repl came with clojerl2-039.)">>, <<"clojerl2-039">>},
     {':pending/missing-core-var', <<"A clojure.core var, or an arity of one, is not ported yet. (sorted-map?/sorted-set?, thread-bound?, get-thread-bindings, tagged-literal and reader-conditional, Inst/inst-ms, xml-seq, struct maps, the proxy stubs, conj! and read-string arities, test, bytes ... came with clojerl2-036.)">>, <<"clojerl2-036">>},
     {':pending/special-forms', <<"A special form (var, set!, ., new, letfn* ...) is not compiled yet.">>, <<"clojerl2-021 follow-up">>},
     {':pending/numbers', <<"A numeric gap that is not a registered divergence. (BigDecimal literals, arithmetic, with-precision, printing and the java.math.BigDecimal surface came with clojerl2-037.)">>, <<"clojerl2-037">>},
     {':pending/reader', <<"The reader rejects the source (reader conditionals, number syntax, escapes ...), or reports a read error unlike the JVM.">>, <<"clojerl2-021 follow-up; cleared by clojerl2-040">>},
     {':pending/compiler', <<"The compiler rejects the entry: defrecord, extend-protocol and the like inside an expression (they are top-level forms here). (loop* inits in order, nested syntax-quote and its JVM construction code, destructured deftype/defmacro params, Object methods, deftype options, defprotocol options, trailing attr-maps, declare, defonce, lazy apply came with clojerl2-038.)">>, <<"clojerl2-038">>},
     {':pending/triage', <<"Runs but disagrees with the JVM (wrong value, unexpected or missing throw, timeout, crash), cause not yet known: a new failure lands here until it is triaged into a concrete cause or a registered divergence.">>, <<"clojerl2-033">>}].

%% A first guess at a new failure's cause: a registered divergence when the
%% entry plainly exercises one, else a pending cause by failure kind.
cause(#{suite := Suite, label := Label, expected := Exp, actual := Act}, Why) ->
    Has = fun(Src, Re) -> is_binary(Src) andalso re:run(Src, Re, [unicode]) =/= nomatch end,
    Chunking = (Has(Suite, "chunk") orelse Has(Label, "chunk")) andalso not Has(Label, "not chunked|unchunked")
               andalso not Has(Suite, "unchunked"),
    Stm = case Why of
              {threw, B0} when is_binary(B0) -> binary:match(B0, <<"refs and STM">>) =/= nomatch;
              _ -> false
          end,
    case Why of
        _ when Chunking -> ':lazy-seq/no-chunking';
        {compile_error, {syntax, {bad_catch_class, _}}} -> ':exceptions/erlang-classes';
        %% a core fn without that arity is a gap; a fn of the entry's own,
        %% the divergence (a compile error, not a run-time ArityException)
        {compile_error, {link, {arity, 'clojure.core', _, _}}} -> ':pending/missing-core-var';
        {compile_error, {link, {arity, _, _, _}}} -> ':fn/arity-at-compile-time';
        {compile_error, {resolve, {unresolved_symbol, reify}}} -> ':protocols/type-designators';
        {threw, _} when Stm -> ':refs/no-stm';
        {mismatch, _} ->
            case {Has(Suite, "^fn identity"), Has(Exp, "(^|[^\\w\"])-?\\d+/\\d+"), Has(Exp, "\\\\[a-z]")} of
                {true, _, _} -> ':fn/structural-identity';
                {_, true, _} -> ':number/no-ratio-arithmetic';
                {_, _, true} -> ':char/integer';
                _ -> ':pending/triage'
            end;
        {threw, <<"{error,{clj2_require,{not_found,'clojure.", _/binary>>} -> ':pending/stdlib-namespaces';
        {threw, <<"{error,{clj2_form,{no_data_form,", _/binary>>} -> ':pending/compiler';
        {threw, B} ->
            case {binary:match(B, <<"undef">>), Has(Act, "clojure\\.lang\\.|java\\.")} of
                {nomatch, _} -> ':pending/triage';
                {_, true} -> ':pending/host-types';
                {_, false} -> case Has(Act, "clojure\\.(string|set|walk|edn|math|pprint|repl|template|zip|data)/") of
                                  true -> ':pending/stdlib-namespaces';
                                  false -> ':pending/triage'
                              end
            end;
        _ -> pending_cause(Why)
    end.

pending_cause({compile_error, {resolve, {unresolved_symbol, S}}}) -> symbol_cause(S);
pending_cause({compile_error, {resolve, {no_such_var, _, S}}}) -> symbol_cause(S);
pending_cause({compile_error, {unsupported, {special_form, _}}}) -> ':pending/special-forms';
pending_cause({compile_error, {syntax, ns_must_be_first_form}}) -> ':pending/runtime-eval';
pending_cause({compile_error, {read, _}}) -> ':pending/reader';
pending_cause({compile_error, {unsupported, {literal, regex}}}) -> ':pending/strings-io';
pending_cause({compile_error, {unsupported, {literal, tagged}}}) -> ':pending/reader';
pending_cause({compile_error, {unsupported, {literal, L}}}) when L =:= bigdec; L =:= bigint -> ':pending/numbers';
pending_cause({compile_error, _}) -> ':pending/compiler';
pending_cause(_) -> ':pending/triage'.

symbol_cause(S) ->
    N = atom_to_list(S),
    Owners = [{':pending/multimethods',
               [defmulti, defmethod, derive, underive, 'isa?', parents, ancestors, descendants,
                'make-hierarchy', 'prefer-method', 'remove-method', 'remove-all-methods', methods,
                'get-method', prefers]},
              {':pending/ref-types',
               [atom, 'swap!', 'reset!', 'swap-vals!', 'reset-vals!', 'compare-and-set!', 'add-watch',
                'remove-watch', 'set-validator!', 'get-validator', 'volatile!', 'vswap!', 'vreset!',
                'volatile?', ref, dosync, alter, commute, 'ref-set', agent, send, 'send-off', await,
                future, 'future-call', 'future-cancel', 'future?', 'future-done?', promise, deliver,
                delay, 'delay?', force, 'realized?', binding, 'with-redefs', 'alter-var-root',
                'with-bindings', 'bound-fn', 'locking', 'io!']},
              {':pending/strings-io',
               ['re-find', 're-matches', 're-seq', 're-pattern', 're-groups', 're-matcher', format,
                printf, 'with-in-str', 'read-line', slurp, spit, 'line-seq', char, 'char?',
                'parse-long', 'parse-double', 'parse-uuid', 'parse-boolean', 'random-uuid', 'uuid?',
                'char-escape-string', 'char-name-string', newline, flush, 'print-str', 'println-str',
                'prn-str']},
              {':pending/runtime-eval',
               [require, use, import, refer, load, 'load-string', 'load-file', 'read-string', read, eval,
                'macroexpand', 'macroexpand-1', resolve, 'ns-resolve', 'find-ns', 'the-ns',
                'create-ns', 'remove-ns', 'all-ns', 'ns-name', 'ns-publics', 'ns-interns',
                'ns-map', 'ns-aliases', 'ns-refers', 'ns-unmap', intern, 'find-var', 'var-get',
                'var-set', 'var?', 'bound?', 'thread-bound?', '*ns*', 'requiring-resolve']},
              {':pending/metadata', [meta, 'with-meta', 'vary-meta', 'alter-meta!', 'reset-meta!']},
              {':pending/sorted-colls',
               ['sorted-map', 'sorted-map-by', 'sorted-set', 'sorted-set-by', subseq, rsubseq, 'sorted?']},
              {':pending/transients',
               [transient, 'persistent!', 'conj!', 'assoc!', 'dissoc!', 'pop!', 'disj!']},
              {':pending/host-types',
               [class, type, 'instance?', cast, 'class?', bases, supers, 'satisfies?']}],
    case [C || {C, Syms} <- Owners, lists:member(S, Syms)] of
        [C | _] -> C;
        [] when hd(N) =/= $. -> case string:prefix(N, "clojure.") of
                                    nomatch -> host_or_missing(N);
                                    "lang." ++ _ -> ':pending/host-types';
                                    "core/" ++ _ -> ':pending/missing-core-var';
                                    _ -> ':pending/stdlib-namespaces'
                                end;
        [] -> ':pending/host-types'
    end.

%% Class/method, .method, Class. and other host forms
host_or_missing(N) ->
    case lists:member($., N) orelse lists:member($/, N) of
        true -> ':pending/host-types';
        false -> ':pending/missing-core-var'
    end.

known_failures_text(Rows) ->
    Sorted = lists:sort(Rows),
    ["\
;; clojerl2 corpus known failures (designs/04 §5.1 gate, clojerl2-022).
;;
;; Every :common corpus entry that fails is listed here with its cause:
;; a divergence id from known-divergences.edn (a deliberate difference)
;; or a :pending cause below (work not done yet). `make certify' fails on
;; a failure that is not listed and on a listed entry that passes.
;;
;; Generated by `make corpus-rebaseline' (clj2_corpus:rebaseline/0), which
;; keeps the cause of entries already listed: to triage an entry, edit its
;; :cause here (e.g. to a divergence id) and it sticks.
{:pending
 {",
     lists:join("\n  ", [io_lib:format("~ts {:reason ~ts :task ~ts}", [C, str(R), str(T)])
                         || {C, R, T} <- pending_legend()]),
     "}\n :entries\n [",
     lists:join("\n  ", [io_lib:format("{:suite ~ts :label ~ts :cause ~ts}", [str(S), str(L), C])
                         || {S, L, C} <- Sorted]),
     "]}\n"].

str(B) -> clj2_print:pr_str(B).

%%====================================================================
%% Report
%%====================================================================

%% @doc Write a markdown baseline of `Results' (from run/1) to `Path'.
report(Results, Path) ->
    Total = length(Results),
    Passed = length([ok || {_, _, pass} <- Results]),
    Tally = fun(KeyFun) ->
                    lists:foldl(fun({_, E, R}, Acc) ->
                                        K = KeyFun(E),
                                        {P, T} = maps:get(K, Acc, {0, 0}),
                                        maps:put(K, {P + case R of pass -> 1; _ -> 0 end, T + 1}, Acc)
                                end, #{}, Results)
            end,
    ByLayer = Tally(fun(#{layer := L}) -> atom_to_binary(L) end),
    BySuite = Tally(fun(#{suite := S}) -> suite_group(S) end),
    #{entries := Known} = known_failures(),
    Causes = count([maps:get({S, L}, Known, <<"(unlisted)">>)
                    || {_, #{suite := S, label := L}, {fail, _}} <- Results]),
    Kinds = count([fail_kind(R) || {_, _, {fail, _} = R} <- Results]),
    Unresolved = count([S || {_, _, {fail, {compile_error, {resolve, {unresolved_symbol, S}}}}} <- Results]
                       ++ [S || {_, _, {fail, {compile_error, {resolve, {no_such_var, _, S}}}}} <- Results]),
    Table = fun(M, Sort) ->
                    Rows = case Sort of
                               by_name -> lists:sort(maps:to_list(M));
                               by_size -> [{K, V} || {_, K, V} <- lists:reverse(lists:sort([{T, K, {P, T}} || {K, {P, T}} <- maps:to_list(M)]))]
                           end,
                    [io_lib:format("| ~ts | ~b | ~b | ~b% |~n", [K, P, T, round(100 * P / T)])
                     || {K, {P, T}} <- Rows]
            end,
    Lines =
        [io_lib:format("# corpus 基线(clojerl2-021/022)~n~n", []),
         io_lib:format("语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0;`:expected` 经 `make corpus-regen` 以 JVM Clojure 1.12.5 重新生成),只计 `:portability :common` 条目。~n"
                       "生成:`make corpus`;门控:`make certify`(对照 `test/corpus-known-failures.edn`)。判定见 `src/erl/clj2_corpus.erl`。~n~n", []),
         io_lib:format("**通过 ~b / ~b(~.1f%)**~n~n", [Passed, Total, 100 * Passed / max(Total, 1)]),
         "## 按 core 分层\n\n条目归入它引用到的最靠后的 core 层(`clj2_core:layer_vars/0`)。\n\n"
         "| 层 | 通过 | 条目 | 通过率 |\n|---|---|---|---|\n",
         Table(ByLayer, by_name),
         "\n## 按 suite\n\n| suite | 通过 | 条目 | 通过率 |\n|---|---|---|---|\n",
         Table(BySuite, by_size),
         "\n## 失败原因(known-failures 登记)\n\n| cause | 条目 |\n|---|---|\n",
         [io_lib:format("| `~ts` | ~b |~n", [K, N]) || {K, N} <- Causes],
         "\n## 失败类别\n\n| 类别 | 条目 |\n|---|---|\n",
         [io_lib:format("| ~ts | ~b |~n", [K, N]) || {K, N} <- Kinds],
         "\n## 最常见的未解析符号(缺失的 core 函数/宏的线索)\n\n| 符号 | 条目 |\n|---|---|\n",
         [io_lib:format("| `~ts` | ~b |~n", [S, N]) || {S, N} <- lists:sublist(Unresolved, 60)]],
    ok = file:write_file(Path, unicode:characters_to_binary(Lines)),
    #{passed => Passed, total => Total}.

suite_group(S) ->
    case binary:split(S, <<" / ">>) of
        [G | _] -> string:trim(G);
        _ -> S
    end.

fail_kind({fail, {threw, _}}) -> <<"threw (unexpected)">>;
fail_kind({fail, no_throw}) -> <<"expected a throw">>;
fail_kind({fail, expected_error}) -> <<":expected does not evaluate">>;
fail_kind({fail, timeout}) -> <<"timeout">>;
fail_kind({fail, {mismatch, _}}) -> <<"wrong value">>;
fail_kind({fail, {crashed, _}}) -> <<"crashed">>;
fail_kind({fail, {compile_error, {resolve, {unresolved_symbol, _}}}}) -> <<"compile: unresolved symbol">>;
fail_kind({fail, {compile_error, {resolve, {no_such_var, _, _}}}}) -> <<"compile: no such var">>;
fail_kind({fail, {compile_error, {unsupported, {special_form, F}}}}) ->
    iolist_to_binary(["compile: unsupported special form ", atom_to_binary(F)]);
fail_kind({fail, {compile_error, {unsupported, {literal, L}}}}) ->
    iolist_to_binary(["compile: unsupported literal ", atom_to_binary(L)]);
fail_kind({fail, {compile_error, {Phase, _}}}) when is_atom(Phase) ->
    iolist_to_binary(["compile: ", atom_to_binary(Phase)]);
fail_kind({fail, {compile_error, _}}) -> <<"compile: other">>.

count(Xs) ->
    M = lists:foldl(fun(X, Acc) -> maps:update_with(X, fun(N) -> N + 1 end, 1, Acc) end, #{}, Xs),
    lists:reverse(lists:keysort(2, maps:to_list(M))).
