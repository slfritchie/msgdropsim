%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%% Distributed strictly increasing counter simulation, phase 1 only,
%%% modified to try to be more "fair" in some circumstances.
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
-module(multiask_fairness_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

-record(c, {                                    % client state
          clop              :: 'undefined' | reference(),
          num_servers       :: integer(),
          num_responses = 0 :: integer(),
          ph1_oks = []      :: list(),
          ph1_sorrys = []   :: list(),
          ph2_val = 0       :: integer(),
          ph2_now           :: 'undefined' | {integer(), integer(), integer()}
         }).

-record(s, {                                    % server state
          val                :: integer(),
          asker              :: 'undefined' | atom(),
          cookie = undefined :: 'undefined' | reference()
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
    [{Clnt, #c{}, client_init} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    [{Server, #s{val = gen_nat_nat2(5, 1)}, server_unasked} ||
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
    Steps = slf_msgsim:get_step(Sched1),
    AllProcs = lists:sublist(all_clients(), 1, NumClients) ++
        lists:sublist(all_servers(), 1, NumServers),
    Unconsumed = lists:append([slf_msgsim:get_mailbox(Proc, Sched1) ||
                                  Proc <- AllProcs]),
    %% We need to sort the emitted events by "time", see comment
    %% below with "erlang:now()" in it.
    InnerUs = [Inner || {_Clnt, _Step, Inner} <- UTrc],
    Winners = [Client || {ph1_win, Client, _} <- InnerUs],
    Losers = [Client || {ph1_lose, Client, _} <- InnerUs],
    Waiters = [Client || {ph1_will_wait, Client, _} <- InnerUs],
    NumWinners = length(Winners),
    NumLosers = length(Losers),
    NumWaiters = length(Waiters),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd2 = ~P\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Win/Lose/Wait = ~w/~w/~w\n",
                 [F1, F2, Sched1, 250,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1),
                  NumWinners, NumLosers, NumWaiters]),
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("sched steps ", Steps,
       measure("crashes     ", NumCrashes,
       measure("# ops       ", length(Ops),
       measure("# winners   ", length(Winners),
       measure("# losers    ", length(Losers),
       measure("# waiters", length(Waiters),
       measure("msgs sent   ", NumMsgs,
       measure("msgs dropped", NumDrops,
       measure("timeouts    ", NumTimeouts,
       begin
           Runnable == false andalso
               Unconsumed == [] andalso
               NumWinners < 2 andalso
               NumWaiters < 2
       end))))))))))))).

%%% Protocol implementation

%% Message sequence diagram
%%
%% Try to create a 2-phase ask/do protocol that is also fair.  The
%% protocol that is simulated in "distrib_counter_2phase_sim.erl"
%% appears to be correct (simulator finds no faults), but it is
%% definitely not a fair protocol.  In cases of contention by a very
%% large number of clients, the protocol can starve most of those
%% clients for quite a while.
%%
%% My intention with this simulation module is to modify phase 1 (the
%% "ask" phase) of "distrib_counter_2phase_sim.erl to give enough
%% information to the clients so that they can figure out if one of
%% them is in a position where it knows that it will be able to
%% execute phase 2 soon.  Er, whatever "soon" means ... hopefully
%% something fair.
%%
%%     C1                          C2                          Server
%%                                 |-------- phase 1 ask ------->
%%                                 <- phase 1 ok + cookie + val-|
%%     |-------- phase 1 ask ----------------------------------->
%%     <-------- phase 1 sorry + my winner = C2 ----------------|
%%
%% However, this protocol cannot always choose a single runner-up.
%% For 3 clients and 3 servers:
%%   Client 1: Wins S1, loses S2 & S3 -> lose
%%   Client 2: Wins S2, loses S1 to C1 -> C2>C1 -> will_wait
%%   Client 3: Wins S3, loses S1 to C1 -> C3>C1 -> will_wait
%%
%% Despite my best intention, C2 and C3 don't know anything about each
%% other, so neither of them can calculate that it is best to abort.
%% I'd tried to find this combination via paper and pen, but the
%% counter-example eluded me.  It looks pretty obvious, in hindsight.
%%
%% Fairness, bah humbug.

client_init({counter_op, Servers}, _C) ->
    ClOp = make_ref(),
    [slf_msgsim:bang(Server, {ph1_ask, slf_msgsim:self(), ClOp}) ||
        Server <- Servers],
    {recv_timeout, client_ph1_waiting, #c{clop = ClOp,
                                          num_servers = length(Servers)}};
client_init(T, C) when is_tuple(T) ->
    {recv_general, same, C}.

client_ph1_waiting({ph1_ask_ok, ClOp, _Server, _Cookie, _Count} = Msg,
                   C = #c{clop = ClOp, num_responses = Resps, ph1_oks = Oks}) ->
    cl_p1_next_step(false, C#c{num_responses = Resps + 1,
                               ph1_oks       = [Msg|Oks]});
client_ph1_waiting({ph1_ask_sorry, ClOp, _Server, _LuckyClient} = Msg,
                   C = #c{clop = ClOp,
                          num_responses = Resps, ph1_sorrys = Sorrys}) ->
    cl_p1_next_step(false, C#c{num_responses = Resps + 1,
                               ph1_sorrys    = [Msg|Sorrys]});
client_ph1_waiting(timeout, C) ->
    cl_p1_next_step(true, C).

cl_p1_next_step(true = _TimeoutHappened, C) ->
    slf_msgsim:add_utrace({ph1_lose, slf_msgsim:self(), xyz_timeout}),
    {recv_general, client_consume_noop, C};
cl_p1_next_step(false, C = #c{num_responses = NumResps, ph1_sorrys = Sorrys}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            NumOks = length(C#c.ph1_oks),
            if NumOks >= Q ->
                    slf_msgsim:add_utrace({ph1_win, slf_msgsim:self(), xyz}),
                    {recv_general, client_consume_noop, C};
               true ->
                    OtherClients = [Cl || {ph1_ask_sorry, _, _, Cl} <- Sorrys],
                    {BiggestOtherClient, NumOtherOks} = find_biggest_other(
                                                          OtherClients),
                    Me = slf_msgsim:self(),
                    if %% NumOks > NumOtherOks orelse
                       %% (NumOks == NumOtherOks andalso
                       (NumOks >= NumOtherOks andalso
                        Me > BiggestOtherClient) ->
                            Extra = [{oks, C#c.ph1_oks},
                                     {sorrys, C#c.ph1_sorrys},
                                     {biggest_other, BiggestOtherClient},
                                     {num_other_oks, NumOtherOks}],
                            slf_msgsim:add_utrace({ph1_will_wait, Me, Extra}),
                            {recv_general, client_consume_noop, C};
                       true ->
                            slf_msgsim:add_utrace({ph1_lose, Me, xyz}),
                            {recv_general, client_consume_noop, C}
                    end
            end;
       true ->
            {recv_timeout, same, C}
    end.

client_consume_noop(_Msg, C) ->
    {recv_general, same, C}.

server_unasked({ph1_ask, From, ClOp}, S = #s{cookie = undefined}) ->
    S2 = send_ask_ok(From, ClOp, S),
    {recv_timeout, server_asked, S2};
server_unasked({ph2_do_set, From, ClOp, Cookie, Val}, S) ->
    slf_msgsim:bang(From, {error, ClOp, slf_msgsim:self(),
                           server_unasked, Cookie, Val}),
    {recv_general, same, S};
server_unasked({ph1_cancel, From, ClOp, _Cookie}, S) ->
    %% Late arrival, tell client it's OK, but really we ignore it
    slf_msgsim:bang(From, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    {recv_general, same, S}.

server_asked({ph2_do_set, From, ClOp, Cookie, Val}, S = #s{cookie = Cookie}) ->
    slf_msgsim:bang(From, {ok, ClOp, slf_msgsim:self(), Cookie}),
    {recv_general, server_unasked, S#s{asker = undefined,
                                       cookie = undefined,
                                       val = Val}};
server_asked({ph1_ask, From, ClOp}, S = #s{asker = Asker}) ->
    slf_msgsim:bang(From, {ph1_ask_sorry, ClOp, slf_msgsim:self(), Asker}),
    {recv_timeout, same, S};
server_asked({ph1_cancel, Asker, ClOp, Cookie}, S = #s{asker = Asker,
                                                       cookie = Cookie}) ->
    slf_msgsim:bang(Asker, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    server_asked(timeout, S); % lazy reuse
server_asked({ph1_cancel, From, ClOp, _Cookie}, S) ->
    %% Late arrival, tell client it's OK, but really we ignore it
    slf_msgsim:bang(From, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    {recv_timeout, same, S};
server_asked(timeout, S) ->
    {recv_general, server_unasked, S#s{asker = undefined,
                                       cookie = undefined}}.

send_ask_ok(From, ClOp, S = #s{val = Val}) ->
    Cookie = {cky,now()},
    slf_msgsim:bang(From, {ph1_ask_ok, ClOp, slf_msgsim:self(), Cookie, Val}),
    S#s{asker = From, cookie = Cookie}.

calc_q(#c{num_servers = NumServers}) ->
    (NumServers div 2) + 1.

find_biggest_other(Clients) ->
    [Biggest|_] = Cls = lists:reverse(lists:sort(Clients)),
    BiggestCls = [Cl || Cl <- Cls, Cl == Biggest],
    {Biggest, length(BiggestCls)}.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].
