%%%-------------------------------------------------------------------
%%% @doc The known-divergences registry is well formed (designs/04 §5).
%%% The corpus gate itself is clojerl2-022.
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
