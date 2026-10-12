%%%-------------------------------------------------------------------
%%% @doc The known-divergences registry, its evidence tests, the user docs
%%% and the corpus known-failures list agree (designs/04 §5.1,
%%% clojerl2-025). The gate itself (`make certify', clj2_corpus:certify/0)
%%% runs the whole corpus and is not an eunit test.
%%%-------------------------------------------------------------------
-module(clj2_divergences_tests).

-include_lib("eunit/include/eunit.hrl").

root() -> filename:join(filename:dirname(code:which(?MODULE)), "..").

entries() ->
    {ok, Bin} = file:read_file(filename:join([root(), "test", "known-divergences.edn"])),
    {ok, [Form], _} = clj2_reader:read_all(Bin),
    clj2_coll:to_list(clj2_form:to_data(Form)).

%% every entry says what, why (a design section, not just a task) and what
%% to write instead
registry_test() ->
    Entries = entries(),
    ?assert(length(Entries) > 0),
    Ids = [begin
               [?assert(is_binary(clj2_coll:get(E, K))) || K <- [':reason', ':design', ':alternative']],
               ?assertNotEqual(nomatch, binary:match(clj2_coll:get(E, ':design'), <<"§"/utf8>>)),
               ?assert(clj2_rt:is_keyword(clj2_coll:get(E, ':area'))),
               clj2_coll:get(E, ':id')
           end || E <- Entries],
    ?assertEqual(length(Ids), length(lists:usort(Ids))).

%% one evidence test per id, and no test without an id
%% (`:lazy-seq/no-chunking' → lazy_seq__no_chunking_test)
evidence_test() ->
    Expected = lists:sort([evidence_name(clj2_coll:get(E, ':id')) || E <- entries()]),
    Tests = lists:sort([F || {F, 0} <- clj2_divergence_evidence_tests:module_info(exports),
                             lists:suffix("_test", atom_to_list(F))]),
    ?assertEqual(Expected, Tests).

evidence_name(Id) ->
    [$: | Name] = atom_to_list(Id),
    list_to_atom(lists:flatten([case C of $/ -> "__"; $- -> "_"; _ -> C end || C <- Name]) ++ "_test").

%% the user documentation covers every registered divergence
docs_test() ->
    {ok, Doc} = file:read_file(filename:join([root(), "docs", "differences.md"])),
    Missing = [Id || E <- entries(), Id <- [clj2_coll:get(E, ':id')],
                     binary:match(Doc, atom_to_binary(Id)) =:= nomatch],
    ?assertEqual([], Missing).

known_failures_test() ->
    #{pending := Pending, entries := Known} = clj2_corpus:known_failures(),
    Causes = clj2_corpus:divergence_ids() ++ maps:keys(Pending),
    %% every pending cause says why and which task removes it
    [begin
         ?assert(is_binary(clj2_coll:get(Info, ':reason'))),
         ?assert(is_binary(clj2_coll:get(Info, ':task')))
     end || Info <- maps:values(Pending)],
    %% every listed failure has a registered cause ...
    ?assertEqual([], lists:usort([C || C <- maps:values(Known), not lists:member(C, Causes)])),
    %% ... and names a :common corpus entry
    Path = filename:join([filename:dirname(code:which(?MODULE)), "..", "test", "corpus.edn"]),
    Common = maps:from_list([{{S, L}, true} || #{suite := S, label := L, portability := common}
                                                   <- clj2_corpus:entries(Path)]),
    ?assertEqual([], [K || K <- maps:keys(Known), not maps:is_key(K, Common)]).

%% every override cites a registered divergence, names a :common row, and
%% changes its test or its expected value
overrides_test() ->
    Ids = clj2_corpus:divergence_ids(),
    Path = filename:join([root(), "test", "corpus.edn"]),
    Rows = maps:from_list([{{S, L}, E} || E = #{suite := S, label := L, portability := common}
                                           <- clj2_corpus:raw_entries_for_test(Path)]),
    Ovs = clj2_corpus:overrides(),
    ?assert(map_size(Ovs) > 0),
    [begin
         ?assert(lists:member(maps:get(because, O), Ids)),
         ?assert(is_map_key(K, Rows)),
         ?assert(is_map_key(actual, O) orelse is_map_key(expected, O) orelse maps:get(skip, O, false))
     end || {K, O} <- maps:to_list(Ovs)].

