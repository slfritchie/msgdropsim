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
-module(distrib_counter_2phase_vclock_sim).

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

-record(obj, {
          %% key = undefined,
          vclock             :: vclock:vclock(),
          contents           :: [integer()]
         }).

-record(s, {                                    % server state
          val                :: #obj{},
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
    NumMsgs = length([x || {bang,_,_,_,_} <- Trc]),
    NumDrops = length([x || {drop,_,_,_,_} <- Trc]),
    NumDelays = length([x || {delay,_,_,_,_,_} <- Trc]),
    NumTimeouts = length([x || {recv,_,scheduler,_,timeout} <- Trc]),
    NumCrashes = length([x || {process_crash,_,_,_,_,_} <- Trc]),
    %% We need to sort the emitted events by "time", see comment
    %% below with "erlang:now()" in it.
    Emitted0 = [Inner || {_Clnt, _Step, Inner = {counter, _Now, Count}} <- UTrc,
                        Count /= timeout],
    Emitted1 = lists:keysort(2, Emitted0),
    Emitted = [Count || {counter, _Now, Count} <- Emitted1],
    Phase1Timeouts = [x || {_Clnt,_Step,{timeout_phase1, _}} <- UTrc],
    Phase1QuorumFails = [x || {_Clnt,_Step,{ph1_quorum_failure,_,_,_}} <- UTrc],
    Phase2Timeouts = [x || {_Clnt,_Step,{timeout_phase2, _, _}} <- UTrc],
    Steps = slf_msgsim:get_step(Sched1),
    AllProcs = lists:sublist(all_clients(), 1, NumClients) ++
        lists:sublist(all_servers(), 1, NumServers),
    Unconsumed = lists:append([get_mailbox(Proc, Sched1) || Proc <- AllProcs]),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd2 = ~P\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Emitted counters = ~w\n"
                 "Ops ~p ?= Emitted ~p + Phase1QuorumFails ~p + Phase1Timeouts ~p + Phase2Timeouts ~p\n"
                 "# Unconsumed ~p, NumCrashes ~p\n",
                 [F1, F2, Sched1, 250,
                  slf_msgsim:runnable_procs(Sched1),
                  slf_msgsim:receivable_procs(Sched1),
                  Emitted,
                 length(Ops), length(Emitted), length(Phase1QuorumFails), length(Phase1Timeouts), length(Phase2Timeouts),
                 length(Unconsumed), NumCrashes]),
       classify(NumDrops /= 0, at_least_1_msg_dropped,
       measure("clients     ", NumClients,
       measure("servers     ", NumServers,
       measure("sched steps ", Steps,
       measure("crashes     ", NumCrashes,
       measure("# ops       ", length(Ops),
       measure("# emitted   ", length(Emitted),
       measure("# ph1 t.out ", length(Phase1Timeouts),
       measure("# ph1 q.fail", length(Phase1QuorumFails),
       measure("# ph2 t.out ", length(Phase2Timeouts),
       measure("msgs sent   ", NumMsgs,
       measure("msgs dropped", NumDrops,
       measure("msgs delayed", NumDelays,
       measure("timeouts    ", NumTimeouts,
       begin
           Runnable == false andalso
           length(Ops) == length(Emitted) +
               length(Phase1QuorumFails) +
               length(Phase1Timeouts) +
               length(Phase2Timeouts) andalso
               length(Emitted) == length(lists:usort(Emitted)) andalso
               Emitted == lists:sort(Emitted) andalso
               Unconsumed == [] andalso
               NumCrashes == 0
       end))))))))))))))).

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
%%         C1                          C2                          S1       S2
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
%%         <-------- phase 2 ok ------------------------------------|

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
client_init(T, C) when is_tuple(T) ->
    %% In all other client states, our receive contain a guard based
    %% on ClOp, so any message that we see here in client_init that
    %% isn't a 'counter_op' message and is a tuple is something that
    %% arrived late in a prior 'counter_op' request.  We don't care
    %% about them, but we should consume them.
    {recv_general, same, C}.

client_ph1_waiting({ph1_ask_ok, ClOp, _Server, _Cookie, _Z} = Msg,
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

cl_p1_next_step(true = _TimeoutHappened, _C) ->
    slf_msgsim:add_utrace({timeout_phase1, slf_msgsim:self()}),
    {recv_general, client_init, #c{}};
cl_p1_next_step(false, C = #c{num_responses = NumResps}) ->
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

client_ph2_waiting({ok, ClOp, _Server, _Cookie},
                   C = #c{clop = ClOp,
                          num_responses = NumResps, ph2_val = Z}) ->
    if length(C#c.ph1_oks) /= NumResps + 1 ->
            {recv_timeout, same, C#c{num_responses = NumResps + 1}};
       true ->
            [Val] = Z#obj.contents,
            slf_msgsim:add_utrace({counter, C#c.ph2_now, Val}),
            {recv_general, client_init, #c{}}
    end;
client_ph2_waiting({ph1_ask_ok, ClOp, Server, Cookie, _Z} = Msg,
                   C = #c{clop = ClOp, ph1_oks = Oks, ph2_val = Z}) ->
    slf_msgsim:bang(Server, {ph2_do_set, slf_msgsim:self(), ClOp, Cookie, Z}),
    {recv_timeout, same, C#c{ph1_oks = [Msg|Oks]}};
client_ph2_waiting(timeout, C = #c{num_responses = NumResps, ph2_val = Z}) ->
    Q = calc_q(C),
    if NumResps >= Q ->
            [Val] = Z#obj.contents,
            slf_msgsim:add_utrace({counter, C#c.ph2_now, Val});
       true ->
            slf_msgsim:add_utrace({timeout_phase2, slf_msgsim:self(), Z})
    end,
    {recv_general, client_init, #c{}}.

server_unasked({ph1_ask, From, ClOp}, S = #s{cookie = undefined}) ->
    S2 = send_ask_ok(From, ClOp, S),
    {recv_timeout, server_asked, S2};
server_unasked({ph2_do_set, From, ClOp, Cookie, Z}, S) ->
    slf_msgsim:bang(From, {error, ClOp, slf_msgsim:self(),
                           server_unasked, Cookie, Z}),
    {recv_general, same, S};
server_unasked({ph1_cancel, From, ClOp, _Cookie}, S) ->
    %% Late arrival, tell client it's OK, but really we ignore it
    slf_msgsim:bang(From, {ph1_cancel_ok, ClOp, slf_msgsim:self()}),
    {recv_general, same, S}.

server_asked({ph2_do_set, From, ClOp, Cookie, Z0},
             S = #s{cookie = Cookie, val = Z1}) ->
    Z = do_reconcile([Z0, Z1], server),
%%    case slf_msgsim:self() of s4 -> io:format("svr ~p:\n In  ~p\nOut ~p\n", [slf_msgsim:self(), [Z0, Z1], Z]); _ -> ok end,
%% io:format("svr ~p:\n In  ~p\nOut ~p\n", [slf_msgsim:self(), [Z0, Z1], Z]),
    slf_msgsim:bang(From, {ok, ClOp, slf_msgsim:self(), Cookie}),
    {recv_general, server_unasked, S#s{asker = undefined,
                                       cookie = undefined,
                                       val = Z}};
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

send_ask_ok(From, ClOp, S = #s{val = Z}) ->
    Cookie = {cky, now()},
    slf_msgsim:bang(From, {ph1_ask_ok, ClOp, slf_msgsim:self(), Cookie, Z}),
    S#s{asker = From, cookie = Cookie}.

cl_p1_send_do(C = #c{clop = ClOp, ph1_oks = Oks}) ->
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
    [slf_msgsim:bang(Svr, {ph2_do_set, slf_msgsim:self(), ClOp, Cookie, NewZ})
     || {ph1_ask_ok, _x_ClOp, Svr, Cookie, _Z} <- Oks],
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

do_reconcile(Objs0, WhoIsIt) ->
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

%% @spec reconcile([riak_object()]) -> [riak_object()]
reconcile2(Objects) ->
    All = ordsets:from_list(Objects),
    Del = ordsets:from_list(ancestors(Objects)),
    remove_duplicate_objects(ordsets:to_list(ordsets:subtract(All, Del))).

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
