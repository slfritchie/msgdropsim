%%%-------------------------------------------------------------------
%%% @author Scott Lystig Fritchie <fritchie@snookles.com>
%%% @copyright (C) 2011, Scott Lystig Fritchie
%%% @doc
%%%
%%% @end
%%% Created : 26 Mar 2011 by Scott Lystig Fritchie <fritchie@snookles.com>
%%%-------------------------------------------------------------------
-module(distrib_counter_bad4_sim).

-compile(export_all).

-include_lib("eqc/include/eqc.hrl").

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
    [{Clnt, [], fun counter_client1/2} || Clnt <- Clients].

%% required
gen_server_initial_states(NumServers, _Props) ->
    Servers = lists:sublist(all_servers(), 1, NumServers),
    [{Server, gen_nat_nat2(5, 1), fun counter_server1/2} || Server <- Servers].

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
                      %% Retrograde counter if we truncate the floats?
                      Lt = [trunc(Count) || Count <- L],
                      decreasing_p(Lt)
              end,                                 
    ClientRetroP = lists:any(F_retro, Clients),
    ?WHENFAIL(
       io:format("Failed:\nF1 = ~p\nF2 = ~p\nEnd2 = ~P\n"
                 "Runnable = ~p, Receivable = ~p\n"
                 "Emitted counters = ~p\n",
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
           conjunction([{runnable, Runnable == false},
                        {ops_finish, length(Ops) == length(UTrc)},
                        {emits_unique, length(Emitted) ==
                                      length(lists:usort(Emitted))},
                        {per_client_not_retro, not ClientRetroP}])
       end))))))))))).

%%% Protocol implementation

%% Known to be flawed: ask each server for its counter, then
%% choose the max of all responses.  The servers are naive
%% and are not keeping per-key counters but rather a single
%% counter for the entire server.

counter_client1({counter_op, Servers}, _St) ->
    [slf_msgsim:bang(Server, {incr_counter, slf_msgsim:self()}) ||
        Server <- Servers],
    {recv_timeout, fun counter_client1_reply/2, {Servers, []}}.

counter_client1_reply({incr_counter_reply, Server, Count},
                      {Waiting, Replies})->
    Replies2 = [{Server, Count}|Replies],
    case Waiting -- [Server] of
        [] ->
            Val = make_val(Replies2),
            slf_msgsim:add_utrace({counter, Val}),
            {recv_general, same, unused};
        Waiting2 ->
            {recv_timeout, same, {Waiting2, Replies2}}
    end;
counter_client1_reply(timeout, {Waiting, Replies}) ->
    Val = if length(Waiting) > length(Replies) ->
                  timeout;
             true ->
                  make_val(Replies)
          end,
    slf_msgsim:add_utrace({counter, Val}),
    {recv_general, same, unused}.

counter_server1({incr_counter, From}, Count) ->
    slf_msgsim:bang(From, {incr_counter_reply, slf_msgsim:self(), Count}),
    {recv_general, same, Count + 1}.

make_val(Replies) ->
    Ns = [N || {_Server, N} <- Replies],
    ByN = lists:sort([{N, Server} || {Server, N} <- Replies]),
    SvrOrder = [Server || {_N, Server} <- ByN],
    LHS_int = lists:max(Ns),
    Left = integer_to_list(LHS_int),
    Right = make_suffix(SvrOrder),
    list_to_float(Left ++ "." ++ Right).

make_suffix(ReplyServers) ->
    lists:flatten(make_suffix2(ReplyServers)).

make_suffix2(ReplyServers) ->
    [lists:nth(2, atom_to_list(Svr)) || Svr <- ReplyServers].

%%% Misc....

all_clients() ->
    [c1, c2, c3, c4, c5, c6, c7, c8, c9].

all_servers() ->
    [s1, s2, s3, s4, s5, s6, s7, s8, s9].

decreasing_p([A, B|Rest]) when A =< B ->
    decreasing_p([B|Rest]);
decreasing_p([_]) ->
    false;
decreasing_p([]) ->
    false;
decreasing_p(_) ->
    true.
