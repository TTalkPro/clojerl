#!/usr/bin/env escript
%% -*- erlang -*-
%%%-------------------------------------------------------------------
%%% clojerl2-003 -- lazy-seq / delay memoization spike (M0)
%%%
%%% A delay / lazy-seq is modelled as  thunk + memo cell:
%%%   cell = {Key, Thunk},  Key = fresh ref token created with the cell
%%%
%%%   C control : plain non-memoized thunk call (what memoization saves)
%%%   A pdict   : get/2 + put/2, per-process memo cell
%%%   B ETS     : ets:lookup/2 + ets:insert/2, one row per cell
%%%
%%% plus a lazy chain of N steps under A and B, the cross-process
%%% semantics of A vs B, and a concurrent realize-once correctness check
%%% for the ETS CAS (ets:select_replace claim/commit, plus the
%%% ets:update_counter guarded variant).
%%%
%%% design refs: designs/03-runtime-model.md 5.3 and 6
%%%-------------------------------------------------------------------

-mode(compile).

-define(ITERS, 2000000).        %% micro iterations per rep
-define(REPS, 5).               %% reps, best-of
-define(POOL, 1024).            %% memo cells live in the micro loops
-define(CHAIN_LEN, 64).         %% lazy steps per chain
-define(CHAIN_ITERS, 20000).    %% chains (or rewalks) per rep
-define(ROUNDS_FAST, 200).      %% race rounds, cheap thunk
-define(ROUNDS_SLOW, 50).       %% race rounds, 1ms thunk
-define(RACERS, 8).             %% racers per round
-define(AWAIT_MAX, 500000).     %% spin bound when waiting for a winner

main(_Args) ->
    io:format("~n=== clojerl2-003 lazy memo spike (designs/03 5.3 / 6) ===~n"),
    print_env(),
    io:format("~n[1/4] micro benchmarks: iters=~B, best-of-~B, cell pool=~B~n",
              [?ITERS, ?REPS, ?POOL]),
    {Names, M, S1} = micro(),
    print_rows(Names, M),
    print_derived_micro(M),
    io:format("~n[2/4] lazy chain: N=~B steps/chain, ~B chains per iteration~n",
              [?CHAIN_LEN, ?CHAIN_ITERS]),
    {CN, CM, S2} = chain(),
    print_rows(CN, CM),
    print_derived_chain(CM),
    io:format("~n[3/4] cross-process semantics: one delay realized by 4 processes~n"),
    semantics(),
    io:format("~n[4/4] ETS realize-once under concurrent realization~n"),
    Verdict = cas_check(),
    io:format("~nCHECKSUM = ~w~n", [checksum(S1 ++ S2)]),
    io:format("~n>>> ETS realize-once CAS check: ~s~n",
              [case Verdict of pass -> "PASS"; _ -> "FAIL" end]),
    ok.

%%%===================================================================
%%% environment / timing
%%%===================================================================

print_env() ->
    io:format("otp_release=~s  schedulers_online=~B  system=~s~n",
              [erlang:system_info(otp_release),
               erlang:system_info(schedulers_online),
               erlang:system_info(system_version)]).

%% F() performs exactly Iters operations and returns an integer checksum.
bench(_Iters, F) ->
    Runs = [begin
                T0 = erlang:monotonic_time(),
                S = F(),
                {erlang:monotonic_time() - T0, S}
            end || _ <- lists:seq(1, ?REPS)],
    {lists:min([T || {T, _} <- Runs]),
     [S || {_, S} <- Runs],
     [T || {T, _} <- Runs]}.

checksum(Sums) -> lists:sum(Sums) band 16#FFFFFFFF.

ops_sec(Best, _It) when Best =< 0 -> 0;
ops_sec(Best, It) -> round(1000000000 * It / Best).

%%%===================================================================
%%% the model
%%%===================================================================

mk_pool(N) -> list_to_tuple([make_ref() || _ <- lists:seq(1, N)]).

next_i(I, Size) when I >= Size -> 1;
next_i(I, _Size) -> I + 1.

%% A: per-process memo cell
realize_pdict({K, T}) ->
    case get(K) of
        undefined -> V = T(), put(K, V), V;
        V -> V
    end.

%% B: shared memo cell
realize_ets(Tab, {K, T}) ->
    case ets:lookup(Tab, K) of
        [{_, V}] -> V;
        [] -> V = T(), ets:insert(Tab, {K, V}), V
    end.

%%%===================================================================
%%% micro loops
%%%===================================================================

%% floor: the value is already in hand, no memo cell involved
loop_direct(_V, _Sz, _I, 0, Acc) -> Acc;
loop_direct(V, Sz, I, N, Acc) ->
    loop_direct(V, Sz, next_i(I, Sz), N - 1, Acc + element(I, V)).

%% control C: plain non-memoized thunk call
loop_plain(_T, 0, Acc) -> Acc;
loop_plain(T, N, Acc) -> loop_plain(T, N - 1, Acc + T()).

%% A hit: deref of an already realized delay
loop_pdict_hit(_P, _Sz, _I, 0, Acc) -> Acc;
loop_pdict_hit(P, Sz, I, N, Acc) ->
    V = case get(element(I, P)) of
            undefined -> 7;
            X -> X
        end,
    loop_pdict_hit(P, Sz, next_i(I, Sz), N - 1, Acc + V).

%% A miss, gross (erase pre-cleans the slot: get + thunk + put)
loop_pdict_miss(_P, _Sz, _I, 0, Acc, _T) -> Acc;
loop_pdict_miss(P, Sz, I, N, Acc, T) ->
    K = element(I, P),
    erase(K),
    V = case get(K) of
            undefined -> X = T(), put(K, X), X;
            Y -> Y
        end,
    loop_pdict_miss(P, Sz, next_i(I, Sz), N - 1, Acc + V, T).

%% A cleanup control (erase + thunk, no get/put)
loop_pdict_clean(_P, _Sz, _I, 0, Acc, _T) -> Acc;
loop_pdict_clean(P, Sz, I, N, Acc, T) ->
    erase(element(I, P)),
    loop_pdict_clean(P, Sz, next_i(I, Sz), N - 1, Acc + T(), T).

%% B hit: ets:lookup
loop_ets_hit(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_ets_hit(Tab, P, Sz, I, N, Acc) ->
    V = case ets:lookup(Tab, element(I, P)) of
            [{_, X}] -> X;
            [] -> 7
        end,
    loop_ets_hit(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + V).

%% B miss, gross (delete pre-cleans the row: lookup + thunk + insert)
loop_ets_miss(_Tab, _P, _Sz, _I, 0, Acc, _T) -> Acc;
loop_ets_miss(Tab, P, Sz, I, N, Acc, T) ->
    K = element(I, P),
    ets:delete(Tab, K),
    V = case ets:lookup(Tab, K) of
            [{_, X}] -> X;
            [] -> X1 = T(), ets:insert(Tab, {K, X1}), X1
        end,
    loop_ets_miss(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + V, T).

%% B cleanup control (delete + thunk)
loop_ets_clean(_Tab, _P, _Sz, _I, 0, Acc, _T) -> Acc;
loop_ets_clean(Tab, P, Sz, I, N, Acc, T) ->
    ets:delete(Tab, element(I, P)),
    loop_ets_clean(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + T(), T).

%% ETS CAS commit, gross (arm pending row + select_replace + drop row)
loop_cas_commit(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_cas_commit(Tab, P, Sz, I, N, Acc) ->
    K = element(I, P),
    ets:insert(Tab, {K, pending, undefined}),
    R = ets:select_replace(Tab, [{ {K, pending, '_'}, [], [{{K, done, 7}}] }]),
    ets:delete(Tab, K),
    loop_cas_commit(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + R).

%% ETS CAS arm control (insert pending + delete, no select_replace)
loop_cas_arm(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_cas_arm(Tab, P, Sz, I, N, Acc) ->
    K = element(I, P),
    ets:insert(Tab, {K, pending, undefined}),
    ets:delete(Tab, K),
    loop_cas_arm(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + 1).

%% ETS update_counter claim, gross (arm counter row + update_counter + drop)
loop_uc_claim(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_uc_claim(Tab, P, Sz, I, N, Acc) ->
    K = element(I, P),
    ets:insert(Tab, {K, 0, undefined}),
    _Old = ets:update_counter(Tab, K, {2, 1, 2, 2}, {K, 0, undefined}),
    ets:delete(Tab, K),
    loop_uc_claim(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + 1).

%% ETS claim CAS realized, gross: arm pending row, lookup, select_replace
%% pending -> claimed, plain insert of the realized value, drop the row
loop_claim_sr(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_claim_sr(Tab, P, Sz, I, N, Acc) ->
    K = element(I, P),
    ets:insert(Tab, {K, pending, undefined}),
    R = case ets:lookup(Tab, K) of
            [{_, done, V}] -> V;
            [{_, pending, _}] ->
                case ets:select_replace(Tab,
                                        [{{K, pending, '_'}, [], [{{K, claimed, undefined}}]}]) of
                    1 -> V2 = 7, ets:insert(Tab, {K, done, V2}), V2;
                    0 -> 7
                end
        end,
    ets:delete(Tab, K),
    loop_claim_sr(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + R).

%% ETS update_counter arm control
loop_uc_arm(_Tab, _P, _Sz, _I, 0, Acc) -> Acc;
loop_uc_arm(Tab, P, Sz, I, N, Acc) ->
    K = element(I, P),
    ets:insert(Tab, {K, 0, undefined}),
    ets:delete(Tab, K),
    loop_uc_arm(Tab, P, Sz, next_i(I, Sz), N - 1, Acc + 1).

%%%===================================================================
%%% micro driver
%%%===================================================================

micro() ->
    Pool = mk_pool(?POOL),
    Sz = tuple_size(Pool),
    Vals = list_to_tuple(lists:duplicate(?POOL, 7)),
    Tab = ets:new(memo_rc, [set, public, {read_concurrency, true}]),
    TabNoRc = ets:new(memo_plain, [set, public]),
    T = fun() -> 7 end,
    %% prime every cell so the "hit" loops really hit
    lists:foreach(fun(K) ->
                          ets:insert(Tab, {K, 7}),
                          ets:insert(TabNoRc, {K, 7}),
                          put(K, 7)
                  end, tuple_to_list(Pool)),
    Specs = [{"direct (value in hand)",
              fun() -> loop_direct(Vals, Sz, 1, ?ITERS, 0) end},
             {"C plain-thunk (control)",
              fun() -> loop_plain(T, ?ITERS, 0) end},
             {"A pdict hit (get)",
              fun() -> loop_pdict_hit(Pool, Sz, 1, ?ITERS, 0) end},
             {"A pdict miss (gross)",
              fun() -> loop_pdict_miss(Pool, Sz, 1, ?ITERS, 0, T) end},
             {"A pdict cleanup-ctrl",
              fun() -> loop_pdict_clean(Pool, Sz, 1, ?ITERS, 0, T) end},
             {"B ets hit (lookup, rc)",
              fun() -> loop_ets_hit(Tab, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets hit (lookup, no rc)",
              fun() -> loop_ets_hit(TabNoRc, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets miss (gross)",
              fun() -> loop_ets_miss(Tab, Pool, Sz, 1, ?ITERS, 0, T) end},
             {"B ets cleanup-ctrl",
              fun() -> loop_ets_clean(Tab, Pool, Sz, 1, ?ITERS, 0, T) end},
             {"B ets cas-commit (gross)",
              fun() -> loop_cas_commit(Tab, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets cas-arm-ctrl",
              fun() -> loop_cas_arm(Tab, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets claim-selrep (gross)",
              fun() -> loop_claim_sr(Tab, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets claim-uc (gross)",
              fun() -> loop_uc_claim(Tab, Pool, Sz, 1, ?ITERS, 0) end},
             {"B ets claim-uc-arm-ctrl",
              fun() -> loop_uc_arm(Tab, Pool, Sz, 1, ?ITERS, 0) end}],
    collect(?ITERS, Specs, [], #{}, []).

collect(_Iters, [], Names, Map, Sums) -> {Names, Map, Sums};
collect(Iters, [{Name, F} | Rest], Names, Map, Sums) ->
    {Best, S, Times} = bench(Iters, F),
    Row = {Iters, Best, Times, lists:sum(S)},
    collect(Iters, Rest, [Name | Names], Map#{Name => Row}, Sums ++ S).

%%%===================================================================
%%% printing
%%%===================================================================

print_rows(Names, Map) ->
    io:format("~n  ~-30s ~11s ~10s ~10s ~15s ~11s~n",
              ["benchmark", "iters", "best ns", "rep max", "ops/sec", "checksum"]),
    io:format("  ~s~n", [lists:duplicate(94, $-)]),
    lists:foreach(
      fun(N) ->
              {It, Best, Times, Sum} = maps:get(N, Map),
              io:format("  ~-30s ~11w ~10.2f ~10.2f ~15w ~11w~n",
                        [N, It, ns(Best, It), ns(lists:max(Times), It),
                         ops_sec(Best, It), Sum])
      end, lists:reverse(Names)).

ns(PerRep, Iters) -> PerRep / Iters.

row(Name, NsPerOp) ->
    io:format("  ~-40s ~10.2f ns/op ~13w ops/sec~n",
              [Name, NsPerOp, round(1000000000 / NsPerOp)]).

ratio(Name, R) -> io:format("  ~-40s ~11.2fx~n", [Name, R]).

best_ns(Map, Name) -> element(2, maps:get(Name, Map)).

sub3({_, B1, _, _}, {_, B2, _, _}, {_, B3, _, _}) -> B1 - B2 + B3.

print_derived_micro(Map) ->
    I = ?ITERS,
    D = fun(Name) -> ns(best_ns(Map, Name), I) end,
    PD = ns(sub3(maps:get("A pdict miss (gross)", Map),
                 maps:get("A pdict cleanup-ctrl", Map),
                 maps:get("C plain-thunk (control)", Map)), I),
    ET = ns(sub3(maps:get("B ets miss (gross)", Map),
                 maps:get("B ets cleanup-ctrl", Map),
                 maps:get("C plain-thunk (control)", Map)), I),
    CAS = ns(best_ns(Map, "B ets cas-commit (gross)") -
                 best_ns(Map, "B ets cas-arm-ctrl"), I),
    UC = ns(best_ns(Map, "B ets claim-uc (gross)") -
                best_ns(Map, "B ets claim-uc-arm-ctrl"), I),
    CSR = ns(best_ns(Map, "B ets claim-selrep (gross)") -
                 best_ns(Map, "B ets cas-arm-ctrl"), I),
    io:format("~n  derived per-op costs (gross minus matching cleanup control):~n"),
    row("A pdict miss  [get + thunk + put]", PD),
    row("B ets   miss  [lookup + thunk + insert]", ET),
    row("B ets   CAS   [select_replace]", CAS),
    row("B ets   claim [update_counter]", UC),
    row("B ets   exactly-once realize [l+claim+ins]", CSR),
    io:format("~n  ratios:~n"),
    ratio("ets hit / pdict hit",
          D("B ets hit (lookup, rc)") / D("A pdict hit (get)")),
    ratio("ets hit (no rc) / pdict hit",
          D("B ets hit (lookup, no rc)") / D("A pdict hit (get)")),
    ratio("ets miss / pdict miss", ET / PD),
    ratio("ets cas + miss / plain ets miss", (ET + CAS) / ET),
    ratio("ets claim + miss / plain ets miss", (ET + UC) / ET),
    ratio("ets plain realize / pdict realize", ET / PD),
    ratio("ets exactly-once / pdict (per realize)", CSR / PD),
    io:format("~n  note: ets:select_replace/2 (OTP 28) rejects pre-compiled match~n"
              "  specs, so the CAS parse cost is paid on every call; the cheap~n"
              "  guarded primitive is ets:update_counter/4.~n", []).

%%%===================================================================
%%% lazy chain
%%%===================================================================
%%%
%%% N lazy steps; step i is a cell whose thunk yields {Value, NextCell}.
%%% Realizing the head forces all N cells. "rewalk" re-realizes an
%%% already realized chain, i.e. a second consumer walking the same
%%% lazy structure: every step is a memo hit.

mk_chain(0) -> {done, []};
mk_chain(N) ->
    {Rest, Keys} = mk_chain(N - 1),
    K = make_ref(),
    Thunk = fun() -> {7, Rest} end,
    {{K, Thunk}, [K | Keys]}.

walk_pdict(done, _N, A) -> A;
walk_pdict(Cell, N, A) ->
    {_, Next} = realize_pdict(Cell),
    walk_pdict(Next, N - 1, A + 1).

walk_ets(_Tab, done, _N, A) -> A;
walk_ets(Tab, Cell, N, A) ->
    {_, Next} = realize_ets(Tab, Cell),
    walk_ets(Tab, Next, N - 1, A + 1).

erase_keys([]) -> ok;
erase_keys([K | T]) -> erase(K), erase_keys(T).

delete_keys(_Tab, []) -> ok;
delete_keys(Tab, [K | T]) -> ets:delete(Tab, K), delete_keys(Tab, T).

loop_cp_construct(_N, 0, Acc) -> Acc;
loop_cp_construct(N, Iters, Acc) ->
    {_Cell, Keys} = mk_chain(N),
    erase_keys(Keys),
    loop_cp_construct(N, Iters - 1, Acc + N).

loop_cp_first(_N, 0, Acc) -> Acc;
loop_cp_first(N, Iters, Acc) ->
    {Cell, Keys} = mk_chain(N),
    A = walk_pdict(Cell, N, 0),
    erase_keys(Keys),
    loop_cp_first(N, Iters - 1, Acc + A).

loop_cp_rewalk(_Cell, _N, 0, Acc) -> Acc;
loop_cp_rewalk(Cell, N, Iters, Acc) ->
    A = walk_pdict(Cell, N, 0),
    loop_cp_rewalk(Cell, N, Iters - 1, Acc + A).

loop_ce_construct(_Tab, _N, 0, Acc) -> Acc;
loop_ce_construct(Tab, N, Iters, Acc) ->
    {_Cell, Keys} = mk_chain(N),
    delete_keys(Tab, Keys),
    loop_ce_construct(Tab, N, Iters - 1, Acc + N).

loop_ce_first(_Tab, _N, 0, Acc) -> Acc;
loop_ce_first(Tab, N, Iters, Acc) ->
    {Cell, Keys} = mk_chain(N),
    A = walk_ets(Tab, Cell, N, 0),
    delete_keys(Tab, Keys),
    loop_ce_first(Tab, N, Iters - 1, Acc + A).

loop_ce_rewalk(_Tab, _Cell, _N, 0, Acc) -> Acc;
loop_ce_rewalk(Tab, Cell, N, Iters, Acc) ->
    A = walk_ets(Tab, Cell, N, 0),
    loop_ce_rewalk(Tab, Cell, N, Iters - 1, Acc + A).

chain() ->
    N = ?CHAIN_LEN,
    It = ?CHAIN_ITERS,
    Steps = N * It,
    Tab = ets:new(memo_chain, [set, public, {read_concurrency, true}]),
    {PCell, _} = mk_chain(N),
    _ = walk_pdict(PCell, N, 0),
    {ECell, _} = mk_chain(N),
    _ = walk_ets(Tab, ECell, N, 0),
    Specs = [{"A chain construct-ctrl",
              fun() -> loop_cp_construct(N, It, 0) end},
             {"A chain first-realize",
              fun() -> loop_cp_first(N, It, 0) end},
             {"A chain rewalk (memo hits)",
              fun() -> loop_cp_rewalk(PCell, N, It, 0) end},
             {"B chain construct-ctrl",
              fun() -> loop_ce_construct(Tab, N, It, 0) end},
             {"B chain first-realize",
              fun() -> loop_ce_first(Tab, N, It, 0) end},
             {"B chain rewalk (memo hits)",
              fun() -> loop_ce_rewalk(Tab, ECell, N, It, 0) end}],
    {Names, Map, Sums} = collect_chain(Specs, [], #{}, []),
    {Names, Map, Sums ++ [Steps]}.

collect_chain([], Names, Map, Sums) -> {Names, Map, Sums};
collect_chain([{Name, F} | Rest], Names, Map, Sums) ->
    {Best, S, Times} = bench(?CHAIN_ITERS, F),
    Row = {?CHAIN_LEN * ?CHAIN_ITERS, Best, Times, lists:sum(S)},
    collect_chain(Rest, [Name | Names], Map#{Name => Row}, Sums ++ S).

print_derived_chain(Map) ->
    Steps = ?CHAIN_LEN * ?CHAIN_ITERS,
    G = fun(N) -> element(2, maps:get(N, Map)) / Steps end,
    PD = G("A chain first-realize") - G("A chain construct-ctrl"),
    ET = G("B chain first-realize") - G("B chain construct-ctrl"),
    PW = G("A chain rewalk (memo hits)"),
    EW = G("B chain rewalk (memo hits)"),
    io:format("~n  derived per-step costs (chain cost minus construct control):~n"),
    row("A pdict first-realize / step", PD),
    row("B ets   first-realize / step", ET),
    row("A pdict rewalk / step (all hits)", PW),
    row("B ets   rewalk / step (all hits)", EW),
    ratio("ets first-realize / pdict first-realize", ET / PD),
    ratio("ets rewalk / pdict rewalk", EW / PW).

%%%===================================================================
%%% cross-process semantics
%%%===================================================================
%%%
%%% One delay cell is realized by 4 processes released at the same time.
%%% The thunk body bumps a shared counter and returns
%%% {pure_payload, 42, RunNo}, so we see both how often the body ran and
%%% whether observers of the same delay ended up with different values.

body_fun(Cnt, fast) ->
    fun() -> {pure_payload, 42, atomics:add_get(Cnt, 1, 1)} end;
body_fun(Cnt, slow) ->
    fun() -> timer:sleep(1), {pure_payload, 42, atomics:add_get(Cnt, 1, 1)} end.

semantics() ->
    TabP = ets:new(sem_plain, [set, public]),
    TabC = ets:new(sem_claim, [set, public]),
    io:format("~n  ~-10s ~-6s ~6s ~10s ~10s  ~s~n",
              ["strategy", "thunk", "body", "distinct", "agree", "reading"]),
    io:format("  ~s~n", [lists:duplicate(92, $-)]),
    sem_case("pdict", slow, fun(_K) -> ok end,
             fun(K, T) -> realize_pdict({K, T}) end),
    sem_case("ets-plain", slow, fun(_K) -> ok end,
             fun(K, T) -> ets_plain_realize(TabP, K, T) end),
    sem_case("ets-claim", slow,
             fun(K) -> ets:insert(TabC, {K, pending, undefined}) end,
             fun(K, T) -> ets_claim_realize(TabC, K, T) end),
    sem_case("pdict", fast, fun(_K) -> ok end,
             fun(K, T) -> realize_pdict({K, T}) end),
    sem_case("ets-plain", fast, fun(_K) -> ok end,
             fun(K, T) -> ets_plain_realize(TabP, K, T) end),
    sem_case("ets-claim", fast,
             fun(K) -> ets:insert(TabC, {K, pending, undefined}) end,
             fun(K, T) -> ets_claim_realize(TabC, K, T) end),
    io:format("~n  pure_payload is 42 in every run: pdict observers always agree~n"
              "  on the value, they only disagree on how often the body ran.~n", []),
    ok.

sem_case(Name, Mode, Setup, Realize) ->
    Cnt = atomics:new(1, [{signed, false}]),
    K = make_ref(),
    Setup(K),
    Vals = run_barrier(4, fun() -> Realize(K, body_fun(Cnt, Mode)) end),
    Runs = atomics:get(Cnt, 1),
    Distinct = length(lists:usort(Vals)),
    Reading = case {Name, Runs, Distinct} of
                  {"ets-plain", 1, 1} ->
                      "lucky: no race this run, NOT a guarantee";
                  {"ets-plain", _, 4} ->
                      "4 body runs, 4 different values: no guarantee";
                  {_, 4, 4} -> "per-process recompute, observers diverge";
                  {_, 4, 1} -> "recomputed per process, observers agree";
                  {_, 1, 1} -> "realize-once, shared by all processes";
                  {_, R, D} -> io_lib:format("runs=~B distinct=~B", [R, D])
              end,
    io:format("  ~-10s ~-6s ~6B ~10B ~10B  ~s~n",
              [Name, Mode, Runs, Distinct, Distinct, Reading]),
    case Distinct > 1 of
        false -> ok;
        true -> io:format("             observed: ~p~n", [lists:usort(Vals)])
    end.

%%%===================================================================
%%% ETS realize-once under concurrent realization
%%%===================================================================
%%%
%%% Four strategies are raced against each other on the same cell:
%%%   naive   lookup, compute, insert            -- no guarantee
%%%   commit  compute, select_replace pending->done -- one committed
%%%           value, but the body may run several times. On OTP 28 a
%%%           tuple cannot be carried literally in a match spec body
%%%           (see pitfall 1), so the value is boxed in a one-element
%%%           list and unboxed on read.
%%%   claim   select_replace pending->claimed first; the winner is the
%%%           only process allowed to run the body, losers spin until
%%%           the row turns into done  -- exactly once
%%%   uc      same, with ets:update_counter as the guarded primitive

cas_check() ->
    Tab = ets:new(cas_tab, [set, public]),
    io:format("~n  each round: ~B racers released by a barrier on one fresh cell.~n"
              "  'body' counts thunk evaluations (ideal = 1 per round),~n"
              "  'diverge' counts rounds where racers did not all see the same value.~n",
              [?RACERS]),
    _ = case_race("naive  lookup+insert  ", Tab, ?ROUNDS_SLOW, slow, naive),
    _ = case_race("naive  lookup+insert  ", Tab, ?ROUNDS_FAST, fast, naive),
    ComS = case_race("commit compute+CAS    ", Tab, ?ROUNDS_SLOW, slow, commit),
    ComF = case_race("commit compute+CAS    ", Tab, ?ROUNDS_FAST, fast, commit),
    ClmS = case_race("claim  select_replace ", Tab, ?ROUNDS_SLOW, slow, claim),
    ClmF = case_race("claim  select_replace ", Tab, ?ROUNDS_FAST, fast, claim),
    UcS = case_race("claim  update_counter ", Tab, ?ROUNDS_SLOW, slow, uc),
    UcF = case_race("claim  update_counter ", Tab, ?ROUNDS_FAST, fast, uc),
    CommitOk = element(3, ComS) andalso element(3, ComF),
    ClaimOk = element(2, ClmS) andalso element(2, ClmF) andalso
              element(2, UcS) andalso element(2, UcF),
    Pits = pitfalls(),
    case CommitOk andalso ClaimOk andalso Pits of
        true -> pass;
        false -> fail
    end.

case_race(Label, Tab, Rounds, Mode, Kind) ->
    Cnt = atomics:new(1, [{signed, false}]),
    Body = body_fun(Cnt, Mode),
    Setup = case Kind of
                naive -> fun(_K) -> ok end;
                uc -> fun(K) -> ets:insert(Tab, {K, 0, undefined}) end;
                _ -> fun(K) -> ets:insert(Tab, {K, pending, undefined}) end
            end,
    Realize = case Kind of
                 naive -> fun(K) -> ets_plain_realize(Tab, K, Body) end;
                 commit -> fun(K) -> ets_commit_realize(Tab, K, Body) end;
                 claim -> fun(K) -> ets_claim_realize(Tab, K, Body) end;
                 uc -> fun(K) -> ets_uc_realize(Tab, K, Body) end
             end,
    #{runs := Runs, diverge := Diverge, maxruns := Max, sample := Sample} =
        race_rounds(Rounds, ?RACERS, Cnt, Setup, Realize),
    ExactlyOnce = (Runs =:= Rounds) andalso (Diverge =:= 0),
    SingleValue = (Diverge =:= 0),
    Verdict = case Kind of
                  naive -> false;
                  commit -> SingleValue;
                  claim -> ExactlyOnce;
                  uc -> ExactlyOnce
              end,
    Text = case {Kind, Verdict} of
               {naive, _} ->
                   "FAIL (lookup+insert has no realize-once guarantee)";
               {commit, true} ->
                   "PASS (single committed value; body may repeat)";
               {commit, false} ->
                   "FAIL (observers disagreed)";
               {_, true} ->
                   "PASS (thunk body ran exactly once)";
               {_, false} ->
                   "FAIL (body ran more than once / observers disagreed)"
           end,
    io:format("~n  ~s [~p thunk, ~B rounds x ~B racers]~n"
              "      body evaluations: ~B (ideal ~B, worst round ~B), "
              "rounds with diverging observers: ~B~n"
              "      realize-once: ~s~n",
              [Label, Mode, Rounds, ?RACERS, Runs, Rounds, Max, Diverge, Text]),
    case Sample of
        [] -> ok;
        _ -> io:format("      sample of observed values: ~p~n", [Sample])
    end,
    {Verdict, ExactlyOnce, SingleValue}.

%% --- the realize strategies -------------------------------------

%% (0) no CAS: lookup, compute, insert -- must not be used
ets_plain_realize(Tab, K, Thunk) ->
    case ets:lookup(Tab, K) of
        [{_, V}] -> V;
        [] -> V = Thunk(), ets:insert(Tab, {K, V}), V
    end.

%% (1) commit CAS: everybody computes, one wins the row
ets_commit_realize(Tab, K, Thunk) ->
    case ets:lookup(Tab, K) of
        [{_, done, [V]}] -> V;
        [{_, pending, _}] ->
            V = Thunk(),
            MS = [{{K, pending, '_'}, [], [{{K, done, [V]}}]}],
            case ets:select_replace(Tab, MS) of
                1 -> V;
                0 -> await_boxed(Tab, K)
            end
    end.

%% (2) claim CAS: only the winner runs the body
ets_claim_realize(Tab, K, Thunk) ->
    case ets:lookup(Tab, K) of
        [{_, done, V}] -> V;
        [{_, claimed, _}] -> await_plain(Tab, K);
        [{_, pending, _}] ->
            case ets:select_replace(Tab,
                                    [{{K, pending, '_'}, [], [{{K, claimed, undefined}}]}]) of
                1 ->
                    V = Thunk(),
                    true = ets:insert(Tab, {K, done, V}),
                    V;
                0 -> await_plain(Tab, K)
            end
    end.

%% (3) claim with ets:update_counter. The counter saturates at 2, so the
%%     racer that moved it 0 -> 1 owns the computation. Which side of the
%%     increment update_counter returns changed in OTP 28, so the
%%     convention is probed once instead of hard-coded.
ets_uc_realize(Tab, K, Thunk) ->
    case ets:lookup(Tab, K) of
        [{_, _, done}] -> await_uc(Tab, K);
        [{_, _, undefined}] ->
            N = ets:update_counter(Tab, K, {2, 1, 2, 2}, {K, 0, undefined}),
            case uc_winner(N) of
                true ->
                    V = Thunk(),
                    true = ets:insert(Tab, {K, 1, V}),
                    V;
                false -> await_uc(Tab, K)
            end;
        _ -> await_uc(Tab, K)
    end.

uc_winner(N) ->
    case uc_returns_new() of
        true -> N =:= 1;      %% OTP >= 28 returns the post-increment value
        false -> N =:= 0      %% older OTP returns the pre-increment value
    end.

uc_returns_new() ->
    case get('$uc_returns_new') of
        undefined ->
            %% probe with exactly the operation the claim uses
            T = ets:new(uc_probe, [set]),
            K = make_ref(),
            ets:insert(T, {K, 0, undefined}),
            R = ets:update_counter(T, K, {2, 1, 2, 2}, {K, 0, undefined}),
            ets:delete(T),
            V = (R =:= 1),
            put('$uc_returns_new', V),
            V;
        V -> V
    end.

%% spin-wait for the winner; bounded so a lost row shows up as a
%% divergent value instead of hanging the benchmark
await_plain(Tab, K) -> await_plain(Tab, K, ?AWAIT_MAX).

await_plain(_Tab, _K, 0) -> await_timeout;
await_plain(Tab, K, N) ->
    case ets:lookup(Tab, K) of
        [{_, done, V}] -> V;
        _ -> await_plain(Tab, K, N - 1)
    end.

await_boxed(Tab, K) -> await_boxed(Tab, K, ?AWAIT_MAX).

await_boxed(_Tab, _K, 0) -> await_timeout;
await_boxed(Tab, K, N) ->
    case ets:lookup(Tab, K) of
        [{_, done, [V]}] -> V;
        _ -> await_boxed(Tab, K, N - 1)
    end.

await_uc(Tab, K) -> await_uc(Tab, K, ?AWAIT_MAX).

await_uc(_Tab, _K, 0) -> await_timeout;
await_uc(Tab, K, N) ->
    case ets:lookup(Tab, K) of
        [{_, _, undefined}] -> await_uc(Tab, K, N - 1);
        [{_, _, V}] when V =/= undefined -> V;
        _ -> await_uc(Tab, K, N - 1)
    end.

%%%===================================================================
%%% ETS CAS pitfalls a runtime has to know about (all checked here)
%%%===================================================================

is_exception({'EXIT', _}) -> true;
is_exception({error, _, _}) -> true;
is_exception(_) -> false.

pitfalls() ->
    T = ets:new(pit, [set, public]),
    %% 1: a tuple value cannot be carried literally in the body
    K1 = make_ref(),
    ets:insert(T, {K1, pending, undefined}),
    P1 = is_exception(catch ets:select_replace(
                        T, [{{K1, pending, '_'}, [], [{{K1, done, {lazy, seq, 1}}}]}])),
    %% ... but copying it out of the row with a match variable works
    K2 = make_ref(),
    ets:insert(T, {K2, pending, {lazy, seq, 1}}),
    R2 = ets:select_replace(T, [{{K2, pending, '$1'}, [], [{{K2, done, '$1'}}]}]),
    Row2 = ets:lookup(T, K2),
    P2 = (R2 =:= 1) andalso (Row2 =:= [{K2, done, {lazy, seq, 1}}]),
    %% 2: select_replace/2 rejects pre-compiled match specs
    K3 = make_ref(),
    ets:insert(T, {K3, pending, undefined}),
    P3 = is_exception(catch ets:select_replace(
                        T, [ets:match_spec_compile(
                              [{{K3, pending, '_'}, [], [{{K3, done, done}}]}])])),
    %% 3: update_counter's return convention depends on the OTP release
    P4 = is_boolean(uc_returns_new()),
    io:format("~n  ETS CAS pitfalls (each one is a runtime landmine, all re-checked here):~n"
              "      1 a tuple value in the select_replace body : ~s; "
              "copying it out with a match variable: ~s~n"
              "      2 a pre-compiled match spec in select_replace: ~s~n"
              "      3 ets:update_counter/4 returns ~s in this OTP~n",
              [case P1 of
                   true -> "badarg, as expected";
                   false -> "accepted, as expected"
               end,
               case P2 of
                   true -> "ok";
                   false -> "broken"
               end,
               case P3 of
                   true -> "badarg, as expected";
                   false -> "accepted, as expected"
               end,
               case uc_returns_new() of
                   true -> "the NEW value";
                   false -> "the OLD value"
               end]),
    P1 andalso P2 andalso P3 andalso P4.

%%%===================================================================
%%% race harness
%%%===================================================================

run_barrier(N, F) ->
    Parent = self(),
    Pids = [spawn(fun() ->
                          Parent ! {ready, self()},
                          receive go -> ok end,
                          R = try F() catch C:E -> {crash, C, E} end,
                          Parent ! {res, self(), R}
                  end) || _ <- lists:seq(1, N)],
    [receive {ready, P} -> ok end || P <- Pids],
    [P ! go || P <- Pids],
    [receive {res, P, V} -> V end || P <- Pids].

race_rounds(Rounds, Racers, Cnt, Setup, Realize) ->
    lists:foldl(
      fun(_, Acc) ->
              atomics:put(Cnt, 1, 0),
              K = make_ref(),
              Setup(K),
              Vals = run_barrier(Racers, fun() -> Realize(K) end),
              Runs = atomics:get(Cnt, 1),
              US = lists:usort(Vals),
              Diverge = case length(US) of
                            1 -> 0;
                            _ -> 1
                        end,
              Acc#{runs => maps:get(runs, Acc) + Runs,
                   diverge => maps:get(diverge, Acc) + Diverge,
                   maxruns => max(maps:get(maxruns, Acc), Runs),
                   sample => case {Diverge, maps:get(sample, Acc)} of
                                {0, _} -> maps:get(sample, Acc);
                                {_, []} -> US;
                                {_, _} -> maps:get(sample, Acc)
                            end}
      end, #{runs => 0, diverge => 0, maxruns => 0, sample => []},
      lists:seq(1, Rounds)).
