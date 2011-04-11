%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% QuickCheck foundations for the message passing &amp; dropping simulator.
%%% @end
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%-------------------------------------------------------------------

-module(slf_msgsim_qc).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%%% Generators

gen_scheduler_list(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({L1, UnfairL, SlowProcs, Seed},
         {list(elements(Both)),
          gen_unfair_list(Both),
          frequency([{4, []},
                     {1, non_empty(list(elements(Both)))}]),
          gen_seed()},
         begin
             L2 = lists:filter(fun(X) -> not lists:member(X, SlowProcs) end,
                               UnfairL ++ L1),
             Missing = [Proc || Proc <- Both,
                                not lists:member(Proc, L2)],
             L2 ++ shuffle(Missing, Seed)
         end).

gen_unfair_list(L) ->
    frequency([{1, []},
               {1, ?LET(SubL, non_empty(list(elements(L))),
                        resize(80, list(elements(SubL))))},
               {1, ?LET(SubL, non_empty(list(elements(L))),
                        resize(500, list(elements(SubL))))}]).

gen_server_partitions(Module, ModProps, NumClients, NumServers) ->
    case proplists:get_value(disable_partitions, ModProps, false) of
        true ->
            [];
        false ->
            ?LET(Parts,
                 non_empty(list(gen_partition(Module, NumClients, NumServers))),
                 lists:flatten(Parts))
    end.

gen_partition(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({Direction, Froms, Tos, Start, Len},
         {oneof([s_to_c, c_to_s, both]),
          my_list_elements(Both), my_list_elements(Both),
          gen_nat_nat2(10, 1), gen_nat_nat2(30, 1)},
         case Direction of
             s_to_c ->
                 [{partition, Froms, Tos, Start, Start + Len}];
             c_to_s ->
                 [{partition, Tos, Froms, Start, Start + Len}];
             both ->
                 [{partition, Froms, Tos, Start, Start + Len},
                  {partition, Tos, Froms, Start, Start + Len}]
         end).

gen_message_delays(Module, _ModProps, NumClients, NumServers) ->
    list(gen_delay(Module, NumClients, NumServers)).

gen_delay(Module, NumClients, NumServers) ->
    Clients = lists:sublist(Module:all_clients(), 1, NumClients),
    Servers = lists:sublist(Module:all_servers(), 1, NumServers),
    Both = Clients ++ Servers,
    ?LET({Froms, Tos, Start, Len, DelayRounds},
         {my_list_elements(Both), my_list_elements(Both),
          gen_nat_nat2(10, 1), gen_nat_nat2(30, 1), nat()},
         {delay, lists:usort(Froms), lists:usort(Tos),
          Start, Start + Len, DelayRounds + 1}).

gen_nat_nat2(A, B) ->
    frequency([{A, nat()},
               {B, ?LET({X,Y}, {nat(), nat()}, (X+1)*(Y+1))}]).

gen_seed() ->
    noshrink({largeint(), largeint(), largeint()}).

gen_initial_counter() ->
    frequency([{10, 1},
               {10, nat()},
               { 1, ?LET({X, Y},
                         {nat(), nat()},
                         X * Y)}]).

shuffle(L, Seed) ->
    random:seed(Seed),
    lists:sort(fun(_, _) -> random:uniform(100) < 50 end, L).

apply_msg_drops(Rpcs, DropList) ->
    NumRpcs = length(Rpcs),
    T = lists:foldl(fun({drop, Nth, c_to_s}, DT) when Nth =< NumRpcs ->
                            RPC = element(Nth, DT),
                            setelement(Nth, DT,
                                       filter_drop(RPC, {drop_noop, RPC}));
                       ({drop, Nth, s_to_c}, DT)  when Nth =< NumRpcs ->
                            RPC = element(Nth, DT),
                            setelement(Nth, DT,
                                       filter_drop(RPC, {drop_reply, RPC}));
                       (_, DT) ->
                            DT
                    end, list_to_tuple(Rpcs), DropList),
    tuple_to_list(T).

filter_drop({_, _, sched_barrier} = Old, _New) ->
    Old;
filter_drop(_Old, New) ->
    New.

delete_all(X, L) ->
    [Y || Y <- L, Y /= X].

apply_net_partitions(Rpcs, PartitionList) ->
    NumRpcs = length(Rpcs),
    lists:flatten(
      [
       [{drop, N, Type} || N <- lists:seq(StartN, EndN),
                             N < NumRpcs,
                             {_, _, rpc, ask, Svr, _} <- [lists:nth(N, Rpcs)],
                             Svr == Server]
       || {partition, Server, StartN, EndN, Type} <- PartitionList]).

counters_to_floats(Counters) ->
    Counters2 = [re:replace(C, "[^0-9.]", "0", [global, {return,list}]) ||
                    C <- Counters],
    [list_to_float(C) || C <- Counters2].

%% Very strict:
%% counters_are_increasing(Floats) ->
%%     Floats == lists:sort(Floats).

counters_are_increasing(Floats) ->
    try
        lists:foldl(fun(N, Last) ->
                            true = (trunc(N) >= Last),
                            trunc(N)
                    end, -9999999999999, Floats),
        true
    catch _:_ ->
            false
    end.
                        
%%% Protocols to test

%% proto 1: Known to be flawed: ask each server for its counter, then
%%          choose the max of all responses.  The servers are naive
%%          and are not keeping per-key counters but rather a single
%%          counter for the entire server.

counter_client1({counter_op, Key, Servers}, _St) ->
    [slf_msgsim:bang(Server, {incr_counter, Key, slf_msgsim:self()}) ||
        Server <- Servers],
    {recv_timeout, fun counter_client1_reply/2, {Servers, Servers, []}}.

counter_client1_reply({incr_counter_reply, Server, Count},
                      {AllServers, Waiting, Replies})->
    Replies2 = [{Server, Count}|Replies],
    case Waiting -- [Server] of
        [] ->
            Val = make_val(AllServers, Replies2),
            slf_msgsim:add_utrace({counter, Val}),
            {recv_general, same, unused};
        Waiting2 ->
            {recv_timeout, same, {AllServers, Waiting2, Replies2}}
    end;
counter_client1_reply(timeout, {AllServers, Waiting, Replies}) ->
    Val = if length(Waiting) > length(Replies) ->
                  timeout;
             true ->
                  make_val(AllServers, Replies)
          end,
    slf_msgsim:add_utrace({counter, Val}),
    {recv_general, same, unused}.

counter_server1({incr_counter, _Key, From}, Count) ->
    slf_msgsim:bang(From, {incr_counter_reply, slf_msgsim:self(), Count}),
    {recv_general, same, Count + 1}.

make_val(AllServers, Replies) ->
    Ns = [N || {_Server, N} <- Replies],
    ByN = lists:sort([{N, Server} || {Server, N} <- Replies]),
    SvrOrder = [Server || {_N, Server} <- ByN],
    LHS_int = lists:max(Ns),
    Left = integer_to_list(LHS_int),
    Right = make_suffix(AllServers, SvrOrder),
    Left ++ "." ++ Right.

make_suffix(AllServers, ReplyServers) ->
    lists:append(make_suffix2(AllServers, ReplyServers)).

make_suffix2(AllServers, ReplyServers) ->
    Padding = ["__" || _ <- lists:seq(1, length(AllServers) - length(ReplyServers))],
    [atom_to_list(Svr) || Svr <- ReplyServers] ++ Padding.

check_exact_msg_or_timeout(Clients, Predicted, Actual) ->
    lists:all(
      fun(Client) ->
              Pred = proplists:get_value(Client, Predicted),
              Act = proplists:get_value(Client, Actual),
              lists:all(fun({X, X}) ->               true;
                           ({_X, server_timeout}) -> true;
                           (_)                    -> false
                        end, lists:zip(Pred, Act))
      end, Clients).                                

prop_simulate(Module, ModProps) ->
    MinClients = proplists:get_value(min_clients, ModProps, 1),
    MaxClients = proplists:get_value(max_clients, ModProps, 5),
    MinServers = proplists:get_value(min_servers, ModProps, 1),
    MaxServers = proplists:get_value(max_servers, ModProps, 5),
    MinKeys = proplists:get_value(min_keys, ModProps, 1),
    MaxKeys = proplists:get_value(max_keys, ModProps, 1),
    ?FORALL({NumClients, NumServers, NumKeys} = F1,
            {my_choose(MinClients, MaxClients),
             my_choose(MinServers, MaxServers),
             my_choose(MinKeys, MaxKeys)},
    ?FORALL({Ops, ClientInits, ServerInits, SchedList,
             PartitionList, DelayList} = F2,
            {Module:gen_initial_ops(NumClients, NumServers, NumKeys, ModProps),
             Module:gen_client_initial_states(NumClients, ModProps),
             Module:gen_server_initial_states(NumServers, ModProps),
             gen_scheduler_list(Module, NumClients, NumServers),
             gen_server_partitions(Module, ModProps, NumClients, NumServers),
             gen_message_delays(Module, ModProps, NumClients, NumServers)},
            begin
                Sched0 = slf_msgsim:new_sim(ClientInits, ServerInits, Ops,
                                            SchedList, PartitionList,
                                            DelayList),
                {Runnable, Sched1} = slf_msgsim:run_scheduler(Sched0),
                Trc = slf_msgsim:get_trace(Sched1),
                UTrc = slf_msgsim:get_utrace(Sched1),
                Module:verify_property(NumClients, NumServers, ModProps,
                                       F1, F2, Ops,
                                       Sched0, Runnable, Sched1, Trc, UTrc)
            end
           )).

my_choose(_, 0) ->
    0;
my_choose(N, M) ->
    choose(N, M).

my_list_elements([]) ->
    [];
my_list_elements(L) ->
    list(elements(L)).

