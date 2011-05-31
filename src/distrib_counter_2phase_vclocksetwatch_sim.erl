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
%%%
%%% Example usage:
%%%
%%% eqc:quickcheck(eqc:numtests(1*1000,slf_msgsim_qc:prop_simulate(distrib_counter_2phase_vclocksetwatch_sim, []))).
%%%

-module(distrib_counter_2phase_vclocksetwatch_sim).

-compile(export_all).

%% -define(TIMEOUT, 250).
-define(TIMEOUT, 30*1000).

-include_lib("eqc/include/eqc.hrl").

-record(c, {                                    % client state
          clop              :: 'undefined' | reference(),
          num_servers       :: integer(),
          num_responses = 0 :: integer(),
          ph1_oks = []      :: list(),
          %% counter-related items
          ph1_sorrys = []   :: list(),
          ph2_val = 0       :: integer(),
          ph2_now           :: 'undefined' | {integer(), integer(), integer()},
          %% watch-related items
          watchers = []     :: [{atom(), ClOp::term()}],
          watchers2 = []    :: [{atom(), ClOp::term()}]
         }).

-record(obj, {
          %% key = undefined,
          vclock             :: vclock:vclock(),
          contents           :: [integer()]
         }).

-record(s, {                                    % server state
          val                :: #obj{},
          asker              :: 'undefined' | atom(),
          cookie = undefined :: 'undefined' | reference(),
          %% watch-related items
          watchers = []      :: [{atom(), ClOp::term()}]
         }).

t(MaxClients, MaxServers) ->
    eqc:quickcheck(slf_msgsim_qc:prop_simulate(
                     ?MODULE, [{max_clients, MaxClients},
                               {max_servers, MaxServers},
                               disable_partitions])).

%%% Generators

%% required
gen_initial_ops(NumClients, NumServers, _NumKeys, _Props) ->
    list(elements([gen_counter_op(NumClients, NumServers),
                   gen_watch_op(NumClients, NumServers)])).

gen_counter_op(NumClients, NumServers) ->
    ?LET(ClientI, choose(1, NumClients),
         {lists:nth(ClientI, all_clients()),
          {counter_op, lists:sublist(all_servers(), NumServers)}}).

gen_watch_op(NumClients, NumServers) ->
    ?LET(ClientI, choose(1, NumClients),
         {lists:nth(ClientI, all_clients()),
          {watch_op, lists:sublist(all_servers(), NumServers)}}).

%% required
gen_client_initial_states(NumClients, _Props) ->
    Clients = lists:sublist(all_clients(), 1, NumClients),
    [{Clnt, #c{}, client_init} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    %% TODO: See comment "Item-1" below for advice on #obj.contents init'n
    [{Server,
      #s{val = #obj{vclock = vclock:fresh(),
                    %% contents = [gen_nat_nat2(5, 1)]}},
                    contents = [0]}},
      server_unasked} ||
        Server <- Servers].

gen_nat_nat2(A, B) ->
    %% Use nat() A/(A+B) of the time, nat()*nat() B/(A+B) of the time
    slf_msgsim_qc:gen_nat_nat2(A, B).

%%% Verify our properties

%% required
verify_property(NumClients, NumServers, _Props, F1, F2, Ops,
                _Sched0, Runnable, Sched1, Trc, UTrc) ->
    CounterOps = [Op || {_, {counter_op, _}} = Op <- Ops],
    WatchOps = [Op || {_, {watch_op, _}} = Op <- Ops],
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumDelays = length([x || {delay,_,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    NumCrashes = length([x || {process_crash,_,_,_,_,_} <- Trc]),
    %% We need to sort the emitted events by "time", see comment
    %% below with "erlang:now()" in it.
    Emitted0 = [Inner ||
                   {_Clnt, _Step, Inner = {counter, _Now, Count, _Ws}} <- UTrc,
                   Count /= timeout],
    Emitted1 = lists:keysort(2, Emitted0),
    Emitted2 = [{counter, Now, hd(Z#obj.contents), Ws} ||
                   {counter, Now, Z, Ws} <- Emitted1],
    Emitted = [Count || {counter, _Now, Count, _Ws} <- Emitted2],
    Phase1QuorumFails = [x || {_Clnt,_Step,{ph1_quorum_failure,_,_,_}} <- UTrc],
    Phase2Timeouts = [x || {_Clnt,_Step,{timeout_phase2, _, _}} <- UTrc],
    Steps = slf_msgsim:get_step(Sched1),
    AllProcs = lists:sublist(all_clients(), 1, NumClients) ++
        lists:sublist(all_servers(), 1, NumServers),
    Unconsumed = lists:append([get_mailbox(Proc, Sched1) || Proc <- AllProcs]),
    UncondDelayed = length([x || {delay,_,_,_,{unconditional_set,_,_,_},_Rounds} <- Trc]),
    UncondSent  = length([x || {_,_,{unconditional_set_sent}} <- UTrc]),
    UncondOrig  = length([x || {_,_,{unconditional_set, orig}} <- UTrc]),
    UncondNew   = length([x || {_,_,{unconditional_set, new}} <- UTrc]),
    UncondOther = length([x || {_,_,{unconditional_set, other}} <- UTrc]),
    WatchTimeouts = length([x || {_,_,{watch_timeout, _}} <- UTrc]),
    WatchOks = length([x || {_,_,{watch_notify, _, _}} <- UTrc]),
    WatchMaybes = length([x || {_,_,{watch_notify_maybe, _, _}} <- UTrc]),

    %% Start the LTL-wanna-be by gathering up some useful stuff.
    CounterStartZs = [{Step,Z} || {_,Step,{counter_start_ph2,_,Z}} <- UTrc],
    CounterDefiniteZs =  [{Step,Z,Ws} || {_,Step,{counter, _, Z, Ws}} <- UTrc],
    WatchSetupStartClOps =
        [{Step,ClOp} || {_,Step,{watch_setup_start,ClOp,_}} <- UTrc],
    WatchSetupDoneClOps =
        [{Step,ClOp} || {_,Step,{watch_setup_done,ClOp,_}} <- UTrc],
    WatchNotifyClOps =
        [{Step,ClOp,Z} || {_,Step,{watch_notify,ClOp,Z}} <- UTrc],
    WatchNotifyMaybeClOps =
        [{Step,ClOp,Z} || {_,Step,{watch_notify_maybe,ClOp,Z}} <- UTrc],
    WatchTimeoutClOps =
        [{Step,ClOp} || {_,Step,{watch_timeout,ClOp}} <- UTrc],

    %% Baby step: If a {watch_notify,ClOp,_} is present,
    %%            then a {watch_setup_done,ClOp,_} must be present earlier.
    %%     TODO: How the heck do I express that in LTL, when there
    %%           isn't an "earlier" operator.  This definitely isn't right:
    %%               [] (watch_setup_done -> <> watch_notify)
    %%
    %%           Hmmm ... How about this, abusing the notation (if not the
    %%           very idea) of a predicate?
    %%               For all ClOp elements of watch_notify event list,
    %%               [] (watch_setup_done(ClOp) -> <> watch_notify(ClOp))
    C1 = [{X, Y} || {LaterStep,   ClOp_l, _Z} = X <- WatchNotifyClOps,
                    {EarlierStep, ClOp_e}     = Y <- WatchSetupDoneClOps,
                    ClOp_e == ClOp_l,
                    EarlierStep > LaterStep],         % negate the desired cond!

    %% Baby step: If a {watch_notify_maybe,ClOp,_} is present,
    %%            then a {watch_setup_start,ClOp,_} must be present earlier.
    C2 = [{X, Y} || {LaterStep,   ClOp_l, _Z} = X <- WatchNotifyMaybeClOps,
                    {EarlierStep, ClOp_e}     = Y <- WatchSetupStartClOps,
                    ClOp_e == ClOp_l,
                    EarlierStep > LaterStep],         % negate the desired cond!

    %% More interesting: If a {watch_notify,_,Z} is present,
    %%                   then a {counter,_,Z,_} must be present earlier.
    C3 = [{X, Y} || {LaterStep,_,Z_l}   = X <- WatchNotifyClOps,
                    {EarlierStep,Z_e,_} = Y <- CounterDefiniteZs,
                    Z_e == Z_l,
                    EarlierStep > LaterStep],         % negate the desired cond!

    %% More interesting: If a {watch_maybe,_,Z} is present,
    %%                   then a {counter_start_ph2,_,Z} must be present earlier.
    C4 = [{X, Y} || {LaterStep,_,Z_l} = X <- WatchNotifyMaybeClOps,
                    {EarlierStep,Z_e} = Y <- CounterStartZs,
                    Z_e == Z_l,
                    EarlierStep > LaterStep],         % negate the desired cond!

    %% More interesting: If a {watch_timeout,ClOp} is present, then there
    %% must not be any {counter_start_ph2,_,Z} events between the time that the
    %% watch was definitely setup ({watch_setup_done,...}) and the timeout.
    C5 = [{X,Y,Z} || {SetupDoneStep,ClOp_d} = Y <- WatchSetupDoneClOps,
                     {TimeoutStep,  ClOp_t} = X <- WatchTimeoutClOps,
                     ClOp_d == ClOp_t,
                     {Ph2Step,_,_Z}         = Z <- CounterStartZs,
                     SetupDoneStep =< Ph2Step andalso Ph2Step =< TimeoutStep],

    %% More interesting: If a {watch_timeout,ClOp} is present, then ClOp must
    %% not be present in any Watchers in {counter,_,_Z,Watchers} list.

    %% Its intent: we want the watch mechanism to always deliver a
    %% notification to a watcher, definite or maybe, whenever a key has
    %% changed.
    %%
    %% Ha, this one proves more interesting.  Here's a counterexample:
    %%   * three servers, one client
    %%   * ops: watch, increment
    %%   * network partition: one message dropped (see below).
    %%   Sequence of events:
    %%     1. Set up the watch
    %%     2. A network partition drops the {watch_setup_resp,...} message
    %%        from server S1.  Servers S2 and S3 ack the watch setup without
    %%        a problem.
    %%     3. The watch times out, because there isn't any other client to
    %%        perform an increment.
    %%     4. The client sends {watch_cancel_req,...} messages to S2 and S3.
    %%        No cancel is sent to S1 because of the network partition in
    %%        step #2.
    %%     5. Now the client performs an increment.
    %%     6. Server S1's sends {ph2_ok, _ClOp, Watchers}, where Watchers
    %%        contains the watch setup request from step #1.
    %%     7. The C6 list below finds the "bad combination".
    %%
    %% In reality, the sequence events above isn't an error: C6's calculation
    %% is faulty.  We need to add an additional check, i.e., that the timeout
    %% happens *after* the watch setup.
    %%
    %% Also, there is an honest race between the watch setup and the end
    %% of the increment phase 2.  To disambiguate, we must only test watch
    %% timeouts that were *definitely* setup before the end of incr phase 2.
    %%
    %% Also, there's the possibility that a). an increment client gets a
    %% timeout while waiting for phase 2 responses and decides that the op
    %% was successful, and b). a watcher client in client_watch_waiting state
    %% gets a timeout at the same time and gives up (and cancels its watch
    %% requests).  The notification from the increment client in step a) will
    %% arrive at the watcher proc "late".  We need to consider the late
    %% arrival as OK: it isn't our fault if the client doesn't wait around
    %% long enough for the change notification to arrive.  :-)

    LateWatchNotifyReqClOps =
        [ClOp || {_,_,{late_watch_notify_req,ClOp,_Z}} <- UTrc],
    C6 = [{X,Y,Z} || {Step_d,ClOp_d}      = X <- WatchSetupDoneClOps,
                     {Step_c,_Z,Watchers} = Y <- CounterDefiniteZs,
                     {Step_t,ClOp_t}      = Z <- WatchTimeoutClOps,
                     Step_d < Step_c,               %% extra check, see comments
                     ClOp_t == ClOp_d,              %% honest race fixer part 1
                     Step_t > Step_c,               %% honest race fixer part 2
                     {_Client, ClOp_w} <- Watchers,
                     ClOp_t == ClOp_w andalso
                         not lists:member(ClOp_d, LateWatchNotifyReqClOps)],

    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd2 = ~P\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Emitted counters = ~w\n"
                 "CounterOps ~p ?= Emitted ~p + Phase1QuorumFails ~p + Phase2Timeouts ~p\n"
                 "# Unconsumed ~p, NumCrashes ~p\n"
                 "C1 = ~p, C2 = ~p, C3 = ~p, C4 = ~p, C5 = ~p\n"
                 "C6 = ~p LateWatchNotifyReqClOps = ~p\n",
                 [F1, F2, Sched1, 250,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1),
                  Emitted,
                  length(CounterOps), length(Emitted), length(Phase1QuorumFails), length(Phase2Timeouts),
                  length(Unconsumed), NumCrashes,
                  C1, C2, C3, C4, C5,
                  C6, LateWatchNotifyReqClOps]),
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("sched steps ", Steps,
       measure("crashes     ", NumCrashes,
       measure("# ops       ", length(Ops),
       measure("# emitted   ", length(Emitted),
       measure("# ph1 q.fail", length(Phase1QuorumFails),
       measure("# ph2 t.out ", length(Phase2Timeouts),
       measure("msgs sent   ", NumMsgs,
       measure("msgs dropped", NumDrops,
       measure("msgs delayed", NumDelays,
       measure("timeouts    ", NumTimeouts,
       measure("uncond sent ", UncondSent,
       measure("uncond delay", UncondDelayed,
       measure("uncond=orig ", UncondOrig,
       measure("uncond=new  ", UncondNew,
       measure("uncond=other", UncondOther,
       measure("watch ops   ", length(WatchOps),
       measure("watch oks   ", WatchOks,
       measure("watch maybes", WatchMaybes,
       measure("watch t.out ", WatchTimeouts,
       begin
           Runnable == false andalso
           length(CounterOps) == length(Emitted) +
               length(Phase1QuorumFails) +
               length(Phase2Timeouts) andalso
               length(Emitted) == length(lists:usort(Emitted)) andalso
               Emitted == lists:sort(Emitted) andalso
               Unconsumed == [] andalso
               NumCrashes == 0 andalso
               %% LTL-like time
               C1 == [] andalso C2 == [] andalso C3 == [] andalso
               C4 == [] andalso C5 == [] andalso C6 == []
       end))))))))))))))))))))))).

verify_mc_property(NumClients, _NumServers, ModProps, _F1, _F2,
                   Ops, ClientResults) ->
    %% io:format(user, "v", []),
    true. %% SLF_TODO_fixme_vacuously_true.

%%% Protocol implementation

%% Message sequence diagram
%%
%% Clients C1 and C2 are trying to update a key simultaneously on
%% servers S1 and S2.  Several requests, including C1 -> S2 and all
%% messages with server S3, are not shown because those extra messages
%% do not demonstrate any new types of protocol messages.  An odd
%% number of servers is recommended because phase 1 of this protocol
%% requires that a client acquire a quorum of phase 1 ok responses
%% before that client is permitted to execute phase 2 of the protocol.
%%
%% Phase 1 cancel requires that the client wait for all phase 1 cancel
%% responses before the client is allowed to continue.
%%
%% In the example below:
%%
%% a. C1 wins the race to S1 and therefore gets a phase 1 ok.
%% b. C2 loses the race to S1 and gets a 'sorry' response.
%% c. C2 won the race with S2, but since S2 doesn't have a quorum of
%%    phase 1 ok responses, C2 must send a phase 1 cancel to the servers
%%    that it *did* get phase 1 ok responses from.
%% d. Assuming that C1 got a quorum of phase 1 ok responses, C1 uses
%%    phase 2 to set the new value on all servers that gave C1 a phase 1
%%    ok responses.
%%
%% 
%%         C1                          C2             C3           S1       S2
%% Steps a & b:
%%         |-------- phase 1 ask ----------------------------------->
%%                                     |-------- phase 1 ask ------->
%%                                     |-------- phase 1 ask ---------------->
%%         <-------- phase 1 ok + cookie + current value V0 --------|
%%                                     <-------- phase 1 sorry -----|
%%                                     <--- phase 1 ok + cookie + curval Vx -|
%% Step c:
%%                                     |-------- phase 1 cancel + cookie ---->
%%                                     <-------- phase 1 cancel ok ----------|
%% Step d:
%%         |-------- phase 2 set + cookie + new value V1 ----------->
%%         <-------- phase 2 ok + list of watchers (e.g. client C3) ---------|
%%         |----------- change notification ---------->|
%%         |<----- change notification response -------|

client_init({counter_op, Servers}, _C) ->
    %% The clop/ClOp is short for "Client Operation".  It's used in
    %% a manner similar to gen_server's reference() tag: the ClOp is
    %% used to avoid receiving messages that are late, i.e. messages
    %% that have been delayed or have been received after we made an
    %% important state transition.  If we don't restrict our match/receive
    %% pattern in this way, then messages that arrive late can cause
    %% very hard-to-reproduce errors.  (Well, hard if we didn't have
    %% QuickCheck to help reproduct them.  :-)
    ClOp = make_ref(),
    [slf_msgsim:bang(Server, {ph1_ask, slf_msgsim:self(), ClOp}) ||
        Server <- Servers],
    {recv_timeout, client_ph1_waiting, #c{clop = ClOp,
                                          num_servers = length(Servers)}};
client_init({watch_op, Servers}, _C) ->
    ClOp = make_ref(),
    slf_msgsim:add_utrace({watch_setup_start, ClOp, slf_msgsim:self()}),
    [slf_msgsim:bang(Server, {watch_setup_req, slf_msgsim:self(), ClOp}) ||
        Server <- Servers],
    {recv_timeout, client_watch_setup, #c{clop = ClOp,
                                          num_servers = length(Servers)}};
client_init({watch_notify_req, ClOp, From, Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:add_utrace({late_watch_notify_req, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, same, C};
client_init({watch_notify_maybe_req, ClOp, From, Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:add_utrace({late_watch_notify_maybe_req, Z}),
    slf_msgsim:bang(From, {watch_notify_maybe_resp,
                           slf_msgsim:self(), ClOp, ok}),
    {recv_general, same, C};
client_init(T, C) when is_tuple(T) ->
    %% In all other client states, our receive contain a guard based
    %% on ClOp, so any message that we see here in client_init that
    %% isn't a 'counter_op' message and is a tuple is something that
    %% arrived late in a prior 'counter_op' request.  We don't care
    %% about them, but we should consume them.
    {recv_general, same, C}.

%%% Client counter-related states

client_ph1_waiting({ph1_ask_ok, ClOp, _Server, _Cookie, _Z} = Msg,
                   C = #c{clop = ClOp, num_responses = Resps, ph1_oks = Oks}) ->
    cl_p1_next_step(C#c{num_responses = Resps + 1, ph1_oks = [Msg|Oks]});
client_ph1_waiting({ph1_ask_sorry, ClOp, _Server, _LuckyClient} = Msg,
                   C = #c{clop = ClOp,
                          num_responses = Resps, ph1_sorrys = Sorrys}) ->
    cl_p1_next_step(C#c{num_responses = Resps + 1, ph1_sorrys = [Msg|Sorrys]});
client_ph1_waiting(timeout, C) ->
    %% Fake like we got responses from all servers ... plus a few extra.
    cl_p1_next_step(C#c{num_responses = 9999999999}).

client_ph1_cancelling({ph1_cancel_ok, ClOp, Server},
                      C = #c{clop = ClOp, ph1_oks = Oks}) ->
    NewOks = lists:keydelete(Server, 3, Oks),
    if NewOks == [] ->
            {recv_general, client_init, #c{}};
       true ->
            {recv_timeout, same, C#c{ph1_oks = NewOks}}
    end;
client_ph1_cancelling(timeout, C) ->
    cl_p1_send_cancels(C).

cl_p1_next_step(C = #c{num_responses = NumResps}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            NumOks = length(C#c.ph1_oks),
            if NumOks >= Q ->
                    cl_p1_send_do(C);
               true ->
                    slf_msgsim:add_utrace({ph1_quorum_failure, slf_msgsim:self(), num_oks, NumOks}),
                    if NumOks == 0 ->
                            {recv_general, client_init, #c{}};
                       true ->
                            cl_p1_send_cancels(C)
                    end
            end;
       true ->
            {recv_timeout, same, C}
    end.

cl_p1_send_cancels(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    [slf_msgsim:bang(Server, {ph1_cancel, slf_msgsim:self(), ClOp, Cookie}) ||
        {ph1_ask_ok, _ClOp, Server, Cookie, _Z} <- Oks],
    {recv_timeout, client_ph1_cancelling, C}.

%% TODO: Is it necessary for for _all_ of the client counter-related
%%       states to explicitly handle the watch_notify*_req messages to
%%       avoid deadlock?  See commit log for more deadlock info....

client_ph2_waiting({ph2_ok, ClOp, Watchers},
                   C = #c{clop = ClOp,
                          num_responses = NumResps, ph2_val = Z,
                          watchers = Ws}) ->
    NewWatchers = lists:usort(Watchers ++ Ws),
    if length(C#c.ph1_oks) /= NumResps + 1 ->
            {recv_timeout, same, C#c{num_responses = NumResps + 1,
                                     watchers = NewWatchers}};
       true ->
            slf_msgsim:add_utrace({counter, C#c.ph2_now, Z, NewWatchers}),
            if NewWatchers == [] ->
                    {recv_general, client_init, #c{}};
               true ->
                    NewC = C#c{watchers = NewWatchers,
                               watchers2 = NewWatchers},
                    cl_send_notifications(NewC),
                    {recv_timeout, client_notif_resp_waiting, NewC}
            end
    end;
client_ph2_waiting({ph1_ask_ok, ClOp, Server, Cookie, _Z} = Msg,
                   C = #c{clop = ClOp, ph1_oks = Oks, ph2_val = Z}) ->
    slf_msgsim:bang(Server, {ph2_do_set, slf_msgsim:self(), ClOp, Cookie, Z}),
    {recv_timeout, same, C#c{ph1_oks = [Msg|Oks]}};
%% next 2 clauses, first bugfix for McErlang??
client_ph2_waiting({watch_notify_req, ClOp, From, Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:add_utrace({late_watch_notify_req, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, same, C};
client_ph2_waiting({watch_notify_maybe_req, ClOp, From, Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:add_utrace({late_watch_notify_maybe_req, Z}),
    slf_msgsim:bang(From, {watch_notify_maybe_resp,
                           slf_msgsim:self(), ClOp, ok}),
    {recv_general, same, C};
client_ph2_waiting(timeout, C = #c{num_responses = NumResps, ph2_val = Z,
                                   watchers = Ws}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            slf_msgsim:add_utrace({counter, C#c.ph2_now, Z, lists:usort(Ws)}),
            cl_send_notifications(C),
            {recv_timeout, client_notif_resp_waiting, C};
       true ->
            slf_msgsim:add_utrace({timeout_phase2, slf_msgsim:self(), Z}),
            {recv_general, client_init, #c{}}
    end.

cl_send_notifications(#c{watchers = Ws, ph2_val = Z}) ->
    [slf_msgsim:bang(Client, {watch_notify_req, ClOp, slf_msgsim:self(), Z}) ||
        {Client, ClOp} <- lists:usort(Ws)].

client_notif_resp_waiting({watch_notify_resp, Client, ClOp, ok},
                           C = #c{num_servers = NumServers, watchers = Ws}) ->
    case Ws -- [{Client, ClOp}] of
        [] ->
            [slf_msgsim:bang(Server, {watch_notifies_delivered, Ws}) || 
                Server <- lists:sublist(all_servers(), 1, NumServers)],
            {recv_general, client_init, #c{}};
        NewWs ->
            {recv_timeout, same, C#c{watchers = NewWs}}
    end;
client_notif_resp_waiting(timeout, C = #c{watchers = Ws}) ->
    if Ws == [] ->
            {recv_general, client_init, #c{}};
       true ->
            cl_send_notifications(C),
            {recv_timeout, same, C}
    end;
client_notif_resp_waiting({watch_notify_req, ClOp, From, Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:add_utrace({late_watch_notify_req, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_timeout, same, C};
client_notif_resp_waiting({watch_notify_maybe_req, ClOp, From, _Z}, C) ->
    %% Race: this arrived late, need to respond to it, though.
    slf_msgsim:bang(From, {watch_notify_maybe_resp,
                           slf_msgsim:self(), ClOp, ok}),
    {recv_timeout, same, C};
client_notif_resp_waiting({ph1_ask_sorry, _, _, _}, C) ->
    %% Race: this arrived late.  But we need to consume it, otherwise we
    %%       won't get a timeout message when we need one
    {recv_timeout, same, C}.

%%% Client watch-related states

client_watch_setup({watch_setup_resp, ClOp, _Server, ok} = Msg,
                   C = #c{clop = ClOp,
                          num_responses = NumResps0, ph1_oks = Oks0}) ->
    NumResps = NumResps0 + 1,
    Oks = [Msg|Oks0],
    NewC = C#c{num_responses = NumResps, ph1_oks = Oks},
    Q = calc_q(C),
    NumResps = length(Oks),             % sanity check
    if NumResps >= Q ->
            slf_msgsim:add_utrace({watch_setup_done, ClOp, slf_msgsim:self()}),
            {recv_timeout, client_watch_waiting, NewC};
       true ->
            {recv_timeout, same, NewC}
    end;
client_watch_setup(timeout, C) ->
    slf_msgsim:add_utrace({watch_setup_timeout, slf_msgsim:self()}),
    cl_watch_send_cancels(C).

cl_watch_send_cancels(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    if length(Oks) == 0 ->
            {recv_general, client_init, C};
       true ->
            Self = slf_msgsim:self(),
            [slf_msgsim:bang(Server, {watch_cancel_req, Self, ClOp}) ||
                {watch_setup_resp, _ClOp, Server, ok} <- Oks],
            {recv_timeout, client_watch_cancelling, C}
    end.

client_watch_cancelling({watch_cancel_resp, ClOp, Server, ok},
                        C = #c{clop = ClOp, ph1_oks = Oks}) ->
    NewOks = lists:keydelete(Server, 3, Oks),
    if NewOks == [] ->
            {recv_general, client_init, #c{}};
       true ->
            {recv_timeout, same, C#c{ph1_oks = NewOks}}
    end;
client_watch_cancelling({watch_notify_maybe_req, ClOp, Server, _Z}, C) ->
    %% Honest race: this may be the thing that we're trying to cancel.
    %% No matter, we need to ack it then go back to waiting for our
    %% cancel ack.
    slf_msgsim:bang(Server, {watch_notify_maybe_resp,
                             slf_msgsim:self(), ClOp, ok}),
    {recv_timeout, same, C};
client_watch_cancelling({watch_notify_req, ClOp, Server, Z}, C) ->
    %% Again, honest race: this may be the thing that we're trying to cancel.
    %% No matter, we need to ack it then go back to waiting for our
    %% cancel ack.
    slf_msgsim:add_utrace({late_watch_notify_req, ClOp, Z}),
    slf_msgsim:bang(Server, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_timeout, same, C};
client_watch_cancelling(timeout, C) ->
    slf_msgsim:add_utrace({watch_cancelling_timeout, slf_msgsim:self()}),
    cl_watch_send_cancels(C).

client_watch_waiting({watch_notify_req, ClOp, From, Z}, #c{clop = ClOp}) ->
    slf_msgsim:add_utrace({watch_notify, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, client_init, #c{}};
%% TODO: Figure out if it's best to wait for more maybe notifications
%%       (because a quorum of maybes change =?= definite change?)
%%       or keep things as they are: a maybe is a maybe
client_watch_waiting({watch_notify_maybe_req, ClOp, From, Z},
                     #c{clop = ClOp}) ->
    slf_msgsim:add_utrace({watch_notify_maybe, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_maybe_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, client_init, #c{}};
client_watch_waiting({watch_setup_resp, ClOp, _Server, ok} = Msg,
                     C = #c{clop = ClOp,
                            num_responses = NumResps0, ph1_oks = Oks0}) ->
    NumResps = NumResps0 + 1,
    Oks = [Msg|Oks0],
    {recv_timeout, same, C#c{num_responses = NumResps, ph1_oks = Oks}};
client_watch_waiting(timeout, C) ->
    {recv_timeout, client_watch_waiting_2, C}.

client_watch_waiting_2({watch_notify_req, ClOp, From, Z}, #c{clop = ClOp}) ->
    slf_msgsim:add_utrace({watch_notify, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, client_init, #c{}};
%% TODO: Figure out if it's best to wait for more maybe notifications
%%       (because a quorum of maybes change =?= definite change?)
%%       or keep things as they are: a maybe is a maybe
client_watch_waiting_2({watch_notify_maybe_req, ClOp, From, Z},
                     #c{clop = ClOp}) ->
    slf_msgsim:add_utrace({watch_notify_maybe, ClOp, Z}),
    slf_msgsim:bang(From, {watch_notify_maybe_resp, slf_msgsim:self(), ClOp, ok}),
    {recv_general, client_init, #c{}};
client_watch_waiting_2({watch_setup_resp, ClOp, _Server, ok} = Msg,
                     C = #c{clop = ClOp,
                            num_responses = NumResps0, ph1_oks = Oks0}) ->
    NumResps = NumResps0 + 1,
    Oks = [Msg|Oks0],
    {recv_timeout, same, C#c{num_responses = NumResps, ph1_oks = Oks}};
client_watch_waiting_2(timeout, C = #c{clop = ClOp}) ->
    slf_msgsim:add_utrace({watch_timeout, ClOp}),
    cl_watch_send_cancels(C).

%%% Server counter-related states

server_unasked({ph1_ask, From, ClOp}, S = #s{cookie = undefined}) ->
    S2 = send_ask_ok(From, ClOp, S),
    {recv_timeout, server_asked, S2};
server_unasked({ph2_do_set, From, ClOp, Cookie, Z}, S) ->
    slf_msgsim:bang(From, {error, ClOp, slf_msgsim:self(),
                           server_unasked, Cookie, Z}),
    {recv_general, same, S};
server_unasked({unconditional_set, _From, _ClOp, Z0}, S = #s{val = Z1}) ->
    Z = do_reconcile([Z0, Z1], server),
    unconditional_utrace(Z0, Z1, Z),
    {recv_general, same, S#s{val = Z}};
server_unasked({ph1_cancel, From, ClOp, _Cookie}, S) ->
    %% Late arrival, tell client it's OK, but really we ignore it
    slf_msgsim:bang(From, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    {recv_general, same, S};
server_unasked({watch_setup_req, _From, _ClOp} = Msg, S) ->
    {recv_general, same, sv_watch_setup(Msg, S)};
server_unasked({watch_cancel_req, _From, _ClOp} = Msg, S) ->
    {recv_general, same, sv_watch_cancel(Msg, S)};
server_unasked({watch_notifies_delivered, _Ws}, S) ->
    {recv_general, same, S};
server_unasked({watch_notify_maybe_resp, _From, _ClOp, ok}, S) ->
    {recv_general, same, S}.

server_asked({ph2_do_set, From, ClOp, Cookie, Z0},
             S = #s{cookie = Cookie, val = Z1, watchers = Ws}) ->
    Z = do_reconcile([Z0, Z1], server),
    slf_msgsim:bang(From, {ph2_ok, ClOp, Ws}),
    if Ws == [] ->
            {recv_general, server_unasked, S#s{asker = undefined,
                                               cookie = undefined,
                                               val = Z}};
       true ->
            {recv_timeout, server_change_notif_fromsetter, S#s{val = Z}}
    end;
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
server_asked({unconditional_set, _From, _ClOp, Z0}, S = #s{val = Z1}) ->
    Z = do_reconcile([Z0, Z1], server),
    unconditional_utrace(Z0, Z1, Z),
    {recv_timeout, same, S#s{val = Z}};
server_asked(timeout, S) ->
    {recv_general, server_unasked, S#s{asker = undefined,
                                       cookie = undefined}};
server_asked({watch_setup_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_setup(Msg, S)};
server_asked({watch_cancel_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_cancel(Msg, S)};
server_asked({watch_notify_maybe_resp, _From, _ClOp, ok}, S) ->
    {recv_timeout, same, S}.

server_change_notif_fromsetter({watch_notifies_delivered, Watchers},
                                S = #s{watchers = Ws}) ->
    {recv_general, server_unasked, S#s{asker = undefined,
                                       cookie = undefined,
                                       watchers = Ws -- Watchers}};
server_change_notif_fromsetter(timeout, S) ->
    NewS = sv_send_maybe_notifications(S),
    {recv_timeout, server_change_notif_toindividuals, NewS};
%% Due to a 1-way network partition, a client might repeatedly send us a
%% zillion watch setup/cancel requests, but our replies are dropped, so
%% they resend.  The simulator can require more than 10K simulator steps
%% to catch up, so we'll consume those things here just to make less
%% catch up work.
server_change_notif_fromsetter({watch_setup_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_setup(Msg, S)};
server_change_notif_fromsetter({watch_cancel_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_cancel(Msg, S)}.

server_change_notif_toindividuals({watch_notify_maybe_resp, From, ClOp, ok},
                                  S = #s{watchers = Ws}) ->
    case Ws -- [{From, ClOp}] of
        [] ->
            {recv_general, server_unasked, S#s{asker = undefined,
                                               cookie = undefined,
                                               watchers = []}};
        NewWs ->
            {recv_timeout, same, S#s{watchers = NewWs}}
    end;
server_change_notif_toindividuals(timeout, S = #s{watchers = Ws}) ->
    if Ws == [] ->
            {recv_general, server_unasked, S#s{asker = undefined,
                                               cookie = undefined,
                                               watchers = []}};
       true ->
            NewS = sv_send_maybe_notifications(S),
            {recv_timeout, same, NewS}
    end;
server_change_notif_toindividuals({ph1_cancel, From, ClOp, _Cookie}, S) ->
    %% Late arrival, tell client it's OK, but really we ignore it
    slf_msgsim:bang(From, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    {recv_timeout, same, S};
%% Due to a 1-way network partition, a client might repeatedly send us a
%% zillion watch setup/cancel requests, but our replies are dropped, so
%% they resend.  The simulator can require more than 10K simulator steps
%% to catch up, so we'll consume those things here just to make less
%% catch up work.
server_change_notif_toindividuals({watch_setup_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_setup(Msg, S)};
server_change_notif_toindividuals({watch_cancel_req, _From, _ClOp} = Msg, S) ->
    {recv_timeout, same, sv_watch_cancel(Msg, S)}.

sv_watch_setup({watch_setup_req, From, ClOp}, S = #s{watchers = Ws}) ->
    slf_msgsim:bang(From, {watch_setup_resp, ClOp, slf_msgsim:self(), ok}),
    S#s{watchers = [{From, ClOp}|Ws]}.

sv_watch_cancel({watch_cancel_req, From, ClOp}, S = #s{watchers = Ws}) ->
    slf_msgsim:bang(From, {watch_cancel_resp, ClOp, slf_msgsim:self(), ok}),
    S#s{watchers = Ws -- [{From, ClOp}]}.

sv_send_maybe_notifications(S = #s{watchers = Ws, val = Z}) ->
     [slf_msgsim:bang(Clnt, {watch_notify_maybe_req, ClOp,
                             slf_msgsim:self(), Z})||
         {Clnt, ClOp} <- Ws],
    S.

unconditional_utrace(#obj{contents = Z0C}, #obj{contents = Z1C}, Z) ->
    Val = case Z#obj.contents of Z0C -> new;
                                 Z1C -> orig;
                                 _   -> other
          end,
    slf_msgsim:add_utrace({unconditional_set, Val}).

send_ask_ok(From, ClOp, S = #s{val = Z}) ->
    Cookie = {cky, now()},
    slf_msgsim:bang(From, {ph1_ask_ok, ClOp, slf_msgsim:self(), Cookie, Z}),
    S#s{asker = From, cookie = Cookie}.

cl_p1_send_do(C = #c{num_servers = NumServers, clop = ClOp, ph1_oks = Oks}) ->
    Objs = [Z || {_, _, _, _, Z} <- Oks],
    Z = do_reconcile(Objs, client),
                      %% So far, I've only seen this multiple contents case
                      %% when the servers have out-of-sync counters *and* then
                      %% are accessed by a never-seen-before client (call it
                      %% 'C').  Due to wacky network partitions, C creates
                      %% vclocks [{C, {1, WhateverTimestamp}}] on multiple
                      %% servers but with different values.  Then when those
                      %% copies are read and fed to do_reconcile(), we get
                      %% multiple contents.  So, as long as the servers always
                      %% start with the same starting counter value (e.g. 0),
                      %% then we'll be OK.
                      %% 
                      %% TODO: This creates an interesting follow-up question,
                      %%       though: what happens if a server crashes and
                      %%       forgets its counter number?  I've been hoping
                      %%       implicitly that this protocol would be able to
                      %%       handle any such case -- that's why my
                      %%       gen_server_initial_states() function has been
                      %%       creating servers with wildly-differing starting
                      %%       counter values.  However, if a server crashes
                      %%       and re-starts with a new (and perhaps lower)
                      %%       counter value, will bad things happen?
                      %% Ref: Item-1
    Counter = lists:max(Z#obj.contents), %% app-specific logic here
    #obj{vclock = VClock} = Z,
    NewCounter = Counter + 1,
    NewZ = Z#obj{vclock = vclock:increment(slf_msgsim:self(), VClock),
                 contents = [NewCounter]},
    %% Using erlang:now() here is naughty in the general case but OK
    %% in this particular case: we're in strictly-increasing counters
    %% over time.  erlang:now() is strictly increasing wrt time.  If
    %% we save the now() time when we've made our decision of what
    %% NewCounter should be, then we can include that timestamp in our
    %% utrace entry when phase2 is finished, and then the
    %% verify_property() function can sort the Emitted list by now()
    %% timestamps and then check for correct counter ordering.
    Now = erlang:now(),
    slf_msgsim:add_utrace({counter_start_ph2, Now, NewZ}),
    [slf_msgsim:bang(Svr, {ph2_do_set, slf_msgsim:self(), ClOp, Cookie, NewZ})
     || {ph1_ask_ok, _x_ClOp, Svr, Cookie, _Z} <- Oks],
    AllServers = lists:sublist(all_servers(), 1, NumServers),
    OkServers = [Svr || {ph1_ask_ok, _x_ClOp, Svr, _Cookie, _Z} <- Oks],
    NotOkServers = AllServers -- OkServers,
    [slf_msgsim:bang(Svr, {unconditional_set, slf_msgsim:self(), ClOp, NewZ}) ||
        Svr <- NotOkServers],
    [slf_msgsim:add_utrace({unconditional_set_sent}) || _ <- NotOkServers],
    {recv_timeout, client_ph2_waiting, C#c{num_responses = 0,
                                           ph2_val = NewZ,
                                           ph2_now = Now}}.

make_val(Replies) ->
    lists:max([Counter || {_Server, Counter} <- Replies]).

calc_q(#c{num_servers = NumServers}) ->
    (NumServers div 2) + 1.

get_mailbox(Proc, Sched) ->
    try
        slf_msgsim:get_mailbox(Proc, Sched)
    catch error:function_clause ->
            %% Process crashed -> orddict:fetch() fails by function_clause
            []
    end.            

do_reconcile(Objs0, _WhoIsIt) ->
    Objs = reconcile(Objs0),
    Contents = lists:append([Z#obj.contents || Z <- Objs]),
    VClock = vclock:merge([Z#obj.vclock || Z <- Objs]),
    Obj1 = hd(Objs),
    Obj1#obj{vclock=VClock, contents=Contents}.

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].

%%% Brute-force attempt to McErlang'ify.....

startup(client) ->
    fun e_client/2;
startup(server) ->
    fun e_server/2.

e_client(Ops, State) ->
    [mc_bang(mc_self(), Op) || Op <- Ops],
    mc_self() ! stop_now_kludge,
    e_client_init(State).

e_client_init(C) ->
    mc_put(short_circuit, 0),
    receive
        {counter_op, Servers} ->
            %% The clop/ClOp is short for "Client Operation".  It's used in
            %% a manner similar to gen_server's reference() tag: the ClOp is
            %% used to avoid receiving messages that are late, i.e. messages
            %% that have been delayed or have been received after we made an
            %% important state transition.  If we don't restrict our
            %% match/receive pattern in this way, then messages that arrive
            %% late can cause very hard-to-reproduce errors.  (Well, hard if we
            %% didn't have QuickCheck to help reproduct them.  :-)
            ClOp = make_ref(),
            [mc_bang(Server, {ph1_ask, mc_self(), ClOp}) || Server <- Servers],
            e_client_ph1_waiting(#c{clop = ClOp,
                                    num_servers = length(Servers)});
        {watch_op, Servers} ->
            ClOp = make_ref(),
            mc_probe({watch_setup_start, ClOp, mc_self()}),
            [mc_bang(Server, {watch_setup_req, mc_self(), ClOp}) ||
                Server <- Servers],
            e_client_watch_setup(#c{clop = ClOp,
                                    num_servers = length(Servers)});
        {watch_notify_req, ClOp, From, Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_probe({late_watch_notify_req, ClOp, Z}),
            mc_bang(From, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_init(C);
        {watch_notify_maybe_req, ClOp, From, Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_probe({late_watch_notify_maybe_req, Z}),
            mc_bang(From, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_init(C);
        T when is_tuple(T) ->
            %% In all other client states, our receive contain a guard based
            %% on ClOp, so any message that we see here in client_init that
            %% isn't a 'counter_op' message and is a tuple is something that
            %% arrived late in a prior 'counter_op' request.  We don't care
            %% about them, but we should consume them.
            e_client_init(C);
        stop_now_kludge ->
            C;
        shutdown ->
            C
    end.

%%% Client counter-related states

e_client_ph1_waiting(C = #c{clop = ClOp, num_responses = Resps,
                            ph1_oks = Oks, ph1_sorrys = Sorrys}) ->
    receive
        {ph1_ask_ok, ClOp, _Server, _Cookie, _Z} = Msg ->
            e_cl_p1_next_step(C#c{num_responses = Resps + 1,
                                  ph1_oks = [Msg|Oks]});
        {ph1_ask_sorry, ClOp, _Server, _LuckyClient} = Msg ->
            e_cl_p1_next_step(C#c{num_responses = Resps + 1,
                                  ph1_sorrys = [Msg|Sorrys]})
    after ?TIMEOUT ->
            %% Fake like we got responses from all servers ... plus a few extra.
            e_cl_p1_next_step(C#c{num_responses = 9999999999})
    end.

e_client_ph1_cancelling(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    receive
        {ph1_cancel_ok, ClOp, Server} ->
            NewOks = lists:keydelete(Server, 3, Oks),
            if NewOks == [] ->
                    e_client_init(#c{});
               true ->
                    e_client_ph1_cancelling(C#c{ph1_oks = NewOks})
            end
    after ?TIMEOUT ->
            e_cl_p1_send_cancels(C)
    end.

e_cl_p1_next_step(C = #c{num_responses = NumResps}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            NumOks = length(C#c.ph1_oks),
            if NumOks >= Q ->
                    e_cl_p1_send_do(C);
               true ->
                    mc_probe({ph1_quorum_failure, mc_self(), num_oks, NumOks}),
                    if NumOks == 0 ->
                            e_client_init(#c{});
                       true ->
                            e_cl_p1_send_cancels(C)
                    end
            end;
       true ->
            e_client_ph1_waiting(C)
    end.

e_cl_p1_send_cancels(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    mc_put(short_circuit, mc_get(short_circuit) + 1),
    [mc_bang(Server, {ph1_cancel, mc_self(), ClOp, Cookie}) ||
        {ph1_ask_ok, _ClOp, Server, Cookie, _Z} <- Oks],
    e_client_ph1_cancelling(C).

%% TODO: Is it necessary for for _all_ of the client counter-related
%%       states to explicitly handle the watch_notify*_req messages to
%%       avoid deadlock?  See commit log for more deadlock info....

e_client_ph2_waiting(C = #c{clop = ClOp,
                            num_responses = NumResps, ph2_val = Z,
                            watchers = Ws, ph1_oks = Oks}) ->
    receive
        {ph2_ok, ClOp, Watchers} ->
            NewWatchers = lists:usort(Watchers ++ Ws),
            if length(C#c.ph1_oks) /= NumResps + 1 ->
                    e_client_ph2_waiting(C#c{num_responses = NumResps + 1,
                                             watchers = NewWatchers});
               true ->
                    io:format(user, "\nDELME ~w ", [{counter, C#c.ph2_now, Z, NewWatchers}]),
                    mc_probe({counter, C#c.ph2_now, Z, NewWatchers}),
                    if NewWatchers == [] ->
                            e_client_init(#c{});
                       true ->
                            NewC = C#c{watchers = NewWatchers,
                                       watchers2 = NewWatchers},
                            e_cl_send_notifications(NewC),
                            e_client_notif_resp_waiting(NewC)
                    end
            end;
        {ph1_ask_ok, ClOp, Server, Cookie, _Z} = Msg ->
            mc_bang(Server, {ph2_do_set, mc_self(), ClOp, Cookie, Z}),
            e_client_ph2_waiting(C#c{ph1_oks = [Msg|Oks]});
        %% next 2 clauses, first bugfix for McErlang??
        {watch_notify_req, _ClOp, From, _Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_probe({late_watch_notify_req, ClOp, Z}),
            mc_bang(From, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_ph2_waiting(C);
        {watch_notify_maybe_req, _ClOp, From, _Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_probe({late_watch_notify_maybe_req, Z}),
            mc_bang(From, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_ph2_waiting(C)
    after ?TIMEOUT ->
            Q = calc_q(C),
            if NumResps >= Q ->
                    io:format(user, "\nDELME ~w ", [{counter, C#c.ph2_now, Z, lists:usort(Ws)}]),
                    mc_probe({counter, C#c.ph2_now, Z, lists:usort(Ws)}),
                    e_cl_send_notifications(C),
                    e_client_notif_resp_waiting(C);
               true ->
                    mc_probe({timeout_phase2, mc_self(), Z}),
                    e_client_init(#c{})
            end
    end.

e_cl_send_notifications(#c{watchers = Ws, ph2_val = Z}) ->
    [mc_bang(Client, {watch_notify_req, ClOp, mc_self(), Z}) ||
        {Client, ClOp} <- lists:usort(Ws)].

e_client_notif_resp_waiting(C = #c{num_servers = NumServers, watchers = Ws}) ->
    receive
        {watch_notify_resp, Client, ClOp, ok} ->
            case Ws -- [{Client, ClOp}] of
                [] ->
                    [mc_bang(Server, {watch_notifies_delivered, Ws}) || 
                        Server <- lists:sublist(all_servers(), 1, NumServers)],
                    e_client_init(#c{});
                NewWs ->
                    e_client_notif_resp_waiting(C#c{watchers = NewWs})
            end;
        {watch_notify_req, ClOp, From, Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_probe({late_watch_notify_req, ClOp, Z}),
            mc_bang(From, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_notif_resp_waiting(C);
        {watch_notify_maybe_req, ClOp, From, _Z} ->
            %% Race: this arrived late, need to respond to it, though.
            mc_bang(From, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_notif_resp_waiting(C);
        {ph1_ask_sorry, _, _, _} ->
            %% Race: this arrived late.  But we need to consume it, otherwise we
            %%       won't get a timeout message when we need one
            e_client_notif_resp_waiting(C)
    after ?TIMEOUT ->
            if Ws == [] ->
                    e_client_init(#c{});
               true ->
                    mc_put(short_circuit, mc_get(short_circuit) + 1),
                    e_cl_send_notifications(C),
                    e_client_notif_resp_waiting(C)
            end
    end.

%%% Client watch-related states

e_client_watch_setup(C = #c{clop = ClOp,
                            num_responses = NumResps0, ph1_oks = Oks0}) ->
    receive
        {watch_setup_resp, ClOp, _Server, ok} = Msg ->
            NumResps = NumResps0 + 1,
            Oks = [Msg|Oks0],
            NewC = C#c{num_responses = NumResps, ph1_oks = Oks},
            Q = calc_q(C),
            NumResps = length(Oks),             % sanity check
            if NumResps >= Q ->
                    mc_probe({watch_setup_done, ClOp, mc_self()}),
                    e_client_watch_waiting(NewC);
               true ->
                    e_client_watch_setup(NewC)
            end
    after ?TIMEOUT ->
            mc_probe({watch_setup_timeout, mc_self()}),
            e_cl_watch_send_cancels(C)
    end.

e_cl_watch_send_cancels(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    if length(Oks) == 0 ->
            e_client_init(C);
       true ->
            mc_put(short_circuit, mc_get(short_circuit) + 1),
            Self = mc_self(),
            [mc_bang(Server, {watch_cancel_req, Self, ClOp}) ||
                {watch_setup_resp, _ClOp, Server, ok} <- Oks],
            e_client_watch_cancelling(C)
    end.

e_client_watch_cancelling(C = #c{clop = ClOp, ph1_oks = Oks}) ->
    receive
        {watch_cancel_resp, ClOp, Server, ok} ->
            NewOks = lists:keydelete(Server, 3, Oks),
            if NewOks == [] ->
                    e_client_init(#c{});
               true ->
                    e_client_watch_cancelling(C#c{ph1_oks = NewOks})
            end;
        {watch_notify_maybe_req, ClOp, Server, _Z} ->
            %% Honest race: this may be the thing that we're trying to cancel.
            %% No matter, we need to ack it then go back to waiting for our
            %% cancel ack.
            mc_bang(Server, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_watch_cancelling(C);
        {watch_notify_req, ClOp, Server, Z} ->
            %% Again, honest race: this may be the thing that we're trying to cancel.
            %% No matter, we need to ack it then go back to waiting for our
            %% cancel ack.
            mc_probe({late_watch_notify_req, ClOp, Z}),
            mc_bang(Server, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_watch_cancelling(C)
    after ?TIMEOUT ->
            mc_put(short_circuit, mc_get(short_circuit) + 1),
            mc_probe({watch_cancelling_timeout, mc_self()}),
            e_cl_watch_send_cancels(C)
    end.

e_client_watch_waiting(C = #c{clop = ClOp,
                              num_responses = NumResps0, ph1_oks = Oks0}) ->
    receive
        {watch_notify_req, ClOp, From, Z} ->
            io:format(user, "DELME ~w|", [{watch_notify, ClOp, Z}]),
            mc_probe({watch_notify, ClOp, Z}),
            mc_bang(From, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_init(#c{});
        %% TODO: Figure out if it's best to wait for more maybe notifications
        %%       (because a quorum of maybes change =?= definite change?)
        %%       or keep things as they are: a maybe is a maybe
        {watch_notify_maybe_req, ClOp, From, Z} ->
            io:format(user, "DELME ~w|", [{watch_notify_maybe, ClOp, Z}]),
            mc_probe({watch_notify_maybe, ClOp, Z}),
            mc_bang(From, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_init(#c{});
        {watch_setup_resp, ClOp, _Server, ok} = Msg ->
            NumResps = NumResps0 + 1,
            Oks = [Msg|Oks0],
            e_client_watch_waiting(C#c{num_responses = NumResps,
                                       ph1_oks = Oks})
    after ?TIMEOUT ->
            e_client_watch_waiting_2(C)
    end.

e_client_watch_waiting_2(C = #c{clop = ClOp,
                                num_responses = NumResps0, ph1_oks = Oks0}) ->
    receive
        {watch_notify_req, ClOp, From, Z} ->
            io:format(user, "DELME ~w|", [{watch_notify, ClOp, Z}]),
            mc_probe({watch_notify, ClOp, Z}),
            mc_bang(From, {watch_notify_resp, mc_self(), ClOp, ok}),
            e_client_init(#c{});
        %% TODO: Figure out if it's best to wait for more maybe notifications
        %%       (because a quorum of maybes change =?= definite change?)
        %%       or keep things as they are: a maybe is a maybe
        {watch_notify_maybe_req, ClOp, From, Z} ->
            io:format(user, "DELME ~w|", [{watch_notify_maybe, ClOp, Z}]),
            mc_probe({watch_notify_maybe, ClOp, Z}),
            mc_bang(From, {watch_notify_maybe_resp, mc_self(), ClOp, ok}),
            e_client_init(#c{});
        {watch_setup_resp, ClOp, _Server, ok} = Msg ->
            NumResps = NumResps0 + 1,
            Oks = [Msg|Oks0],
            e_client_watch_waiting_2(C#c{num_responses = NumResps,
                                         ph1_oks = Oks})
    after ?TIMEOUT ->
            mc_probe({watch_timeout, ClOp}),
            e_cl_watch_send_cancels(C)
    end.

%%% Server counter-related states

e_server(_Ops, State) ->
    e_server_unasked(State).

e_server_unasked(S = #s{val = Z1}) ->
    mc_put(short_circuit, 0),
    receive
        {ph1_ask, From, ClOp} when S#s.cookie == undefined ->
            S2 = e_send_ask_ok(From, ClOp, S),
            e_server_asked(S2);
        {ph2_do_set, From, ClOp, Cookie, Z} ->
            mc_bang(From, {error, ClOp, mc_self(), server_unasked, Cookie, Z}),
            e_server_unasked(S);
        {unconditional_set, _From, _ClOp, Z0} ->
            Z = do_reconcile([Z0, Z1], server),
            e_unconditional_utrace(Z0, Z1, Z),
            e_server_unasked(S#s{val = Z});
        {ph1_cancel, From, ClOp, _Cookie} ->
            %% Late arrival, tell client it's OK, but really we ignore it
            mc_bang(From, {ph1_cancel_ok, ClOp, mc_self()}),
            e_server_unasked(S);
        {watch_setup_req, _From, _ClOp} = Msg ->
            e_server_unasked(e_sv_watch_setup(Msg, S));
        {watch_cancel_req, _From, _ClOp} = Msg ->
            e_server_unasked(e_sv_watch_cancel(Msg, S));
        {watch_notifies_delivered, _Ws} ->
            e_server_unasked(S);
        {watch_notify_maybe_resp, _From, _ClOp, ok} ->
            e_server_unasked(S);
        shutdown ->
            S
    end.

e_server_asked(S = #s{cookie = Cookie, val = Z1, watchers = Ws,
                      asker = Asker}) ->
    receive
        {ph2_do_set, From, ClOp, Cookie, Z0} ->
            Z = do_reconcile([Z0, Z1], server),
            mc_bang(From, {ph2_ok, ClOp, Ws}),
            if Ws == [] ->
                    e_server_unasked(S#s{asker = undefined,
                                         cookie = undefined,
                                         val = Z});
               true ->
                    e_server_change_notif_fromsetter(S#s{val = Z})
            end;
        {ph1_ask, From, ClOp} ->
            mc_bang(From, {ph1_ask_sorry, ClOp, mc_self(), Asker}),
            e_server_asked(S);
        {ph1_cancel, Asker, ClOp, Cookie} ->
            mc_bang(Asker, {ph1_cancel_ok, ClOp, mc_self()}),
            %% Conversion NOTE: Same as timeout case below
            e_server_unasked(S#s{asker = undefined,
                                 cookie = undefined});
        {ph1_cancel, From, ClOp, _Cookie} ->
            %% Late arrival, tell client it's OK, but really we ignore it
            mc_bang(From, {ph1_cancel_ok, ClOp, mc_self()}),
            e_server_asked(S);
        {unconditional_set, _From, _ClOp, Z0} ->
            Z = do_reconcile([Z0, Z1], server),
            e_unconditional_utrace(Z0, Z1, Z),
            e_server_asked(S#s{val = Z});
        {watch_setup_req, _From, _ClOp} = Msg ->
            e_server_asked(e_sv_watch_setup(Msg, S));
        {watch_cancel_req, _From, _ClOp} = Msg ->
            e_server_asked(e_sv_watch_cancel(Msg, S));
        {watch_notify_maybe_resp, _From, _ClOp, ok} ->
            e_server_asked(S);
        shutdown ->
            S
    after ?TIMEOUT ->
            e_server_unasked(S#s{asker = undefined,
                                 cookie = undefined})
    end.

e_server_change_notif_fromsetter(S = #s{watchers = Ws}) ->
    receive
        {watch_notifies_delivered, Watchers} ->
            e_server_unasked(S#s{asker = undefined,
                                 cookie = undefined,
                                 watchers = Ws -- Watchers});
        %% Due to a 1-way network partition, a client might repeatedly send us a
        %% zillion watch setup/cancel requests, but our replies are dropped, so
        %% they resend.  The simulator can require more than 10K simulator steps
        %% to catch up, so we'll consume those things here just to make less
        %% catch up work.
        {watch_setup_req, _From, _ClOp} = Msg ->
            e_server_change_notif_fromsetter(e_sv_watch_setup(Msg, S));
        {watch_cancel_req, _From, _ClOp} = Msg ->
            e_server_change_notif_fromsetter(e_sv_watch_cancel(Msg, S))
    after ?TIMEOUT ->
            io:format(user, "ms=~p,", [length(S#s.watchers)]),
            mc_probe({slf, ?LINE, S#s.watchers}),
            e_sv_send_maybe_notifications(S)
    end.

e_server_change_notif_toindividuals(S = #s{watchers = Ws}) ->
    receive
        {watch_notify_maybe_resp, From, ClOp, ok} ->
            case Ws -- [{From, ClOp}] of
                [] ->
                    e_server_unasked(S#s{asker = undefined,
                                         cookie = undefined,
                                         watchers = []});
                NewWs ->
                    e_server_change_notif_toindividuals(S#s{watchers = NewWs})
            end;
        {ph1_cancel, From, ClOp, _Cookie} ->
            %% Late arrival, tell client it's OK, but really we ignore it
            mc_bang(From, {ph1_cancel_ok, ClOp, mc_self()}),
            e_server_change_notif_toindividuals(S);
        %% Due to a 1-way network partition, a client might repeatedly send us a
        %% zillion watch setup/cancel requests, but our replies are dropped, so
        %% they resend.  The simulator can require more than 10K simulator steps
        %% to catch up, so we'll consume those things here just to make less
        %% catch up work.
        {watch_setup_req, _From, _ClOp} = Msg ->
            e_server_change_notif_toindividuals(e_sv_watch_setup(Msg, S));
        {watch_cancel_req, _From, _ClOp} = Msg ->
            e_server_change_notif_toindividuals(e_sv_watch_cancel(Msg, S))
    after ?TIMEOUT ->
            io:format(user, "ms=~p,", [length(S#s.watchers)]),
            mc_probe({slf, ?LINE, S#s.watchers}),
            e_sv_send_maybe_notifications(S)
    end.

e_send_ask_ok(From, ClOp, S = #s{val = Z}) ->
    Cookie = {cky, now()},
    mc_bang(From, {ph1_ask_ok, ClOp, mc_self(), Cookie, Z}),
    S#s{asker = From, cookie = Cookie}.

%% NOTE: Embarrassing cut-and-paste hack from cl_p1_send_do().

e_cl_p1_send_do(C = #c{num_servers = NumServers, clop = ClOp, ph1_oks = Oks}) ->
    Objs = [Z || {_, _, _, _, Z} <- Oks],
    Z = do_reconcile(Objs, client),
    Counter = lists:max(Z#obj.contents), %% app-specific logic here
    #obj{vclock = VClock} = Z,
    NewCounter = Counter + 1,
    NewZ = Z#obj{vclock = vclock:increment(mc_self(), VClock),
                 contents = [NewCounter]},
    Now = erlang:now(),
    mc_probe({counter_start_ph2, Now, NewZ}),
    [mc_bang(Svr, {ph2_do_set, mc_self(), ClOp, Cookie, NewZ})
     || {ph1_ask_ok, _x_ClOp, Svr, Cookie, _Z} <- Oks],
    AllServers = lists:sublist(all_servers(), 1, NumServers),
    OkServers = [Svr || {ph1_ask_ok, _x_ClOp, Svr, _Cookie, _Z} <- Oks],
    NotOkServers = AllServers -- OkServers,
    [mc_bang(Svr, {unconditional_set, mc_self(), ClOp, NewZ}) ||
        Svr <- NotOkServers],
    [mc_probe({unconditional_set_sent, NotOkSvr}) || NotOkSvr <- NotOkServers],
    e_client_ph2_waiting(C#c{num_responses = 0,
                             ph2_val = NewZ,
                             ph2_now = Now}).

e_sv_watch_setup({watch_setup_req, From, ClOp}, S = #s{watchers = Ws}) ->
    mc_bang(From, {watch_setup_resp, ClOp, mc_self(), ok}),
    S#s{watchers = [{From, ClOp}|Ws]}.

e_sv_watch_cancel({watch_cancel_req, From, ClOp}, S = #s{watchers = Ws}) ->
    mc_bang(From, {watch_cancel_resp, ClOp, mc_self(), ok}),
    S#s{watchers = Ws -- [{From, ClOp}]}.

e_sv_send_maybe_notifications(S = #s{watchers = Ws, val = Z}) ->
    if Ws == [] ->
            e_server_unasked(S#s{asker = undefined,
                                 cookie = undefined,
                                 watchers = []});
       true ->
            mc_put(short_circuit, mc_get(short_circuit) + 1),
            [mc_bang(Clnt, {watch_notify_maybe_req, ClOp, mc_self(), Z}) ||
                {Clnt, ClOp} <- Ws],
            e_server_change_notif_toindividuals(S)
    end.

e_unconditional_utrace(#obj{contents = Z0C}, #obj{contents = Z1C}, Z) ->
    Val = case Z#obj.contents of Z0C -> new;
              Z1C -> orig;
              _   -> other
          end,
    mc_probe({unconditional_set, Val}).

-define(CONST, 4).

mc_bang(Rcpt, Msg) ->
    case mc_get(short_circuit) of
        N when N < ?CONST ->
            slf_msgsim_qc:mc_bang(Rcpt, Msg);
        N when N == ?CONST ->
            %% From now on, we can't drop messages.
            mc_put(short_circuit, N + 1), %% avoid multiple probes
            mc_probe({short_circuit_fired, mc_self(), N}),
            Rcpt ! Msg;
        _ ->
            Rcpt ! Msg
    end,
    Msg.
    %% Rcpt ! Msg.

mc_self() ->
    slf_msgsim_qc:mc_self().
    %% erlang:self().

mc_probe(Term) ->
    mce_erl:probe(Term).
    %% io:format(user, "Probe: ~p\n", [Term]).

mc_get(Key) ->
    mcerlang:gget(Key).

mc_put(Key, Val) ->
    mcerlang:gput(Key, Val).

%%% BEGIN From riak_object.erl, also Apache Public License v2 licensed
%%% Copyright (c) 2007-2010 Basho Technologies, Inc.  All Rights Reserved.
%%% https://github.com/basho/riak_kv/blob/master/src/riak_object.erl
%%% ... because a rebar dep on riak_kv pulls in *lots* of dependent repos ....

ancestors(pure_baloney_to_fool_dialyzer) ->
    [#obj{vclock = vclock:fresh()}];
ancestors(Objects) ->
    ToRemove = [[O2 || O2 <- Objects,
     vclock:descends(O1#obj.vclock,O2#obj.vclock),
     (vclock:descends(O2#obj.vclock,O1#obj.vclock) == false)]
                || O1 <- Objects],
    lists:flatten(ToRemove).

%% @spec reconcile([riak_object()]) -> [riak_object()]
reconcile(Objects) ->
    All = sets:from_list(Objects),
    Del = sets:from_list(ancestors(Objects)),
    XX1 = sets:to_list(sets:subtract(All, Del)),
    XX2 = lists:reverse(lists:sort(XX1)),
    remove_duplicate_objects(XX2).

remove_duplicate_objects(Os) -> rem_dup_objs(Os,[]).
rem_dup_objs([],Acc) -> Acc;
rem_dup_objs([O|Rest],Acc) ->
    EqO = [AO || AO <- Acc, equal(AO,O) =:= true],
    case EqO of
        [] -> rem_dup_objs(Rest,[O|Acc]);
        _ -> rem_dup_objs(Rest,Acc)
    end.

equal(Y, Z) ->
    case vclock:equal(Y#obj.vclock, Z#obj.vclock) of
        true ->
            lists:sort(Y#obj.contents) =:= lists:sort(Y#obj.contents);
        false ->
            false
    end.

%%% END From riak_object.erl, also Apache Public License v2 licensed
