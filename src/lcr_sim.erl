%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%%
%%% Simulation of the LCR leader election algorithm by Le Lann, Chang,
%%% and Roberts as presented in Nancy Lynch's _Distributed Algorithms_,
%%% pp. 27-31.  To be nitpicky, it's more accurate to say that this
%%% simulation emulates the AsyncLCR automaton on p. 477.
%%%
%%% Differences between this implementation and the Lynch's presentation:
%%%
%%% 1. Rather than naming processes by integer 'i', procs are named using
%%%    the Erlang atoms returned by the all_servers() function.
%%%    This requires a bit of gymnastics whenever we use lists:seq/2 or
%%%    nth_server() to map an integer to a server name, but the benefit
%%%    is that the server names make reading the trace logs much easier.
%%%
%%% 2. The slf_msgsim simulation framework requires that a process
%%%    must receive a message before it can do any computation.  This
%%%    is a hassle, but it's the way things are right now.  To work
%%%    around this limitation, the gen_initial_ops/4 callback sends a
%%%    'trigger_server_start' message to each of the servers; these
%%%    messages are delivered at the start of the simulation.
%%%
%%%    Each server is implemented with two functions:
%%%        * server_start/2, which waits for the trigger_server_start
%%%          message and, when received, moves execution to the
%%%          server_running/2 function.
%%%        * server_running/2, which executes the formal LCR algorithm
%%%          that is described on page 28.
%%%
%%%    The use of these two implementation functions is similar to the
%%%    Erlang/OTP coding style that uses the 'gen_fsm' behavior.
%%%
%%%    NOTE: This receive-before-first-computation pattern is,
%%%          coincidentally, exactly what's described in the 'Wakeups'
%%%          paragraph at the bottom of p. 481.
%%%
%%% 3. When run with the 'disable_partitions' option, the simulation is
%%%    run with reliable FIFO queues as communication channels: messages
%%%    are not corrupted, are not lost, are delivered in-order, and are
%%%    delivered without duplication.  (See the top of p. 460 for formal
%%%    and informal definitions of these four criteria.)
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
-module(lcr_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").
-include_lib("eunit/include/eunit.hrl").

-type server_name() :: s0 | s1 | s2 | s3 | s4 | s5 | s6 | s7 | s8 | s9.

-record(state, {
          neighbor :: server_name(),
          u        :: server_name(),
          send     :: null | server_name(),
          status   :: unknown | leader
         }).

%%% Example usage:

run_it(MaxServers) ->
    run_it(MaxServers, 100).

run_it(MaxServers, NumTests) ->
    Props = [disable_partitions, {max_servers, MaxServers}],
    io:format("Cut-and-paste this:\n  eqc:quickcheck(eqc:numtests(~p, slf_msgsim_qc:prop_simulate(~p, ~w))).\n\n", [NumTests, ?MODULE, Props]),
    io:format("NOTE: This algorithm cannot tolerate dropped messages, so\n"
              "      'disable_partitions' is a required option for good behavior.\n").

%%% Generators

%% required
gen_initial_ops(_NumClients, NumServers, _NumKeys, _Props) ->
    [{nth_server(Server), trigger_server_start} ||
        Server <- lists:seq(0, NumServers - 1)].

%% required
gen_client_initial_states(_NumClients, _Props) ->
    [].

%% required
gen_server_initial_states(NumServers, _Props) ->
    SvrNbrs = [{nth_server(N), nth_server((N+1) rem NumServers)} ||
                  N <- lists:seq(0, NumServers - 1)],
    [{Server, #state{neighbor = Neighbor, u = Server, send = null,
                     status = unknown}, fun server_start/2} ||
        {Server, Neighbor} <- SvrNbrs].

%%% Verify our properties

%% required
verify_property(_NumClients, NumServers, _Props, F1, F2, Ops,
                _Sched0, Runnable, Sched1, Trc, UTrc) ->
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd = ~p\n"
                 "Runnable = ~p, Receivable = ~p\n",
                 [F1, F2, Sched1,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1)]),
       measure("servers     ", NumServers,
       measure("num ops     ", length(Ops),
       measure("msgs sent   ", NumMsgs,
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("msgs dropped", NumDrops,
       measure("timeouts    ", NumTimeouts,
       begin
           conjunction([{runnable, Runnable == false},
                        {one_leader, one_leader_p(NumServers, UTrc)}])
       end))))))).

one_leader_p(NumServers, [{Server, _Seq, {i_am_leader, Server}} = _X]) ->
    Nth = nth_server(NumServers - 1),
    Server == Nth;
one_leader_p(_, _) ->
    false.

%%% Other required functions

%% required
all_servers() ->
    [s0, s1, s2, s3, s4, s5, s6, s7, s8, s9].

%% required
all_clients() ->
    [].

%%% Protocol implementation

server_start(trigger_server_start, S) ->
    slf_msgsim:bang(S#state.neighbor, {round_we_go, S#state.u}),
    {recv_general, fun server_running/2, S#state{send = S#state.u}}.

server_running({round_we_go, Name} = Msg, S) when Name > S#state.u ->
    slf_msgsim:bang(S#state.neighbor, Msg),
    {recv_general, same, S#state{send = Msg}};
server_running({round_we_go, Name}, S) when Name == S#state.u ->
    slf_msgsim:add_utrace({i_am_leader, S#state.u}),
    {recv_general, same, S#state{status = leader}};
server_running({round_we_go, _}, S) ->
    {recv_general, same, S}.

%%% Misc....

nth_server(N) ->
    lists:nth(N + 1, all_servers()).

%%% EUnit

-ifdef(TEST).

basic_test() ->
    Props = [disable_partitions,{max_servers,5}],
    true = eqc:quickcheck(
             eqc:numtests(1000, slf_msgsim_qc:prop_simulate(lcr_sim, Props))).

-endif.
