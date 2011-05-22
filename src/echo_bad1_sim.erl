%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% Echo server simulator (buggy)
%%%
%%% See usage example and discussion of simulator results in the file
%%% echo_bad1_sim.txt.
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
%%%
%%% Example usage:
%%%
%%% eqc:quickcheck(eqc:numtests(1*1000,slf_msgsim_qc:prop_simulate(echo_bad1_sim, []))).
%%%

-module(echo_bad1_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

-define(MAGIC_NUMBER, 13).

%%% Generators

%% required
gen_initial_ops(NumClients, NumServers, _NumKeys, _Props) ->
    list(gen_echo_op(NumClients, NumServers)).

gen_echo_op(NumClients, NumServers) ->
    ?LET({ClientI, ServerI},
         {choose(1, NumClients), choose(1, NumServers)},
         {lists:nth(ClientI, all_clients()),
          {echo_op, lists:nth(ServerI, all_servers()), int()}}).

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
                 "Predicted ~w\nActual ~w\n",
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
           %% conjunction([{runnable, Runnable == false},
           %%              {all_ok, slf_msgsim_qc:check_exact_msg_or_timeout(
           %%                         Clients, Predicted, Actual)}])
           Runnable == false andalso
               slf_msgsim_qc:check_exact_msg_or_timeout(
                 Clients, Predicted, Actual)
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

%% proto bad 1: An echo server.  Compared to the good echo_sim.erl,
%%              this server starts acting badly after it has received
%%              a magic number.

echo_client1({echo_op, Server, Key}, ReplyList) ->
    slf_msgsim:bang(Server, {echo, slf_msgsim:self(), Key}),
    {recv_timeout, fun echo_client1_echoreply/2, ReplyList}.

echo_client1_echoreply(timeout, ReplyList) ->
    {recv_general, same, [server_timeout|ReplyList]};
echo_client1_echoreply({echo_reply, Msg}, ReplyList) ->
    {recv_general, same, [Msg|ReplyList]}.

echo_server1({echo, Client, _Msg}, ?MAGIC_NUMBER = St) ->
    slf_msgsim:bang(Client, {echo_reply, St}),
    {recv_general, same, St};
echo_server1({echo, Client, ?MAGIC_NUMBER = Msg}, _St) ->
    slf_msgsim:bang(Client, {echo_reply, Msg}),
    {recv_general, same, Msg};
echo_server1({echo, Client, Msg}, St) ->
    slf_msgsim:bang(Client, {echo_reply, Msg}),
    {recv_general, same, St}.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].
