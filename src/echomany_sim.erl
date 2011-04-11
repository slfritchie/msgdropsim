%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% Echo server simulator (bug-free)
%%%
%%% $ cd /path/to/top/of/msgdropsim
%%% $ make
%%% $ erl -pz ./ebin
%%% [...]
%%% > eqc:quickcheck(slf_msgsim_qc:prop_simulate(echomany_sim, [])).
%%% 
%%%
%%% The difference between echo_sim.erl and this module is that the
%%% clients are not tied to issuing their echo requests serially.
%%% Instead, they will send their requests as fast as they can and
%%% then receive the replies as they trickle in.
%%%
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
-module(echomany_sim).

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
                _Sched0, Runnable, Sched1, Trc, UTrc) ->
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumDelays = length([x || {delay,_,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd = ~p\n"
                 "Runnable = ~p, Receivable = ~p\n",
                 [F1, F2, Sched1,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1)]),
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("echoes      ", length(Ops),
       measure("msgs sent   ", NumMsgs,
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("msgs dropped", NumDrops,
       measure("msgs delayed", NumDelays,
       measure("timeouts    ", NumTimeouts,
       begin
           conjunction([{runnable, Runnable == false},
                        {order, order_ok_p(NumClients, NumServers, Trc, UTrc)}])
       end))))))))).

order_ok_p(NumClients, NumServers, Trc, UTrc) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    Servers = lists:sublist(all_servers(), 1, NumServers),
    X = [
         [begin
              Ops = [Op || {recv, _, scheduler, Clnt, Op} <- Trc,
                           Clnt == Client],
              ShouldBe = [Msg || {echo_op, Svr, Msg} <- Ops,
                                 Svr == Server],
              Got = [Msg || {Clnt, _, {Svr, Msg}} <- UTrc,
                            Clnt == Client, Svr == Server],
              if ShouldBe /= Got ->
                      {client, Client, server, Server,
                       should_be, ShouldBe, got, Got};
                 true ->
                      true
              end
          end || Server <- Servers]
         || Client <- Clients],
    case lists:flatten(X) of
        []   -> true;                           % No messages sent
        Flat -> equals(lists:usort(Flat), [true])
    end.

%%% Protocol implementation

%% proto 1: An echo server.  Not interesting by itself, but hopefully
%%           useful in figuring out how best to simulate dropped packets
%%           and timeouts.

echo_client1({echo_op, Server, Key}, Unused) ->
    slf_msgsim:bang(Server, {echo, slf_msgsim:self(), Key}),
    {recv_general, same, Unused};
echo_client1({echo_reply, Server, Msg}, Unused) ->
    slf_msgsim:add_utrace({Server, Msg}),
    {recv_general, same, Unused}.

echo_server1({echo, Client, Msg}, St) ->
    slf_msgsim:bang(Client, {echo_reply, slf_msgsim:self(), Msg}),
    {recv_general, same, St}.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].
