%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <fritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%%
%%% @end
%%% Created : 26 Mar 2011 by Scott Lystig Fritchie <fritchie@snookles.com>
%%%-------------------------------------------------------------------
-module(echo_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%%% Generators

%% required
gen_initial_ops(NumClients, NumServers, _NumKeys, _Props) ->
    list(gen_echo_op(NumClients, NumServers)).

gen_echo_op(NumClients, NumServers) ->
    ?LET({ClientI, ServerI},
         {choose(1, NumClients), choose(1, NumServers)},
         {lists:nth(ClientI, all_clients()),
          {echo_op, lists:nth(ServerI, all_servers()), make_ref()}}).

%% required
gen_client_initial_states(NumClients, _Props) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    [{Clnt, [], fun echo_client1/2} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    [{Server, {unused, Server}, fun echo_server1/2} || Server <- Servers].

%%% Verify our properties

%% required
verify_property(NumClients, NumServers, _Props, F1, F2, Ops,
                _Sched0, Runnable, Sched1, Trc, _UTrc) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    Predicted = predict_echos(Clients, Ops),
    Actual = actual_echos(Clients, Sched1),
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd = ~p\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Predicted ~p\nActual ~p\n",
                 [F1, F2, Sched1,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1),
                  Predicted, Actual]),
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("echoes      ", length(Ops),
       measure("msgs sent   ", NumMsgs,
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("msgs dropped", NumDrops,
       measure("timeouts    ", NumTimeouts,
       begin
           conjunction([{runnable, Runnable == false},
                        {all_ok, slf_msgsim_qc:check_exact_msg_or_timeout(
                                   Clients, Predicted, Actual)}])
       end)))))))).    

predict_echos(Clients, Ops) ->
    [{Client, begin
                ClientOps = [Op || {Cl, Op} <- Ops, Cl == Client],
                [Msg || {echo_op, _Server, Msg} <- ClientOps]
            end} || Client <- Clients].

actual_echos(Clients, Sched) ->
    [{Client, lists:reverse(slf_msgsim:get_proc_state(Client, Sched))} ||
        Client <- Clients].

%%% Protocol implementation

%% proto 1: An echo server.  Not interesting by itself, but hopefully
%%           useful in figuring out how best to handle dropped packets
%%           and timeouts.

echo_client1({echo_op, Server, Key}, ReplyList) ->
    slf_msgsim:bang(Server, {echo, slf_msgsim:self(), Key}),
    {recv_timeout, fun echo_client1_echoreply/2, ReplyList}.

echo_client1_echoreply(timeout, ReplyList) ->
    {recv_general, same, [server_timeout|ReplyList]};
echo_client1_echoreply({echo_reply, Msg}, ReplyList) ->
    {recv_general, same, [Msg|ReplyList]}.

echo_server1({echo, Client, Msg}, St) ->
    slf_msgsim:bang(Client, {echo_reply, Msg}),
    {recv_general, same, St}.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].

all_keys() ->
    [k1, k2, k3, k4, k5, k6, k7, k8, k9].

