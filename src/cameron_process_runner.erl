%% @author Leandro Silva <leandrodoze@gmail.com>
%% @copyright 2011 Leandro Silva.

%% @doc The gen_server responsable to execute a process.

-module(cameron_process_runner).
-author('Leandro Silva <leandrodoze@gmail.com>').

-behaviour(gen_server).

% admin api
-export([start_link/2, stop/1]).
% public api
-export([schedule_job/1, run_job/1, handle/2]).
% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

%%
%% Includes and Records ---------------------------------------------------------------------------
%%

-include("include/cameron.hrl").

-record(state, {job, countdown}).

%%
%% Admin API --------------------------------------------------------------------------------------
%%

%% @spec start_link(Pname, Job) -> {ok, Pid} | ignore | {error, Error}
%% @doc Start a cameron_process server.
start_link(Pname, Job) ->
  gen_server:start_link({local, Pname}, ?MODULE, [Job], []).

%% @spec stop(Pname) -> ok
%% @doc Manually stops the server.
stop(Pname) ->
  gen_server:cast(Pname, stop).

%%
%% Public API -------------------------------------------------------------------------------------
%%

%% @spec schedule_job(Request) -> {ok, Job} | {error, Reason}
%% @doc It triggers an async dispatch of a resquest to run a process an pay a job.
schedule_job(#request{} = Request) ->
  {ok, _Job} = cameron_process_data:create_new_job(Request).

%% @spec mark_job_as_running(Job) -> ok
%% @doc Create a new process, child of cameron_process_sup, and then run the process (in
%%      parallel, of course) to the job given.
run_job(#job{uuid = JobUUID} = Job) ->
  case cameron_process_sup:start_child(Job) of
    {ok, _Pid} ->
      ok = gen_server:cast(?pname(JobUUID), {run_job, Job});
    {error, {already_started, _Pid}} ->
      ok
  end.

%%
%% Gen_Server Callbacks ---------------------------------------------------------------------------
%%

%% @spec init([Job]) -> {ok, State} | {ok, State, Timeout} | ignore | {stop, Reason}
%% @doc Initiates the server.
init([Job]) ->
  process_flag(trap_exit, true),
  {ok, #state{job = Job}}.

%% @spec handle_call(Job, From, State) ->
%%                  {reply, Reply, State} | {reply, Reply, State, Timeout} | {noreply, State} |
%%                  {noreply, State, Timeout} | {stop, Reason, Reply, State} | {stop, Reason, State}
%% @doc Handling call messages.

% handle_call generic fallback
handle_call(_Request, _From, State) ->
  {reply, undefined, State}.

%% @spec handle_cast(Msg, State) ->
%%                  {noreply, State} | {noreply, State, Timeout} | {stop, Reason, State}
%% @doc Handling cast messages.

% wake up to run a process
handle_cast({run_job, #job{uuid = JobUUID} = Job}, State) ->
  ok = cameron_process_data:mark_job_as_running(Job),

  StartInput = #task_input{job   = Job,
                           name  = "start",
                           pname = ?pname(JobUUID)},
  
  HandlerPid = spawn_link(?MODULE, handle, [1, StartInput]),
  io:format("[cameron_process_runner] handling :: JobUUID: ~s // HandlerPid: ~w~n", [JobUUID, HandlerPid]),
  
  % WARNING => countdown = ?
  {noreply, State#state{countdown = 3}};

% notify when a individual job is done
handle_cast({notify_done, _Index, #task_output{task_input = _TaskInput} = TaskOutput}, State) ->
  ok = cameron_process_data:save_task_result(TaskOutput),

  case State#state.countdown of
    1 ->
      ok = cameron_process_data:mark_job_as_done(State#state.job),
      NewState = State#state{countdown = 0},
      {stop, normal, NewState};
    N ->
      NewState = State#state{countdown = N - 1},
      {noreply, NewState}
  end;

% notify when a individual job fail
handle_cast({notify_error, _Index, #task_output{task_input = _TaskInput} = TaskOutput}, State) ->
  ok = cameron_process_data:save_error_on_task_execution(TaskOutput),

  case State#state.countdown of
    1 ->
      ok = cameron_process_data:mark_job_as_done(State#state.job),
      NewState = State#state{countdown = 0},
      {stop, normal, NewState};
    N ->
      NewState = State#state{countdown = N - 1},
      {noreply, NewState}
  end;

% manual shutdown
handle_cast(stop, State) ->
  {stop, normal, State};
    
% handle_cast generic fallback (ignore)
handle_cast(_Msg, State) ->
  {noreply, State}.

%% @spec handle_info(Info, State) ->
%%                  {noreply, State} | {noreply, State, Timeout} | {stop, Reason, State}
%% @doc Handling all non call/cast messages.

% exit // any reason
handle_info({'EXIT', Pid, Reason}, State) ->
  % i could do 'countdown' and mark_job_as_done here, couldn't i?
  #job{uuid = JobUUID} = State#state.job,
  io:format("[cameron_process_runner] info :: JobUUID: ~s // EXIT: ~w ~w~n", [JobUUID, Pid, Reason]),
  {noreply, State};
  
% down
handle_info({'DOWN',  Ref, Type, Pid, Info}, State) ->
  #job{uuid = JobUUID} = State#state.job,
  io:format("[cameron_process_runner] info :: JobUUID: ~s // DOWN: ~w ~w ~w ~w~n", [JobUUID, Ref, Type, Pid, Info]),
  {noreply, State};
  
handle_info(_Info, State) ->
  {noreply, State}.

%% @spec terminate(Reason, State) -> void()
%% @doc This function is called by a gen_server when it is about to terminate. When it returns,
%%      the gen_server terminates with Reason. The return value is ignored.

% no problem, that's ok
terminate(normal, State) ->
  #job{uuid = JobUUID} = State#state.job,
  io:format("[cameron_process_runner] terminating :: JobUUID: ~s // normal~n", [JobUUID]),
  terminated;

% handle_info generic fallback (ignore) // any reason, i.e: cameron_process_sup:stop_child
terminate(Reason, State) ->
  #job{uuid = JobUUID} = State#state.job,
  io:format("[cameron_process_runner] terminating :: JobUUID: ~s // ~w~n", [JobUUID, Reason]),
  terminate.

%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @doc Convert process state when code is changed.
code_change(_OldVsn, State, _Extra) ->
  {ok, State}.

%%
%% Internal Functions -----------------------------------------------------------------------------
%%

handle(Index, #task_input{job   = Job,
                          name  = _Name,
                          pname = _Pname} = TaskInput) ->

  #request{process = #process{start_task_url = StartTaskURL},
           key      = RequestKey,
           data     = RequestData,
           from     = RequestFrom} = Job#job.request,
  
  Payload = build_payload(RequestKey, RequestData, RequestFrom),

  case http_helper:http_post(StartTaskURL, Payload) of
    {ok, {{"HTTP/1.1", 200, _}, _, Output}} ->
      TaskOutput = #task_output{task_input = TaskInput, output = Output},
      notify_done(Index, TaskOutput);
    {ok, {{"HTTP/1.1", _, _}, _, Output}} ->
      TaskOutput = #task_output{task_input = TaskInput, output = Output},
      notify_error(Index, TaskOutput);
    {error, {connect_failed, emfile}} ->
      TaskOutput = #task_output{task_input = TaskInput, output = "{connect_failed, emfile}"},
      notify_error(Index, TaskOutput);
    {error, Reason} ->
      io:format("Reason = ~w~n", [Reason]),
      TaskOutput = #task_output{task_input = TaskInput, output = "unknown_error"},
      notify_error(Index, TaskOutput)
  end,
  
  ok.
  
notify(What, {Index, #task_output{task_input = TaskInput} = TaskOutput}) ->
  Job = TaskInput#task_input.job,

  Pname = ?pname(Job#job.uuid),
  ok = gen_server:cast(Pname, {What, Index, TaskOutput}).

notify_done(Index, #task_output{} = TaskOutput) ->
  notify(notify_done, {Index, TaskOutput}).

notify_error(Index, #task_output{} = TaskOutput) ->
  notify(notify_error, {Index, TaskOutput}).
  
build_payload(RequestKey, RequestData, RequestFrom) ->
  Payload = struct:to_json({struct, [{<<"key">>,  list_to_binary(RequestKey)},
                                     {<<"data">>, list_to_binary(RequestData)},
                                     {<<"from">>, list_to_binary(RequestFrom)}]}),
                                        
  unicode:characters_to_list(Payload).
  