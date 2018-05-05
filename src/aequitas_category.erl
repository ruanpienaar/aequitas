%% Copyright (c) 2018 Guilherme Andrade
%%
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy  of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO WORK SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%% DEALINGS IN THE SOFTWARE.

%% @reference <a target="_parent" href="https://en.wikipedia.org/wiki/Standard_score">Standard Score / Z-Score</a> (Wikpiedia)
%% @reference <a target="_parent" href="http://www.statisticshowto.com/probability-and-statistics/hypothesis-testing/t-score-vs-z-score/">T-Score vs. Z-score</a> (statisticshowto.com)
%% @reference <a target="_parent" href="https://www.itl.nist.gov/div898/handbook/eda/section3/eda35h.htm">Detection of Outliers</a> (Wikipedia)
%% @reference <a target="_parent" href="https://en.wikipedia.org/wiki/Robust_measures_of_scale">Robust measures of scale</a> (Wikipedia)
%% @reference <a target="_parent" href="https://pkghosh.wordpress.com/2015/08/25/anomaly-detection-with-robust-zscore/">Anomaly Detection with Robust Zscore</a> (pkghosh.wordpress.com)
%% @reference <a target="_parent" href="https://colingorrie.github.io/outlier-detection.html">Three ways to detect outliers</a> (colingorrie.github.io)
%% @reference <a target="_parent" href="https://en.wikipedia.org/wiki/Interquartile_range">Interquartile range</a> (Wikipedia)

-module(aequitas_category).

% https://gist.github.com/marcelog/97708058cd17f86326c82970a7f81d40#file-simpleproc-erl

%%-------------------------------------------------------------------
%% API Function Exports
%%-------------------------------------------------------------------

-export(
   [start_link/1,
    ask/3,
    async_ask/3,
    set_settings/2,
    validate_settings/1,
    async_reload_settings/1,
    report_work_stats/2
   ]).

-ignore_xref(
   [start_link/1
   ]).

%%-------------------------------------------------------------------
%% OTP Function Exports
%%-------------------------------------------------------------------

-export(
   [init/1,
    system_code_change/4,
    system_continue/3,
    system_terminate/4,
    write_debug/3
   ]).

-ignore_xref(
   [init/1,
    system_code_change/4,
    system_continue/3,
    system_terminate/4,
    write_debug/3
   ]).

%%-------------------------------------------------------------------
%% Macro Definitions
%%-------------------------------------------------------------------

-define(DEFAULT_MAX_WINDOW_SIZE, 10000).
-define(DEFAULT_MAX_WINDOW_DURATION, 5000).
-define(DEFAULT_IQR_MULTIPLIER, 1.5).
-define(DEFAULT_MAX_COLLECTIVE_RATE, infinity).

-define(DEFAULT_WORK_WEIGHT, 1).
-define(DEFAULT_RETURN_STATS, false).

-define(is_pos_integer(V), (is_integer((V)) andalso ((V) > 0))).
-define(is_non_neg_integer(V), (is_integer((V)) andalso ((V) >= 0))).
-define(is_non_neg_number(V), (is_number((V)) andalso ((V) >= 0))).

%%-------------------------------------------------------------------
%% Record and Type Definitions
%%-------------------------------------------------------------------

-record(settings, {
          max_window_size :: pos_integer() | infinity,
          max_window_duration :: pos_integer() | infinity,
          iqr_multiplier :: number(),
          max_collective_rate :: non_neg_integer() | infinity
         }).
-type settings() :: #settings{}.

-record(work, {
          actor_id :: term(),
          weight :: pos_integer(),
          timestamp :: integer()
         }).
-type work() :: #work{}.

-record(state, {
          category :: atom(), % the category identifier
          settings :: settings(), % the category settings
          %%
          window :: queue:queue(work()), % sliding window
          window_size :: non_neg_integer(), % queue:len/1 is expensive
          %%
          work_shares_table :: ets:tab(),
          work_stats_status :: updated | outdated | updating,
          work_stats :: aequitas_work_stats:t(),
          %%
          work_stats_pid :: pid(),
          work_stats_mon :: reference()
         }).
-type state() :: #state{}.

-type ask_params() ::
        #{ weight => pos_integer(),
           return_stats => boolean()
         }.

-type setting_opt() ::
        {max_window_size, pos_integer() | infinity} |
        {max_window_duration, pos_integer() | infinity}.
-export_type([setting_opt/0]).

-type overridable_setting_opt() ::
        {iqr_multiplier, number()} |
        {max_collective_rate, non_neg_integer() | infinity}.
-export_type([overridable_setting_opt/0]).

-type ask_opt() ::
        {weight, pos_integer()} |
        {override, overridable_setting_opt()} |
        return_stats.
-export_type([ask_opt/0]).

%%-------------------------------------------------------------------
%% API Function Definitions
%%-------------------------------------------------------------------

-spec start_link(atom()) -> {ok, pid()} | {error, {already_started,pid()}}.
%% @private
start_link(Category) ->
    Args = [{self(), [Category]}],
    Timeout = infinity,
    Opts = [],
    proc_lib:start_link(?MODULE, init, Args, Timeout, Opts).

-spec ask(atom() | pid(), term(), [ask_opt()]) -> Status | {Status, Stats}
             when Status :: accepted | rejected,
                  Stats :: aequitas_work_stats:t().
%% @private
ask(Category, ActorId, Opts) when is_atom(Category) ->
    Pid = ensure_server(Category),
    ask(Pid, ActorId, Opts);
ask(Pid, ActorId, Opts) when is_pid(Pid) ->
    {Tag, Mon} = async_ask(Pid, ActorId, Opts),
    wait_call_reply(Tag, Mon).

-spec async_ask(atom() | pid(), term(), [ask_opt()]) -> {reference(), reference()}.
%% @private
async_ask(Category, ActorId, Opts) when is_atom(Category) ->
    Pid = ensure_server(Category),
    async_ask(Pid, ActorId, Opts);
async_ask(Pid, ActorId, Opts) when is_pid(Pid) ->
    Params = parse_ask_opts(Opts),
    send_call(Pid, {ask, ActorId, Params}).

-spec set_settings(atom(), [setting_opt()])
        -> ok | {error, {invalid_setting_opt | invalid_setting_opts, _}}.
%% @private
set_settings(Category, SettingOpts) when is_atom(Category) ->
    case validate_settings(SettingOpts) of
        ok ->
            aequitas_cfg:set({category, Category}, SettingOpts),
            reload_settings(Category);
        {error, Reason} ->
            {error, Reason}
    end.

-spec validate_settings([setting_opt()]) -> ok | {error, term()}.
%% @private
validate_settings(SettingOpts) ->
    case parse_settings_opts(SettingOpts) of
        {ok, _Settings} ->
            ok;
        {error, Reason} ->
            {error, Reason}
    end.

-spec async_reload_settings(atom()) -> ok.
%% @private
async_reload_settings(Category) when is_atom(Category) ->
    Pid = ensure_server(Category),
    send_cast(Pid, reload_settings).

-spec report_work_stats(pid(), aequitas_work_stats:t()) -> ok.
%% @private
report_work_stats(Pid, WorkStats) ->
    send_cast(Pid, {report_work_stats, WorkStats}).

%%-------------------------------------------------------------------
%% OTP Function Definitions
%%-------------------------------------------------------------------

-spec init({pid(), [atom(), ...]}) -> no_return().
%% @private
init({Parent, [Category]}) ->
    Debug = sys:debug_options([]),
    Server = server_name(Category),
    case aequitas_proc_reg:register(Server, self()) of
        ok ->
            Settings = load_settings(Category),
            WorkSharesTable = ets:new(work_shares, [protected, {read_concurrency,true}]),
            {ok, WorkStatsPid} = aequitas_work_stats:start(self(), WorkSharesTable),
            proc_lib:init_ack(Parent, {ok, self()}),
            State =
                #state{
                   category = Category,
                   settings = Settings,
                   window = queue:new(),
                   window_size = 0,
                   work_shares_table = WorkSharesTable,
                   work_stats_status = updated,
                   work_stats = #{ nr_of_samples => 0, seconds_to_generate => 0 },
                   work_stats_pid = WorkStatsPid,
                   work_stats_mon = monitor(process, WorkStatsPid)
                  },
            loop(Parent, Debug, State);
        {error, {already_registered, ExistingPid}} ->
            proc_lib:init_ack(Parent, {error, {already_started, ExistingPid}})
    end.

-spec write_debug(io:device(), term(), term()) -> ok.
%% @private
write_debug(Dev, Event, Name) ->
    % called by sys:handle_debug().
    io:format(Dev, "~p event = ~p~n", [Name, Event]).

-spec system_continue(pid(), [sys:debug_opt()], state()) -> no_return().
%% @private
system_continue(Parent, Debug, State) ->
    % http://www.erlang.org/doc/man/sys.html#Mod:system_continue-3
    loop(Parent, Debug, State).

-spec system_terminate(term(), pid(), [sys:debug_opt()], state()) -> no_return().
%% @private
system_terminate(Reason, _Parent, _Debug, _State) ->
    % http://www.erlang.org/doc/man/sys.html#Mod:system_terminate-4
    exit(Reason).

-spec system_code_change(state(), ?MODULE, term(), term()) -> {ok, state()}.
%% http://www.erlang.org/doc/man/sys.html#Mod:system_code_change-4
%% @private
system_code_change(State, _Module, _OldVsn, _Extra) ->
    {ok, State}.

%%-------------------------------------------------------------------
%% Internal Functions Definitions - Initialization and Requests
%%-------------------------------------------------------------------

ensure_server(Category) ->
    Server = server_name(Category),
    case aequitas_proc_reg:whereis(Server) of
        undefined ->
            case aequitas_category_sup:start_child([Category]) of
                {ok, Pid} ->
                    Pid;
                {error, {already_started, ExistingPid}} ->
                    ExistingPid
            end;
        Pid ->
            Pid
    end.

-spec reload_settings(atom()) -> ok.
%% @private
reload_settings(Category) when is_atom(Category) ->
    Pid = ensure_server(Category),
    {Tag, Mon} = send_call(Pid, reload_settings),
    wait_call_reply(Tag, Mon).

server_name(Category) ->
    list_to_atom(
      atom_to_list(?MODULE)
      ++ "."
      ++ atom_to_list(Category)).

load_settings(Category) ->
    SettingOpts = aequitas_cfg:get({category, Category}, []),
    case parse_settings_opts(SettingOpts) of
        {ok, Settings} ->
            Settings;
        {error, Reason} ->
            error(#{ category => Category, reason => Reason })
    end.

parse_settings_opts(SettingOpts) ->
    DefaultSettings =
        #settings{ max_window_size = ?DEFAULT_MAX_WINDOW_SIZE,
                   max_window_duration = ?DEFAULT_MAX_WINDOW_DURATION,
                   iqr_multiplier = ?DEFAULT_IQR_MULTIPLIER,
                   max_collective_rate = ?DEFAULT_MAX_COLLECTIVE_RATE
                 },
    parse_settings_opts(SettingOpts, DefaultSettings).

parse_settings_opts([{max_window_size, MaxWindowSize} | Next], Acc)
  when ?is_pos_integer(MaxWindowSize); MaxWindowSize =:= infinity ->
    parse_settings_opts(
      Next, Acc#settings{ max_window_size = MaxWindowSize }
     );
parse_settings_opts([{max_window_duration, MaxWindowDuration} | Next], Acc)
  when ?is_pos_integer(MaxWindowDuration); MaxWindowDuration =:= infinity ->
    parse_settings_opts(
      Next, Acc#settings{ max_window_duration = MaxWindowDuration }
     );
parse_settings_opts([{iqr_multiplier, IQRMultiplier} | Next], Acc)
  when ?is_non_neg_number(IQRMultiplier) ->
    parse_settings_opts(
      Next, Acc#settings{ iqr_multiplier = IQRMultiplier }
     );
parse_settings_opts([{max_collective_rate, MaxCollectiveRate} | Next], Acc)
  when ?is_non_neg_integer(MaxCollectiveRate);
       MaxCollectiveRate =:= infinity ->
    parse_settings_opts(
      Next, Acc#settings{ max_collective_rate = MaxCollectiveRate }
     );
parse_settings_opts([], Acc) ->
    {ok, Acc};
parse_settings_opts([InvalidOpt | _Next], _Acc) ->
    {error, {invalid_setting_opt, InvalidOpt}};
parse_settings_opts(InvalidOpts, _Acc) ->
    {error, {invalid_setting_opts, InvalidOpts}}.

send_call(Pid, Call) ->
    Mon = monitor(process, Pid),
    Tag = Mon,
    Pid ! {call, self(), Tag, Call},
    {Tag, Mon}.

send_cast(Pid, Cast) ->
    Pid ! {cast, Cast},
    ok.

wait_call_reply(Tag, Mon) ->
    receive
        {Tag, Reply} ->
            demonitor(Mon, [flush]),
            Reply;
        {'DOWN', Mon, process, _Pid, Reason} ->
            error({category_process_stopped, Reason})
    end.

%%-------------------------------------------------------------------
%% Internal Functions Definitions - Execution Loop
%%-------------------------------------------------------------------

loop(Parent, Debug, State) when State#state.work_stats_status =:= outdated ->
    WorkStatsPid = State#state.work_stats_pid,
    aequitas_work_stats:generate_work_stats(WorkStatsPid),
    UpdatedState = set_work_stats_status(updating, State),
    loop(Parent, Debug, UpdatedState);
loop(Parent, Debug, State) ->
    case loop_action(State) of
        simple ->
            receive
                Msg ->
                    handle_msg(Msg, Parent, Debug, State)
            end;
        {drop, Work} ->
            UpdatedState = drop_work(Work, State),
            loop(Parent, Debug, UpdatedState);
        {drop_after, Work, WaitTime} ->
            receive
                Msg ->
                    handle_msg(Msg, Parent, Debug, State)
            after
                WaitTime ->
                    UpdatedState = drop_work(Work, State),
                    loop(Parent, Debug, UpdatedState)
            end;
        {hibernate_after, WaitTime} ->
            receive
                Msg ->
                    handle_msg(Msg, Parent, Debug, State)
            after
                WaitTime ->
                    hibernate(Parent, Debug, State)
            end
    end.

loop_action(State) ->
    WorkPeek = queue:peek(State#state.window),
    Settings = State#state.settings,
    loop_action(WorkPeek, Settings, State).

loop_action({value, Work}, Settings, State)
  when Settings#settings.max_window_size < State#state.window_size ->
    {drop, Work};
loop_action({value, Work}, Settings, _State)
  when Settings#settings.max_window_duration =/= infinity ->
    Now = erlang:monotonic_time(milli_seconds),
    ExpirationTs = Work#work.timestamp + Settings#settings.max_window_duration,
    WaitTime = ExpirationTs - Now,
    case WaitTime =< 0 of
        true ->
            {drop, Work};
        _ ->
            {drop_after, Work, WaitTime}
    end;
loop_action(empty, Settings, _State)
  when Settings#settings.max_window_duration =/= infinity ->
    IdleTimeout = Settings#settings.max_window_duration,
    {hibernate_after, IdleTimeout};
loop_action(_WorkPeek, _Settings, _State) ->
    simple.

drop_work(Work, State) ->
    UpdatedWindow = queue:drop(State#state.window),
    UpdatedWindowSize = State#state.window_size - 1,
    update_work_share(State#state.work_shares_table, Work#work.actor_id, -Work#work.weight),
    UpdatedState =
        State#state{
          window = UpdatedWindow,
          window_size = UpdatedWindowSize
         },
    set_work_stats_status(outdated, UpdatedState).

handle_msg({system, From, Request}, Parent, Debug, State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, State);
handle_msg(Msg, Parent, Debug, State) ->
    UpdatedDebug = sys:handle_debug(Debug, fun ?MODULE:write_debug/3, ?MODULE, {in, Msg}),
    handle_nonsystem_msg(Msg, Parent, UpdatedDebug, State).

handle_nonsystem_msg({call, Pid, Tag, {ask, ActorId, AskParams}}, Parent, Debug, State) ->
    {Reply, UpdatedState} = handle_ask(ActorId, AskParams, State),
    Pid ! {Tag, Reply},
    loop(Parent, Debug, UpdatedState);
handle_nonsystem_msg({call, Pid, Tag, reload_settings}, Parent, Debug, State) ->
    UpdatedState = handle_settings_reload(State),
    Pid ! {Tag, ok},
    loop(Parent, Debug, UpdatedState);
handle_nonsystem_msg({cast, reload_settings}, Parent, Debug, State) ->
    UpdatedState = handle_settings_reload(State),
    loop(Parent, Debug, UpdatedState);
handle_nonsystem_msg({cast, {report_work_stats, WorkStats}}, Parent, Debug, State) ->
    State2 = State#state{ work_stats = WorkStats },
    State3 = set_work_stats_status(updated, State2),
    loop(Parent, Debug, State3);
handle_nonsystem_msg(Msg, _Parent, _Debug, _State) ->
    error({unexpected_msg, Msg}).

handle_settings_reload(State) ->
    State#state{
      settings = load_settings(State#state.category)
     }.

hibernate(Parent, Debug, State) ->
    proc_lib:hibernate(?MODULE, system_continue, [Parent, Debug, State]).

%%-------------------------------------------------------------------
%% Internal Functions Definitions - Asking
%%-------------------------------------------------------------------

-spec parse_ask_opts([ask_opt()]) -> ask_params().
parse_ask_opts(Opts) ->
    parse_ask_opts(Opts, #{}).

parse_ask_opts([{weight, Weight} | Next], Acc)
  when ?is_pos_integer(Weight) ->
    parse_ask_opts(
      Next, Acc#{ weight => Weight }
     );
parse_ask_opts([return_stats | Next], Acc) ->
    parse_ask_opts(
      Next, Acc#{ return_stats => true }
     );
parse_ask_opts([{override, {iqr_multiplier, IQRMultiplier}} | Next], Acc)
  when ?is_non_neg_number(IQRMultiplier) ->
    parse_ask_opts(
      Next, Acc#{ iqr_multiplier => IQRMultiplier }
     );
parse_ask_opts([{override, {max_collective_rate, MaxCollectiveRate}} | Next], Acc)
  when ?is_non_neg_integer(MaxCollectiveRate) ->
    parse_ask_opts(
      Next, Acc#{ max_collective_rate => MaxCollectiveRate }
     );
parse_ask_opts([], Acc) ->
    Acc;
parse_ask_opts([InvalidOpt|_], _Acc) ->
    error({badarg, InvalidOpt});
parse_ask_opts(InvalidOpts, _Acc) ->
    error({badarg, InvalidOpts}).

handle_ask(ActorId, AskParams, State) ->
    Now = erlang:monotonic_time(milli_seconds),
    case has_reached_work_limit(ActorId, AskParams, State) orelse
         would_reach_max_collective_rate(AskParams, Now, State)
    of
        true ->
            maybe_return_stats_in_ask(AskParams, rejected, State);
        _ ->
            UpdatedState = accept(ActorId, AskParams, Now, State),
            maybe_return_stats_in_ask(AskParams, accepted, UpdatedState)
    end.

maybe_return_stats_in_ask(#{ return_stats := true }, Status, State) ->
    {{Status, State#state.work_stats}, State};
maybe_return_stats_in_ask(_AskParams, Status, State) ->
    {Status, State}.

has_reached_work_limit(ActorId, AskParams, State) ->
    case State#state.work_stats of
        #{ q3 := Q3, iqr := IQR } ->
            CurrentWorkShare = current_work_share(ActorId, State),
            IQRMultiplier = iqr_multiplier(AskParams, State),
            CurrentWorkShare > (Q3 + (IQR * IQRMultiplier));
        _ ->
            % not enough samples
            false
    end.

current_work_share(ActorId, State) ->
    WorkSharesTable = State#state.work_shares_table,
    case ets:lookup(WorkSharesTable, ActorId) of
        [{_, WorkShare}] ->
            WorkShare;
        [] ->
            0
    end.

iqr_multiplier(AskParams, State) ->
    Settings = State#state.settings,
    maps:get(iqr_multiplier, AskParams, Settings#settings.iqr_multiplier).

would_reach_max_collective_rate(AskParams, Timestamp, State) ->
    MaxCollectiveRate = max_collective_rate(AskParams, State),
    (MaxCollectiveRate =/= infinity andalso
     State#state.window_size =/= 0 andalso
     begin
         {value, OldestWork} = queue:peek(State#state.window),
         TimeElapsed = max(1, Timestamp - OldestWork#work.timestamp),
         HypotheticalCollectiveRate = State#state.window_size * (1000 / TimeElapsed),
         HypotheticalCollectiveRate >= MaxCollectiveRate
     end).

max_collective_rate(AskParams, State) ->
    Settings = State#state.settings,
    maps:get(max_collective_rate, AskParams, Settings#settings.max_collective_rate).

accept(ActorId, Params, Timestamp, State)
  when State#state.window_size >= (State#state.settings)#settings.max_window_size ->
    {value, Work} = queue:peek(State#state.window),
    UpdatedState = drop_work(Work, State),
    accept(ActorId, Params, Timestamp, UpdatedState);
accept(ActorId, Params, Timestamp, State) ->
    Weight = maps:get(weight, Params, ?DEFAULT_WORK_WEIGHT),
    Work =
        #work{
           actor_id = ActorId,
           weight = Weight,
           timestamp = Timestamp
          },

    UpdatedWindow = queue:in(Work, State#state.window),
    UpdatedWindowSize = State#state.window_size + 1,
    update_work_share(State#state.work_shares_table, ActorId, Weight),
    UpdatedState =
        State#state{
          window = UpdatedWindow,
          window_size = UpdatedWindowSize
         },
    set_work_stats_status(outdated, UpdatedState).

update_work_share(Table, ActorId, ShareIncr) ->
    (ets:update_counter(Table, ActorId, {2,ShareIncr}, {ActorId,0}) =:= 0
     andalso ets:delete(Table, ActorId)).

set_work_stats_status(Status, State) ->
    case {State#state.work_stats_status, Status} of
        {Same, Same} ->
            State;
        {updated, outdated} ->
            State#state{ work_stats_status = outdated };
        {outdated, updating} ->
            State#state{ work_stats_status = updating };
        {updating, updated} ->
            State#state{ work_stats_status = updated };
        {updating, outdated} ->
            State
    end.
