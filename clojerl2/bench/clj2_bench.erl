%%%-------------------------------------------------------------------
%%% @doc Embedding benchmarks (clojerl2-048): what a host pays to run a
%%% Clojure rule on its own data. `make bench' prints one line per case:
%%% microseconds per call (median of runs).
%%%-------------------------------------------------------------------
-module(clj2_bench).
-export([run/0]).

-define(N, 20000).

src() -> <<"
(ns bench.rules (:require [clojure.string :as str]))
(defn noop [x] x)
;; a streaming event: rewrite a delta's text when it holds a word
(defn on-event [ev ctx]
  (let [text (get-in ev [\"data\" \"choices\" 0 \"delta\" \"content\"])]
    (if (and text (str/includes? text \"secret\"))
      (assoc-in ev [\"data\" \"blocked\"] true)
      nil)))
;; a request: model map + a system message
(defn on-request [body ctx]
  (cond-> body
    (= (get body \"model\") \"gpt-4\") (assoc \"model\" \"gpt-4o\")
    true (update \"messages\" (fn [ms] (cons {\"role\" \"system\" \"content\" \"be brief\"} ms)))))
(defmulti route (fn [req] (get req \"kind\")))
(defmethod route \"chat\" [req] :chat)
(defmethod route :default [req] :other)
(defn rule [req] (cond (> (count (get req \"messages\")) 10) :long
                       (re-find #\"(?i)test\" (str (get req \"prompt\"))) :tests
                       :else (route req)))
">>.

run() ->
    ok = clj2:ensure(),
    {ok, Ns} = clj2:load(src()),
    M = clj2:module(Ns),
    Ev = #{<<"event">> => <<"message">>,
           <<"data">> => #{<<"choices">> => [#{<<"delta">> => #{<<"content">> => <<"hello world">>}}]}},
    Body = #{<<"model">> => <<"gpt-4">>,
             <<"messages">> => [#{<<"role">> => <<"user">>, <<"content">> => <<"hi">>} || _ <- lists:seq(1, 20)]},
    Req = #{<<"kind">> => <<"chat">>, <<"messages">> => [], <<"prompt">> => <<"write tests">>},
    Cases = [{"direct M:noop/1", fun() -> M:noop(1) end},
             {"clj2:call noop", fun() -> clj2:call(Ns, noop, [1]) end},
             {"on-event (no match)", fun() -> M:'on-event'(Ev, #{}) end},
             {"on-request (20 msgs)", fun() -> M:'on-request'(Body, #{}) end},
             {"rule (regex + multimethod)", fun() -> M:rule(Req) end},
             {"clj2_data:to_erl on-request result",
              fun() -> clj2_data:to_erl(M:'on-request'(Body, #{})) end}],
    [io:format("~-40s ~8.2f us~n", [Name, per_call(F)]) || {Name, F} <- Cases],
    ok.

per_call(F) ->
    _ = [F() || _ <- lists:seq(1, 1000)],                       % warm up
    Runs = [begin
                {T, _} = timer:tc(fun() -> loop(F, ?N) end),
                T / ?N
            end || _ <- lists:seq(1, 5)],
    lists:nth(3, lists:sort(Runs)).

loop(_, 0) -> ok;
loop(F, N) -> F(), loop(F, N - 1).
