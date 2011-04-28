%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <slfritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc A message passing simulator, with delayed/lost messages and
%%%      network partitions.
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

-module(slf_msgsim).
-compile(export_all).

-include_lib("eunit/include/eunit.hrl").

-type orddict()    :: orddict:orddict().
-type delay()      :: {delay, [proc()], [proc()], integer(), integer(), integer()}.
-type partition()  :: {partition, [proc()], [proc()], integer(), integer()}.
-type proc()       :: atom().

-record(proc, {
          name     :: proc(),     % All procs have a name
          state    :: term(),     % proc private state
          mbox     :: list(),     % incoming mailbox
          outbox   :: queue(),    % {Delay::integer(), Rcpt::atom(), Msg}
          next     :: mbox | outbox, % next execution type
          recv_gen :: fun(),      % Fun for generic receive without timeout
          recv_w_timeout :: fun() % Fun for receive with timeout
         }).

-record(sched, {
          step = 0     :: integer(),  % Scheduling step #
          numsent = 0  :: integer(),  % Number of messages sent
          tokens       :: list(atom()),% Process scheduler tokens
          crashed = [] :: list(atom()),% Processes that have crashed
          procs        :: orddict(),  % key=proc name, val=#proc{}
          trace = []   :: list(),     % trace events
          utrace = []  :: list(),     % user trace events
          %% Partition dictionary: key = {From::atom(), To::atom()}
          %% value = list of steps to drop packets
          partitions   :: orddict(),
          %% Delay dictionary: key = {From::atom(), To::atom()}
          %% value = list({StepNumber, DelaySteps}) (similar to partitions)
          delays       :: orddict(),
          module       :: atom()
         }).

-spec new_sim([{proc(), term(), fun()}], [{proc(), term(), fun()}],
              [term()], [proc()], [partition()], [delay()]) -> #sched{}.

new_sim(Clients, Servers, InitialMsgs, SchedOrder, Partitions, Delays) ->
    new_sim(Clients, Servers, InitialMsgs, SchedOrder, Partitions, Delays, nomod).

new_sim(Clients, Servers, InitialMsgs, SchedOrder, Partitions, Delays, Module) ->
    AllCSs = Clients ++ Servers,
    AllNames = lists:usort([Name || {Name, _St, _Recv} <- AllCSs]),
    MissingPs =  AllNames -- lists:usort(SchedOrder),% Add missing procs to toks
    S = #sched{tokens = SchedOrder ++ MissingPs,
               procs = orddict:from_list([{Name, init_proc(ProcSpec)} ||
                                             {Name,_,_} = ProcSpec <- AllCSs]),
               partitions = make_partition_dict(Partitions),
               delays = make_delay_dict(Delays),
               module = Module
              },
    send_initial_msgs_to_procs(InitialMsgs, S).

-spec init_proc({proc(), term(), function()}) ->
                       #proc{}.
init_proc({Name, State, RecvFun}) ->
    init_proc(Name, State, RecvFun).

-spec init_proc(proc(), term(), function()) ->
                       #proc{}.
init_proc(Name, State, RecvFun) ->
    #proc{name = Name,
          state = State,
          mbox = [],
          outbox = queue:new(),
          next = mbox,
          recv_gen = RecvFun,
          recv_w_timeout = undefined}.

-spec make_partition_dict([partition()]) -> orddict().

make_partition_dict(Ps) ->
    Raw = [{{From, To}, N} ||
              {partition, Froms, Tos, Start, End} <- Ps,
              From <- lists:usort(Froms), To <- lists:usort(Tos),
              N <- lists:seq(Start, End)],
    lists:foldl(fun({Key, V}, D) -> orddict:append(Key, V, D) end,
                orddict:new(), Raw).

-spec make_delay_dict([delay()]) -> orddict().

make_delay_dict(Ps) ->
    Raw = [{{From, To}, {N, DelaySteps}} ||
              {delay, Froms, Tos, Start, End, DelaySteps} <- Ps,
              From <- lists:usort(Froms), To <- lists:usort(Tos),
              N <- lists:seq(Start, End)],
    lists:foldl(fun({Key, V}, D) -> orddict:append(Key, V, D) end,
                orddict:new(), Raw).

-spec send_initial_msgs_to_procs([term()], #sched{}) ->
                                        #sched{}.
send_initial_msgs_to_procs(Ops, S0) ->
    lists:foldl(fun({Proc, Msg}, S) ->
                        bang(scheduler, Proc, Msg, false, S)
                end, S0, Ops).

%% NOTE: bang/2, for use by simulation functions, is defined in the
%%       impure section.

bang(Sender, Rcpt, Msg, S) ->
    bang(Sender, Rcpt, Msg, true, S).

bang(scheduler, Rcpt, Msg, false, S) ->
    P = fetch_proc(Rcpt, S),
    store_proc(P#proc{mbox = P#proc.mbox ++ [{imsg, scheduler, Rcpt, Msg}]}, S);
bang(Sender, Rcpt, Msg, IncrSentP,
     #sched{partitions = PartD, delays = DelayD, step = Step} = S) ->
    DropP = case orddict:find({Sender, Rcpt}, PartD) of
                {ok, PartSteps} -> lists:member(Step, PartSteps);
                error           -> false
            end,
    Delay = case orddict:find({Sender, Rcpt}, DelayD) of
                {ok, DelayStepList} ->
                    case lists:keyfind(Step, 1, DelayStepList) of
                        false           -> false;
                        {_, DelaySteps} -> DelaySteps
                    end;
                error            -> false
            end,
    if is_integer(Delay) ->
            Trc = {delay, S#sched.step, Sender, Rcpt, Msg, {num_rounds, Delay}},
            add_trace(Trc, bang2(Sender, Rcpt, Msg, IncrSentP, {t_delay, Delay}, S));
       DropP ->
            Trc = {drop, S#sched.step, Sender, Rcpt, Msg},
            add_trace(Trc, S);
       true ->
            bang2(Sender, Rcpt, Msg, IncrSentP, t_normal, S)
    end.

bang2(Sender, Rcpt, Msg, IncrSentP, DeliveryType, #sched{numsent = NS0} = S) ->
    P = fetch_proc(Sender, S),
    NumSent = if IncrSentP -> NS0 + 1;
                 true      -> NS0
              end,
    Trc = {bang, S#sched.step, Sender, Rcpt, Msg},
    store_proc(add_outgoing_msg(Sender, Rcpt, Msg, DeliveryType, P),
               add_trace(Trc, S#sched{numsent = NumSent})).

fetch_proc(Name, S) ->
    orddict:fetch(Name, S#sched.procs).

%% NOTE: For export to outside world/external API

get_proc_state(Name, S) ->
    (fetch_proc(Name, S))#proc.state.

store_proc(P, S) ->
    S#sched{procs = orddict:store(P#proc.name, P, S#sched.procs)}.

runnable_proc_p(#proc{mbox = Mbox, outbox = Outbox}) ->
    Mbox /= [] orelse (not queue:is_empty(Outbox)).

runnable_any_proc_p(S) ->
    lists:any(fun({_Name, P}) -> runnable_proc_p(P) end, S#sched.procs).

runnable_procs(S) ->
    [Name || {Name, P} <- S#sched.procs, runnable_proc_p(P)].

receivable_proc_p(#proc{recv_w_timeout = undefined}) ->
    false;
receivable_proc_p(_) ->
    true.

receivable_any_proc_p(S) ->
    lists:any(fun({_Name, P}) -> receivable_proc_p(P) end, S#sched.procs).

receivable_procs(S) ->
    [Name || {Name, P} <- S#sched.procs, receivable_proc_p(P)].

run_scheduler(S) ->
    run_scheduler(S, 10000).

run_scheduler(S0, 0) ->
    %% Run one more time: if the processes are stupid enough to
    %% consume timeout messages without doing The Right Thing, then S1
    %% should have the last timeout message consumed so that all procs
    %% in S1 is neither runnable nor receivable.
    S1 = run_scheduler_with_tokens(S0#sched.tokens, S0),
    {runnable_any_proc_p(S1) orelse receivable_any_proc_p(S1), S1};
run_scheduler(S0, MaxIters) ->
    S1 = run_scheduler_with_tokens(S0#sched.tokens, S0),
    if S0#sched.step == S1#sched.step ->
            %% No work was done on that iteration, need to send 'timeout'?
            case receivable_any_proc_p(S1) of
                false ->
                    {false, S1};
                true ->
                    %% There's at least 1 proc waiting for a timeout message.
                    %% Bummer.  Find it/them and get moving again.
                    Waiters = receivable_procs(S1),
                    S2 = lists:foldl(
                           fun(Proc, S) ->
                                   bang(scheduler, Proc, timeout, false, S)
                           end, S1, Waiters),
                    run_scheduler(S2, MaxIters - 1)
            end;
        true ->
            run_scheduler(S1, MaxIters - 1)
    end.

run_scheduler_with_tokens(Tokens, Schedule) ->
    try
        lists:foldl(fun(Name, S) ->
                            consume_scheduler_token(Name, S)
                    end, Schedule, Tokens)
    catch throw:{receive_crash, NewS} ->
            NewS
    end.

%% consume_scheduler_token(check_runnable, S) when is_atom(ProcName) ->
%%     {false, S};
consume_scheduler_token(ProcName, S) when is_atom(ProcName) ->
    P = fetch_proc(ProcName, S),
    consume_scheduler_token(P, S, 0).

consume_scheduler_token(_P, S, 3) ->
    S;
consume_scheduler_token(P = #proc{mbox = Mbox, outbox = Outbox},
                        S, IterNum) ->
    OutboxNotEmpty = not queue:is_empty(Outbox), % very cheap
    case P#proc.next of
        mbox when Mbox /= [] ->
            NewS = run_proc_receive(P, S),
            try
                P1 = fetch_proc(P#proc.name, NewS),
                if NewS#sched.step /= S#sched.step ->
                        store_proc(rotate_next_type(P1), NewS);
                   true ->
                        consume_scheduler_token(rotate_next_type(P), S, IterNum + 1)
                end
            catch
                error:function_clause ->
                    %% Almost certain cause: the proc's receive pattern failed
                    Name = P#proc.name,
                    NewToks = [T || T <- NewS#sched.tokens, T /= Name],
                    NewS2 = NewS#sched{tokens = NewToks,
                                       crashed = [Name|NewS#sched.crashed]},
                    throw({receive_crash, NewS2})
            end;
        outbox when OutboxNotEmpty ->
            case queue:out(P#proc.outbox) of
                {{value, {IMsg, 0}}, Q2} ->
                    deliver_rotate_and_incr_step(IMsg, Q2, P#proc.name, S);
                {{value, {IMsg, DelaySteps}}, Q2} ->
                    Q3 = queue:in({IMsg, DelaySteps - 1}, Q2),
                    store_proc(rotate_next_type(P#proc{outbox = Q3}),
                               incr_step(S))
            end;
        _ ->
            consume_scheduler_token(rotate_next_type(P), S, IterNum + 1)
    end.

deliver_rotate_and_incr_step(IMsg, Q2, ProcName, S) ->
    NewS = deliver_msg(IMsg, S),
    P2 = fetch_proc(ProcName, NewS),
    store_proc(rotate_next_type(P2#proc{outbox=Q2}), incr_step(NewS)).

add_trace(Msg, S) ->
    S#sched{trace = [Msg|S#sched.trace]}.

%% NOTE: For export to outside world/external API

get_trace(S) ->
    lists:reverse(S#sched.trace).

get_utrace(S) ->
    lists:reverse(S#sched.utrace).

get_step(S) ->
    S#sched.step.

get_tokens(S) ->
    S#sched.tokens.

get_mailbox(ProcName, S) ->
    P = fetch_proc(ProcName, S),
    P#proc.mbox.

incr_numsent(#sched{numsent = NumSent} = S) ->
    S#sched{numsent = NumSent + 1}.

incr_step(#sched{step = Step} = S) ->
    S#sched{step = Step + 1}.

add_outgoing_msg(Sender, Rcpt, Msg, t_normal, P) ->
    add_outgoing_msg(Sender, Rcpt, Msg, {t_delay, 0}, P);
add_outgoing_msg(Sender, Rcpt, Msg, {t_delay, DelaySteps0}, P) ->
    Q = P#proc.outbox,
    L = queue:to_list(Q),
    %% NOTE: We need to preserve message order between any Sender & Rcpt!
    %%       The value of DelaySteps0 is advisory only: we may delay
    %%       the message for longer.  The if stmt below will guarantee
    %%       that each new message is delayed for at least 1 round longer
    %%       than any other message.
    DelaySteps = if L == [] ->
                         0;
                    true ->
                         MaxDelay = lists:max([Rnds || {_Imsg, Rnds} <- L]),
                         if DelaySteps0 > MaxDelay -> DelaySteps0;
                            true                   -> MaxDelay + 1
                         end
                 end,
    P#proc{outbox = queue:in({{imsg, Sender, Rcpt, Msg}, DelaySteps}, Q)}.

deliver_msg({imsg, Sender, Rcpt, Msg} = IMsg, S) ->
    Trc = {deliver, S#sched.step, Sender, Rcpt, Msg},
    try
        P = fetch_proc(Rcpt, S),
        store_proc(P#proc{mbox = P#proc.mbox ++ [IMsg]}, add_trace(Trc, S))
    catch error:function_clause ->
            S                                   % fetch_proc failed, rcpt dead
    end.

rotate_next_type(P) ->
    P#proc{next = case P#proc.next of
                      mbox   -> outbox;
                      outbox -> mbox
                  end}.

%%% Impure hackery for an impure world.

run_proc_receive(ProcName, S) when is_atom(ProcName) ->
    run_proc_receive(fetch_proc(ProcName, S), S);
run_proc_receive(P0 = #proc{name = ProcName}, S = #sched{module = Module}) ->
    erlang:put({?MODULE, sched}, S),
    erlang:put({?MODULE, self}, P0#proc.name),
    RecvFun0 = if P0#proc.recv_w_timeout /= undefined -> P0#proc.recv_w_timeout;
                  true                                -> P0#proc.recv_gen
               end,
    RecvFun = if is_function(RecvFun0, 2) ->
                      RecvFun0;
                 true ->
                      fun(A, B) -> Module:RecvFun0(A, B) end
              end,
    RecvVal = receive_loop(P0#proc.mbox, RecvFun, P0#proc.state),
    NewS = erlang:erase({?MODULE, sched}),
    _ = erlang:erase({?MODULE, self}),
    case RecvVal of
        %% Return values from proc receive function
        {{imsg, Sender, Rcpt, Msg} = IMsg, {recv_general, RecFun0, NewProcS}} ->
            RecFun = if RecFun0 == same  -> P0#proc.recv_gen;
                        true             -> RecFun0
                     end,
            Trc = {recv, NewS#sched.step, Sender, Rcpt, Msg},
            P1 = fetch_proc(ProcName, NewS),
            NewS2 = store_proc(P1#proc{state = NewProcS,
                                       mbox = P1#proc.mbox --[IMsg],
                                       recv_gen = RecFun,
                                       recv_w_timeout = undefined},
                               insert_recv_trace(Trc, S, NewS)),
            incr_step(NewS2);
        {{imsg, Sender, Rcpt, Msg} = IMsg, {recv_timeout, RecTFun0, NewProcS}} ->
            RecTFun = if RecTFun0 == same -> P0#proc.recv_w_timeout;
                         true             -> RecTFun0
                      end,
            Trc = {recv, NewS#sched.step, Sender, Rcpt, Msg},
            P1 = fetch_proc(ProcName, NewS),
            NewS2 = store_proc(P1#proc{state = NewProcS,
                                       mbox = P1#proc.mbox --[IMsg],
                                       recv_w_timeout = RecTFun},
                               insert_recv_trace(Trc, S, NewS)),
            incr_step(NewS2);
        %% Values from receive_loop()
        no_match ->
            S;
        {error, Msg, X, Y} ->
            Tr = erlang:get_stacktrace(),
            NewS2 = add_trace({process_crash, ProcName, Msg, X, Y, Tr}, NewS),
            NewS3 = NewS2#sched{procs = orddict:erase(ProcName, S#sched.procs)},
            incr_step(NewS3)
    end.

receive_loop([], _Fun, _St) ->
    no_match;
receive_loop([{imsg, _Sender, _Rcpt, H} = IMsg|T], RecvFun, ProcState) ->
    try
        Res = RecvFun(H, ProcState),
        {IMsg, Res}
    catch
        error:function_clause ->
            receive_loop(T, RecvFun, ProcState);
        X:Y ->
            {error, H, X, Y}
    end.

insert_recv_trace(Trc, #sched{trace = T1}, NewS = #sched{trace = T2})
  when length(T1) == length(T2) ->
    %% The user's receive func didn't insert any trace messages, e.g. bang
    add_trace(Trc, NewS);
insert_recv_trace(Trc, #sched{trace = T1}, NewS = #sched{trace = T2}) ->
    UserTraces = lists:sublist(T2, 1, length(T2) - length(T1)),
    NewS#sched{trace = UserTraces ++ [Trc] ++ T1}.        

self() ->
    erlang:get({?MODULE, self}).

add_utrace(Msg) ->
    #sched{utrace = U} = S = erlang:get({?MODULE, sched}),
    erlang:put({?MODULE, sched},
               S#sched{utrace = [{?MODULE:self(), S#sched.step, Msg}|U]}).

bang(Rcpt, Msg) ->
    S = erlang:get({?MODULE, sched}),
    erlang:put({?MODULE, sched}, bang(?MODULE:self(), Rcpt, Msg, true, S)),
    Msg.

%%% Test funcs

t_sched0(InitialMessages) ->
    t_sched0(InitialMessages, fun t_client0_recv/2, fun t_server0_recv/2).

t_sched0(InitialMessages, ClientFun, ServerFun) ->
    new_sim([{c, st, ClientFun}], [{s, st, ServerFun}],
            InitialMessages, [c], [], []).

t_sched0a() ->
    t_sched0([{c, {echo, s, hello_world}},
              {c, {echo_specific, s, hello_again}}]).

t_sched0b() ->
    t_sched0([{c, {no_match_here}},
              {c, {echo_specific, s, hello_again}}]).

t_sched0c() ->
    t_sched0([]).

t_client0_recv({echo, Server, Msg}, St) ->
    ?MODULE:bang(Server, {echo, ?MODULE:self(), Msg}),
    {recv_general, same, St};
t_client0_recv({echo_specific, Server, Msg}, St) ->
    ?MODULE:bang(Server, {echo, ?MODULE:self(), {your_echo_was, Msg}}),
    {recv_timeout, fun t_client0_echo_reply/2, St};
t_client0_recv(OtherMsg, St) ->
    ?MODULE:add_utrace({other_msg, OtherMsg}),
    {recv_general, same, St}.

t_client0_echo_reply({your_echo_was, TheReply}, _St) ->
    ?MODULE:add_utrace({got_echo_reply, TheReply}),
    {recv_general, same, TheReply};
t_client0_echo_reply(timeout, _St) ->
    {recv_timeout, same, i_was_stupid_and_consumed_a_timeout}.

t_server0_recv({echo, Pid, Msg}, St) ->
    ?MODULE:bang(Pid, Msg),
    {recv_general, same, St}.

run_proc_receive_test() ->
    Sa = t_sched0a(),
    #sched{step = 1, numsent = 1} = Sa2 = run_proc_receive(c, Sa),
    2 = length(Sa2#sched.trace),  % One recv, one bang
    Pa = fetch_proc(c, Sa2),
    1 = length(Pa#proc.mbox),
    undefined = Pa#proc.recv_w_timeout,
    1 = queue:len(Pa#proc.outbox),

    Sb = t_sched0b(),
    Sb2 = run_proc_receive(c, Sb),
    1 = length(Sb2#sched.trace),  % One recv (the msg from init)
    Pb = fetch_proc(c, Sb2),
    1 = length(Pb#proc.mbox),
    0 = queue:len(Pb#proc.outbox),

    Sc = t_sched0c(),
    Sc2 = run_proc_receive(c, Sc),
    Sc = Sc2,

    ok.

run_scheduler_with_tokens_test() ->
    S1 = run_scheduler_with_tokens([c,c,c,s,s,s,c,s,s,s,c,c,c,c,c,s,s,s,c,s,s,s,c,c], slf_msgsim:t_sched0a()),
    check_t_sched0a_sanity(S1).

run_scheduler_test() ->
    {false, S1} = run_scheduler(slf_msgsim:t_sched0a()),
    check_t_sched0a_sanity(S1).

check_t_sched0a_sanity(S) ->
    Trace1 = S#sched.trace,
    UTrace1 = S#sched.utrace,
    RecvInits = [x || {recv, _, scheduler, c, _} <- Trace1],
    RecvOthers = [x || {recv, _, Sender, _, _} <- Trace1, Sender /= scheduler],
    Bangs = [x || {bang, _, _, _, _} <- Trace1],
    Delivers = [x || {deliver, _, _, _, _} <- Trace1],
    2 = length(RecvInits),
    {4, 4, 4} = {length(RecvOthers), length(Bangs), length(Delivers)},

    Clnt = fetch_proc(c, S),
    hello_again = Clnt#proc.state,
    [] = Clnt#proc.mbox,
    true = queue:is_empty(Clnt#proc.outbox),

    Svr = fetch_proc(s, S),
    st = Svr#proc.state,
    [] = Svr#proc.mbox,
    true = queue:is_empty(Svr#proc.outbox),

    {utrace_len, 2} = {utrace_len, length(UTrace1)},

    false = runnable_any_proc_p(S),
    S2 = run_scheduler_with_tokens([s,c,s,c], S),
    S2 = S,

    ok.

not_runnable_but_is_receivable_test() ->
    S0 = slf_msgsim:t_sched0([{c, {echo_specific, s, send_this_to_server}}],
                          fun t_client0_recv/2,
                          fun t_server0_throw_away_all/2),
    {true, S1} = run_scheduler(S0),
    false = runnable_any_proc_p(S1),
    true = receivable_any_proc_p(S1),
    S1.

t_server0_throw_away_all(_Msg, St) ->
    {recv_general, same, St}.

message_order_via_noparts_1_1_echomany_sim_test() ->
    Opts = [disable_partitions, {max_clients,1}, {max_servers,1}],
    true = eqc:quickcheck(slf_msgsim_qc:prop_simulate(echomany_sim, Opts)).
