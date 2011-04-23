%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% Distributed strictly increasing counter simulation, using a 2-phase
%%% protocol.
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
-module(distrib_counter_2phase_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

-record(c, {                                    % client state
          num_servers       :: integer(),
          num_responses = 0 :: integer(),
          ph1_oks = []      :: list(),
          ph1_sorrys = []   :: list(),
          ph2_val = 0       :: integer()
         }).

-record(s, {                                    % server state
          val                :: integer(),
          asker              :: 'undefined' | atom(),
          cookie = undefined :: 'undefined' | reference(),
          waiting = []       :: list
         }).

t(MaxClients, MaxServers) ->
    eqc:quickcheck(slf_msgsim_qc:prop_simulate(distrib_counter_2phase_sim, [{max_clients, MaxClients}, {max_servers, MaxServers}, disable_partitions])).

%%% Generators

%% required
gen_initial_ops(NumClients, NumServers, _NumKeys, _Props) ->
    list(gen_counter_op(NumClients, NumServers)).

gen_counter_op(NumClients, NumServers) ->
    ?LET(ClientI, choose(1, NumClients),
         {lists:nth(ClientI, all_clients()),
          {counter_op, lists:sublist(all_servers(), NumServers)}}).

%% required
gen_client_initial_states(NumClients, _Props) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    [{Clnt, #c{}, fun client_init/2} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    [{Server, #s{val = gen_nat_nat2(5, 1)}, fun server_unasked/2} ||
        Server <- Servers].

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
           Runnable == false andalso
           length(Ops) == length(UTrc) andalso
           length(Emitted) == length(lists:usort(Emitted)) andalso
           Emitted == lists:sort(Emitted)
           %% conjunction([{runnable, Runnable == false},
           %%              {ops_finish, length(Ops) == length(UTrc)},
           %%              {emits_unique, length(Emitted) ==
           %%                            length(lists:usort(Emitted))},
           %%              {not_retro, Emitted == lists:sort(Emitted)}])
       end))))))))))).

%%% Protocol implementation

client_init({counter_op, Servers}, _St) ->
    [slf_msgsim:bang(Server, {ph1_ask, slf_msgsim:self()}) ||
        Server <- Servers],
    {recv_timeout, fun client_ph1_waiting/2, #c{num_servers = length(Servers)}}.

client_ph1_waiting({ph1_ask_ok, _Server, _Cookie, _Count} = Msg,
                   C = #c{num_responses = Resps, ph1_oks = Oks}) ->
    cl_p1_next_step(false, C#c{num_responses = Resps + 1,
                               ph1_oks       = [Msg|Oks]});
client_ph1_waiting({ph1_ask_sorry, _Server, _LuckyClient} = Msg,
                   C = #c{num_responses = Resps, ph1_sorrys = Sorrys}) ->
    cl_p1_next_step(false, C#c{num_responses = Resps + 1,
                               ph1_sorrys    = [Msg|Sorrys]});
client_ph1_waiting(timeout, C) ->
    cl_p1_next_step(true, C).

cl_p1_next_step(true = _TimeoutHappened, C) ->
    {recv_general, fun client_init/2, C};
cl_p1_next_step(false, C = #c{num_responses = NumResps}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            cl_p1_send_do(C);
       true ->
            {recv_timeout, same, C}
    end.

client_ph2_waiting({ok, _Server, _Cookie},
                   C = #c{num_responses = NumResps, ph2_val = Val}) ->
    if length(C#c.ph1_oks) /= NumResps ->
            {recv_timeout, same, C#c{num_responses = NumResps + 1}};
       true ->
            slf_msgsim:add_utrace({counter, Val}),
            {recv_general, fun client_init/2, C}
    end;
client_ph2_waiting({ph1_ask_ok, Server, Cookie, _ValDoesNotMatter} = Msg,
                   C = #c{ph1_oks = Oks, ph2_val = Val}) ->
    slf_msgsim:bang(Server, {ph2_do_set, slf_msgsim:self(), Cookie, Val}),
    {recv_timeout, same, C#c{ph1_oks = [Msg|Oks]}};
client_ph2_waiting(timeout, C = #c{num_responses = NumResps, ph2_val = Val}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            slf_msgsim:add_utrace({counter, Val});
       true ->
            ok
    end,
    {recv_general, fun client_init/2, C}.

server_unasked({ph1_ask, From}, S = #s{cookie = undefined}) ->
    S2 = send_ask_ok(From, S),
    {recv_timeout, fun server_asked/2, S2};
server_unasked({ph2_do, From, Cookie, Val}, S) ->
    slf_msgsim:bang(From, {error, slf_msgsim:self(),
                           server_unasked, Cookie, Val}),
    {recv_general, same, S}.

server_asked({ph2_do_set, From, Cookie, Val}, S = #s{cookie = Cookie,
                                                     waiting = Waiting}) ->
    slf_msgsim:bang(From, {ok, slf_msgsim:self(), Cookie}),
    case Waiting of
        [Head|Ws] ->
            S2 = S#s{cookie = undefined, val = Val, waiting = Ws},
            S3 = send_ask_ok(Head, S2),
            {recv_timeout, same, S3};
        [] ->
            S2 = S#s{cookie = undefined, val = Val},
            {recv_general, fun server_unasked/2, S2}
    end;
server_asked({ph1_ask, From}, S = #s{asker = Asker}) ->
    slf_msgsim:bang(From, {ph1_ask_sorry, slf_msgsim:self(), Asker}),
    {recv_timeout, same, S}.

send_ask_ok(From, S = #s{val = Val}) ->
    Cookie = make_ref(),
    slf_msgsim:bang(From, {ph1_ask_ok, slf_msgsim:self(), Cookie, Val}),
    S#s{asker = From, cookie = Cookie}.

cl_p1_send_do(C = #c{ph1_oks = Oks}) ->
    [{_, _, _, MaxVal}|_] = lists:keysort(4, Oks),
    NewVal = MaxVal + 1,
    [slf_msgsim:bang(Svr, {ph2_do_set, slf_msgsim:self(), Cookie, NewVal}) ||
        {ph1_ask_ok, Svr, Cookie, _Val} <- Oks],
    {recv_timeout, fun client_ph2_waiting/2, C#c{num_responses = 0,
                                                 ph2_val = NewVal}}.

make_val(Replies) ->
    lists:max([Counter || {_Server, Counter} <- Replies]).

calc_q(#c{num_servers = NumServers}) ->
    (NumServers div 2) + 1.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].
