-module(aequitas_category_sup).
-behaviour(supervisor).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export(
   [start_link/1,
    start/1
   ]).

%% ------------------------------------------------------------------
%% supervisor Function Exports
%% ------------------------------------------------------------------

-export([init/1]).

%% ------------------------------------------------------------------
%% Macro Definitions
%% ------------------------------------------------------------------

-define(CB_MODULE, ?MODULE).

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

start_link(Category) ->
    supervisor:start_link(?CB_MODULE, [Category]).

start(Category) ->
    aequitas_categories_sup:start_child([Category]).

%% ------------------------------------------------------------------
%% supervisor Function Definitions
%% ------------------------------------------------------------------

init([Category]) ->
    SupFlags =
        #{ strategy => rest_for_one,
           intensity => 10,
           period => 1
         },
    Children =
        [#{ id => category_broker,
            start => {aequitas_category_broker, start_link, [Category]}
          },
         #{ id => category_regulator,
            start => {aequitas_category_regulator, start_link, [Category]}
          }
        ],
    {ok, {SupFlags, Children}}.
