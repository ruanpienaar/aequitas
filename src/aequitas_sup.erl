-module(aequitas_sup).
-behaviour(supervisor).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export([start_link/0]).

%% ------------------------------------------------------------------
%% supervisor Function Exports
%% ------------------------------------------------------------------

-export([init/1]).

%% ------------------------------------------------------------------
%% Macro Definitions
%% ------------------------------------------------------------------

-define(SERVER, ?MODULE).
-define(CB_MODULE, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link() ->
    supervisor:start_link({local, ?SERVER}, ?CB_MODULE, []).

%% ------------------------------------------------------------------
%% supervisor Function Definitions
%% ------------------------------------------------------------------

init([]) ->
    SupFlags =
        #{ strategy => rest_for_one,
           intensity => 10,
           period => 1
         },
    Children =
        [#{ id => directory_sup,
            start => {aequitas_directory_sup, start_link, []},
            type => supervisor
          },
         #{ id => actor_sup,
            start => {aequitas_actor_sup, start_link, []},
            type => supervisor
          }
        ],
    {ok, {SupFlags, Children}}.
