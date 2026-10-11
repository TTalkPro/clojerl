%%%-------------------------------------------------------------------
%%% @doc clj2_proc — receiving messages from Clojure code, until the
%%% `receive*' special form (designs/01 §1.2, designs/09 §2) lands.
%%% `receive' is Erlang syntax, not a function, so Clojure cannot call it
%%% through interop; these take the next message, in arrival order (no
%%% selective receive: match on the value after taking it).
%%%
%%%   (clj2_proc/receive_any)               the next message, waiting
%%%   (clj2_proc/receive_any 1000 :timeout) or :timeout after 1000 ms
%%%-------------------------------------------------------------------
-module(clj2_proc).

-export([receive_any/0, receive_any/2]).

receive_any() ->
    receive Msg -> Msg end.

receive_any(TimeoutMs, Default) when is_integer(TimeoutMs), TimeoutMs >= 0 ->
    receive Msg -> Msg
    after TimeoutMs -> Default
    end.
