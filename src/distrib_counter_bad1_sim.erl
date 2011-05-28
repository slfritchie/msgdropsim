%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% Distributed strictly increasing counter simulation, #1 (buggy)
%%%
%%% See usage example and discussion of simulator results in the file
%%% distrib_counter_bad1_sim.txt.
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
%%% eqc:quickcheck(eqc:numtests(1*1000,slf_msgsim_qc:prop_simulate(distrib_counter_bad1_sim, []))).
%%%

-module(distrib_counter_bad1_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

%%% Generators

%% required
gen_initial_ops(NumClients, NumServers, _NumKeys, Props) ->
    ServerPids = proplists:get_value(server_pids, Props,
                                     lists:sublist(all_servers(), NumServers)),
    list(gen_counter_op(NumClients, ServerPids)).

gen_counter_op(NumClients, ServerPids) ->
    ?LET(ClientI, choose(1, NumClients),
         {lists:nth(ClientI, all_clients()),
          {counter_op, ServerPids}}).

%% required
gen_client_initial_states(NumClients, _Props) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    [{Clnt, [], counter_client1} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    [{Server, 0, counter_server1} || Server <- Servers].
    %% [{Server, gen_nat_nat2(5, 1), counter_server1} || Server <- Servers].

gen_nat_nat2(A, B) ->
    %% Use nat() A/(A+B) of the time, nat()*nat() B/(A+B) of the time
    slf_msgsim_qc:gen_nat_nat2(A, B).

%%% Verify our properties

%% required
verify_property(NumClients, NumServers, _Props, F1, F2, Ops,
                _Sched0, Runnable, Sched1, Trc, UTrc) ->
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    NumCrashes = length([x || {process_crash,_,_,_,_,_} <- Trc]),
    Emitted = [Count || {_Clnt,_Step,{counter,Count}} <- UTrc,
                        Count /= timeout],
    Steps = slf_msgsim:get_step(Sched1),
    Clients = lists:sublist(all_clients(), 1, NumClients),
    F_retro = fun(Clnt) ->
                      L = [Count || {Cl,_Step,{counter, Count}} <- UTrc,
                                    Count /= timeout, Cl == Clnt],
                      %% Retrograde counter?
                      L /= lists:usort(L)
              end,                                 
    ClientRetroP = lists:any(F_retro, Clients),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd2 = ~P\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Emitted counters = ~w\n",
                 [F1, F2, Sched1, 250,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1),
                  Emitted]),
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("sched steps ", Steps,
       measure("crashes     ", NumCrashes,
       measure("# ops       ", length(Ops),
       measure("# emitted   ", length(Emitted),
       measure("msgs sent   ", NumMsgs,
       measure("msgs dropped", NumDrops,
       measure("timeouts    ", NumTimeouts,
       begin
           %% conjunction([{runnable, Runnable == false},
           %%              {ops_finish, length(Ops) == length(UTrc)},
           %%              {emits_unique, length(Emitted) ==
           %%                            length(lists:usort(Emitted))},
           %%              {not_retro, Emitted == lists:sort(Emitted)}])
           Runnable == false andalso
               length(Ops) == length(UTrc) andalso
               not ClientRetroP
               %% old (see comments below + git commit log):
               %%   length(Emitted) == length(lists:usort(Emitted)) andalso
               %%   Emitted == lists:sort(Emitted)
       end))))))))))).

verify_mc_property(_NumClients, _NumServers, _ModProps, _F1, _F2,
                   Ops, ClientResults) ->
    AllEmitted = lists:flatten(ClientResults),
    EmittedByEach = [Val || {counter, Val} <- ClientResults],
    if length(Ops) == 10, length(ClientResults) > 3 ->
            io:format("\n~p\n", [ClientResults]);
       true ->
            ok 
    end,
    length(Ops) == length(AllEmitted) andalso
        [] == [x || EmitList <- EmittedByEach,
                    EmitList == lists:sort(EmitList),
                    EmitList == lists:usort(EmitList)].


%%% Protocol implementation

%% Known to be flawed: ask each server for its counter, then
%% choose the max of all responses.  The servers are naive
%% and are not keeping per-key counters but rather a single
%% counter for the entire server.
%%
%% A person could argue that the flaw here isn't "real" but is really
%% a matter of an honest race.  For example, testing with a maximum of
%% two clients and one server:
%%
%%    eqc:quickcheck(slf_msgsim_qc:prop_simulate(distrib_counter_bad1_sim, [{max_clients,2},{max_servers,1}, disable_partitions, disable_delays])).
%%
%% ... we can find an alleged violation of emitted counters:
%%
%%    Emitted counters = [1,0]
%%
%% If we look at the simulated timeline, this really looks like an
%% honest race, and a mere quirk of scheduling at time=8 didn't
%% schedule client c2 to emit its counter first and thus satisfy
%% verify_property().
%%
%%    Time 0: Client c2 starts its work on incrementing the counter
%%    Time 1: Client c1 starts its work on incrementing the counter
%%    Time 8: Client c1 emits counter = 1
%%    Time 9: Client c2 emits counter = 0
%%
%% That's a legitimate critique.  So, let's change the
%% verify_property() check to avoid this kind of horse race and
%% instead verify that counters are unique and that a counter is
%% always increasing from any individual client's point of view.
%%
%% ... Bummer, that doesn't work either.  Even when we disable
%% partitions and delayed messages.  Viewed with the most recent event
%% at the top:
%%
%%              {c2,17,{counter,14}}     <- emit event
%%              {recv,17,s2,c2,{incr_counter_reply,s2,14}},
%%                {c1,14,{counter,14}}   <- emit event
%%                {recv,14,s2,c1,{incr_counter_reply,s2,13}},
%%                {recv,12,s1,c1,{incr_counter_reply,s1,14}},
%%              {recv,7,s1,c2,{incr_counter_reply,s1,13}},
%%
%% Generated by: eqc:quickcheck(eqc:numtests(5*1000,slf_msgsim_qc:prop_simulate(distrib_counter_bad1_sim, [{max_clients,2},{max_servers,2}, disable_partitions, disable_delays]))).
%%
%% ... And then I find a bug in the "if" statement of:
%%         counter_client_1_reply(timeout, ...)

%% and with that bug fixed, and when I change the
%% gen_server_initial_states() to have all servers start with the same
%% state, there is *still* a problem with dropped messages.  For
%% example, using eqc:quickcheck(eqc:numtests(5*1000,slf_msgsim_qc:prop_simulate(distrib_counter_bad1_sim, [{max_clients,3},{max_servers,3}]))),
%% for 1 client, 3 servers, and 3 strategically-dropped messages,
%% a client can emit duplicate counters.

counter_client1({counter_op, Servers}, _St) ->
    [slf_msgsim:bang(Server, {incr_counter, slf_msgsim:self()}) ||
        Server <- Servers],
    {recv_timeout, counter_client1_reply, {Servers, []}}.

counter_client1_reply({incr_counter_reply, Server, Count},
                      {Waiting, Replies})->
    Replies2 = [{Server, Count}|Replies],
    case Waiting -- [Server] of
        [] ->
            Val = make_val(Replies2),
            slf_msgsim:add_utrace({counter, Val}),
            {recv_general, counter_client1, unused};
        Waiting2 ->
            {recv_timeout, same, {Waiting2, Replies2}}
    end;
counter_client1_reply(timeout, {Waiting, Replies}) ->
    Val = if length(Waiting) >= length(Replies) ->
                  timeout;
             true ->
                  make_val(Replies)
          end,
    slf_msgsim:add_utrace({counter, Val}),
    {recv_general, counter_client1, unused}.

counter_server1({incr_counter, From}, Count) ->
    slf_msgsim:bang(From, {incr_counter_reply, slf_msgsim:self(), Count}),
    {recv_general, same, Count + 1}.

make_val(Replies) ->
    lists:max([Counter || {_Server, Counter} <- Replies]).

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].

%%% Erlang direct style implementation

startup(client) ->
    fun e_counter_client/2;
startup(server) ->
    fun e_counter_server/2.

e_counter_client(Ops, State) ->
    [e_counter_client1(Op, State) || Op <- Ops].

e_counter_client1({counter_op, Servers}, _State) ->
    [my_bang(Server, {incr_counter, self()}) ||
        Server <- Servers],
    e_counter_client1_reply({Servers, []}).

e_counter_client1_reply({Waiting, Replies})->
    receive
        {incr_counter_reply, Server, Count} ->
            Replies2 = [{Server, Count}|Replies],
            case Waiting -- [Server] of
                [] ->
                    Val = make_val(Replies2),
                    {counter, Val};             % "emit"
                Waiting2 ->
                    e_counter_client1_reply({Waiting2, Replies2})
            end;
        shutdown ->
            shutdown
    after 100 ->
            Val = if length(Waiting) >= length(Replies) ->
                          timeout;
                     true ->
                          make_val(Replies)
                  end,
            {counter, Val}                      % "emit"
    end.

e_counter_server(_Ops, State) ->
    e_counter_server_loop(State).

e_counter_server_loop(Count) ->
    receive
        {incr_counter, From} ->
            my_bang(From, {incr_counter_reply, self(), Count}),
            e_counter_server_loop(Count + 1);
        shutdown ->
            Count
    end.
                
my_bang(Rcpt, Msg) ->
    %% mce_erl:choice([
    %%                 {fun() -> Rcpt ! Msg end, []},
    %%                 {fun() -> do_nothing end, []}
    %%                ]).
    Rcpt ! Msg.
