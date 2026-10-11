%%%-------------------------------------------------------------------
%%% @doc clj2_corpus — runs the conformance corpus (designs/04 §5, D12).
%%%
%%% test/corpus.edn is jolt's corpus (JVM Clojure as the oracle): entries
%%% `{:suite :label :expected :actual :portability}'. Only `:common'
%%% entries apply to clojerl2 (`:jvm' ones test host interop).
%%%
%%% Each entry is compiled as its own namespace (entries define vars):
%%% `(ns corpus.eN) <forms...> (def __result__ <last form>)', loaded in
%%% a fresh process with output discarded, a time limit and a heap cap
%%% (binaries included). The cap is also the VM-wide default during the
%%% run, so processes an entry spawns are capped too, and everything left
%%% under the entry's group leader is killed afterwards: one runaway entry
%%% (an infinite seq realized or printed) must not take the host down. It
%%% passes when
%%% `:expected' is ":threw" and evaluation raised, or when the result
%%% prints as `:expected', or equals (`=') the value `:expected' reads as.
%%%
%%% run/1 returns the per-entry results; report/2 writes the baseline
%%% (clojerl2-021); clojerl2-022 gates CI on it with known-divergences.
%%%-------------------------------------------------------------------
-module(clj2_corpus).

-export([run/0, run/1, entries/1, report/2]).

run() -> run(#{}).

%% Opts: file, workers (8), timeout (ms, 3000), limit (entries),
%% max_heap (bytes per process, 256 MiB)
run(Opts) ->
    {ok, _} = clj2_core:boot(),
    File = maps:get(file, Opts, default_file()),
    Entries0 = [E || E = #{portability := common} <- entries(File)],
    Entries = case maps:get(limit, Opts, all) of
                  all -> Entries0;
                  N -> lists:sublist(Entries0, N)
              end,
    Indexed = lists:zip(lists:seq(1, length(Entries)), Entries),
    MaxHeap = #{size => maps:get(max_heap, Opts, 256 bsl 20) div erlang:system_info(wordsize),
                kill => true, error_logger => false, include_shared_binaries => true},
    Old = erlang:system_flag(max_heap_size, MaxHeap),
    try pool(Indexed, maps:get(workers, Opts, 8), maps:get(timeout, Opts, 3000))
    after erlang:system_flag(max_heap_size, Old)
    end.

default_file() ->
    filename:join([filename:dirname(code:which(?MODULE)), "..", "test", "corpus.edn"]).

%% @doc The corpus entries as Erlang maps.
entries(File) ->
    {ok, Bin} = file:read_file(File),
    {ok, [Form], _} = clj2_reader:read_all(Bin),
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
     || E <- clj2_coll:to_list(clj2_form:to_data(Form))].

%%====================================================================
%% Running
%%====================================================================

pool(Indexed, Workers, Timeout) ->
    Self = self(),
    Queue = spawn_link(fun() -> queue(Indexed) end),
    Ws = [spawn_link(fun() -> worker(Queue, Self, Timeout) end) || _ <- lists:seq(1, Workers)],
    Results = collect(length(Indexed), []),
    [unlink(W) || W <- Ws],
    unlink(Queue),
    lists:keysort(1, Results).

queue([]) -> receive {next, W} -> W ! done, queue([]) end;
queue([Job | Rest]) -> receive {next, W} -> W ! {job, Job}, queue(Rest) end.

worker(Queue, Parent, Timeout) ->
    Queue ! {next, self()},
    receive
        done -> ok;
        {job, {I, Entry}} ->
            Parent ! {result, I, Entry, run_entry(I, Entry, Timeout)},
            worker(Queue, Parent, Timeout)
    end.

collect(0, Acc) -> Acc;
collect(N, Acc) ->
    receive {result, I, Entry, R} -> collect(N - 1, [{I, Entry, R} | Acc]) end.

%% → pass | {fail, Why}. Judged in the child so only a small term crosses
%% back; a killed child (heap cap) shows up as {crashed, killed}.
run_entry(I, #{actual := Actual, expected := Expected}, Timeout) ->
    Ns = list_to_atom("corpus.e" ++ integer_to_list(I)),
    Self = self(),
    Sink = sink(),
    {Pid, Ref} = spawn_monitor(fun() ->
                                       group_leader(Sink, self()),
                                       Self ! {verdict, self(), judge(evaluate(Ns, Actual), Expected)}
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

evaluate(Ns, Actual) ->
    try
        {ok, Forms, _} = clj2_reader:read_all(Actual),
        Body = flatten_do(Forms),
        {Init, [Last]} = lists:split(length(Body) - 1, Body),
        Src = {forms, [[ns, Ns] | Init] ++ [[def, '__result__', Last]]},
        case clj2_compiler:load_ns(Src) of
            {ok, Ns} ->
                V = Ns:'__result__'(),
                {value, V, clj2_print:pr_str(V)};
            {error, {ns_init_failed, _, _}} -> threw;
            {error, Why} -> {compile_error, Why}
        end
    catch
        error:{clj2_compile, _, Why2} -> {compile_error, Why2};
        C:R -> {compile_error, {C, brief(R)}}
    end.

flatten_do([F]) ->
    case clj2_form:to_data(F) of
        ['do' | _] -> [_ | Rest] = unwrap(F), flatten_do_all(Rest);
        _ -> [F]
    end;
flatten_do(Fs) -> Fs.

flatten_do_all([]) -> [nil];
flatten_do_all(Fs) -> Fs.

unwrap({clj2_loc, _, _, F, _}) -> F;
unwrap(F) -> F.

judge(threw, <<":threw">>) -> pass;
judge(threw, _) -> {fail, threw};
judge({value, _, _}, <<":threw">>) -> {fail, no_throw};
judge({value, V, Printed}, Expected) ->
    case Printed =:= Expected orelse equal_to_read(V, Expected) of
        true -> pass;
        false -> {fail, {mismatch, binary:part(Printed, 0, min(byte_size(Printed), 300))}}
    end;
judge({compile_error, Why}, _) -> {fail, {compile_error, Why}}.

equal_to_read(V, Expected) ->
    try
        {ok, [F], _} = clj2_reader:read_all(Expected),
        clj2_coll:equals(clj2_form:to_data(F), clj2_form:from_value(V))
    catch _:_ -> false
    end.

cleanup(Ns) ->
    case clj2_ns:info(Ns) of
        {ok, _} -> clj2_ns:remove(Ns);
        error -> ok
    end,
    Prefix = atom_to_list(Ns),
    [begin code:purge(M), code:delete(M), code:purge(M) end
     || {M, _} <- code:all_loaded(), lists:prefix(Prefix, atom_to_list(M))],
    ok.

sink() ->
    spawn(fun Loop() ->
                  receive
                      {io_request, From, R, _} -> From ! {io_reply, R, ok}, Loop()
                  after 600000 -> ok
                  end
          end).

%%====================================================================
%% Report
%%====================================================================

%% @doc Write a markdown baseline of `Results' (from run/1) to `Path'.
report(Results, Path) ->
    Total = length(Results),
    Passed = length([ok || {_, _, pass} <- Results]),
    BySuite = lists:foldl(
                fun({_, #{suite := S}, R}, Acc) ->
                        Key = suite_group(S),
                        {P, T} = maps:get(Key, Acc, {0, 0}),
                        maps:put(Key, {P + case R of pass -> 1; _ -> 0 end, T + 1}, Acc)
                end, #{}, Results),
    Kinds = count([fail_kind(R) || {_, _, {fail, _} = R} <- Results]),
    Unresolved = count([S || {_, _, {fail, {compile_error, {resolve, {unresolved_symbol, S}}}}} <- Results]
                       ++ [S || {_, _, {fail, {compile_error, {resolve, {no_such_var, _, S}}}}} <- Results]),
    Lines =
        [io_lib:format("# corpus 基线(clojerl2-021)~n~n", []),
         io_lib:format("语料:`test/corpus.edn`(jolt `test/chez/corpus.edn` @ 6c2685e,EPL-2.0),只计 `:portability :common` 条目。~n"
                       "生成:`clj2_corpus:report(clj2_corpus:run(), Path)`。判定见 `src/erl/clj2_corpus.erl`。~n~n", []),
         io_lib:format("**通过 ~b / ~b(~.1f%)**~n~n", [Passed, Total, 100 * Passed / max(Total, 1)]),
         "## 按 suite\n\n| suite | 通过 | 条目 | 通过率 |\n|---|---|---|---|\n",
         [io_lib:format("| ~ts | ~b | ~b | ~b% |~n", [K, P, T, round(100 * P / T)])
          || {_, K, {P, T}} <- lists:reverse(lists:sort([{T, K, {P, T}} || {K, {P, T}} <- maps:to_list(BySuite)]))],
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

fail_kind({fail, threw}) -> <<"threw (unexpected)">>;
fail_kind({fail, no_throw}) -> <<"expected a throw">>;
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
