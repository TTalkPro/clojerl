%%%-------------------------------------------------------------------
%%% @doc The known-divergences registry and the corpus known-failures list
%%% are well formed (designs/04 §5). The gate itself (`make certify',
%%% clj2_corpus:certify/0) runs the whole corpus and is not an eunit test.
%%%-------------------------------------------------------------------
-module(clj2_divergences_tests).

-include_lib("eunit/include/eunit.hrl").

registry_test() ->
    Path = filename:join([filename:dirname(code:which(?MODULE)), "..", "test", "known-divergences.edn"]),
    {ok, Bin} = file:read_file(Path),
    {ok, [Form], _} = clj2_reader:read_all(Bin),
    Entries = clj2_coll:to_list(clj2_form:to_data(Form)),
    ?assert(length(Entries) > 0),
    Ids = [begin
               [?assert(is_binary(clj2_coll:get(E, K))) || K <- [':reason', ':design']],
               ?assert(clj2_rt:is_keyword(clj2_coll:get(E, ':area'))),
               clj2_coll:get(E, ':id')
           end || E <- Entries],
    ?assertEqual(length(Ids), length(lists:usort(Ids))),
    ?assert(lists:member(':lazy-seq/per-process-realization', Ids)).

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
