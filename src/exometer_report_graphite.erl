%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------

-module(exometer_report_graphite).
-behaviour(exometer_report).

%% gen_server callbacks
-export(
   [
    exometer_init/1,
    exometer_info/2,
    exometer_cast/2,
    exometer_call/3,
    exometer_report/5,
    exometer_subscribe/5,
    exometer_unsubscribe/4,
    exometer_newentry/2,
    exometer_setopts/4,
    exometer_terminate/2
   ]).

-include_lib("exometer_core/include/exometer.hrl").
-include_lib("kernel/include/inet.hrl").

-define(DEFAULT_HOST, "carbon.hostedgraphite.com").
-define(DEFAULT_PORT, 2003).
-define(DEFAULT_CONNECT_TIMEOUT, 5000).

-record(st, {
          address,
          port = ?DEFAULT_PORT,
          connect_timeout = ?DEFAULT_CONNECT_TIMEOUT,
          name,
          namespace = [],
          prefix = [],
          api_key = "",
          socket = undefined}).

%% calendar:datetime_to_gregorian_seconds({{1970,1,1},{0,0,0}}).
-define(UNIX_EPOCH, 62167219200).

-include("log.hrl").

%% Probe callbacks

exometer_init(Opts) ->
  ?info("Exometer Graphite Reporter; Opts: ~p~n", [Opts]),
  API_key = get_opt(api_key, Opts),
  Prefix = get_opt(prefix, Opts, []),
  {ok, Host} = inet:gethostbyname(get_opt(host, Opts, ?DEFAULT_HOST)),
  [IP | _] = Host#hostent.h_addr_list,
  AddrType = Host#hostent.h_addrtype,
  Port = get_opt(port, Opts, ?DEFAULT_PORT),

  case gen_udp:open(0, [AddrType]) of
    {ok, Sock} ->
      {ok, #st{socket = Sock, address = IP, port = Port, prefix = Prefix, api_key = API_key}};
    {error, _} = Error ->
      Error
  end.

%% xaptum  graphite meter data points hack
exometer_report(Probe, mean, _Extra, Value, St)->
  exometer_report(Probe, mean_rate, _Extra, Value, St);
exometer_report(Probe, one, _Extra, Value, St)->
  exometer_report(Probe, one_minute_rate, _Extra, Value, St);
exometer_report(Probe, five, _Extra, Value, St)->
  exometer_report(Probe, five_minute_rate, _Extra, Value, St);
exometer_report(Probe, fifteen, _Extra, Value, St)->
  exometer_report(Probe, fifteen_minute_rate, _Extra, Value, St);
exometer_report(Probe, DataPoint, _Extra, Value, #st{
  address = IP, port = Port, socket = Socket, api_key = APIKey, prefix = Prefix} = St) ->
  Line = [key(APIKey, Prefix, Probe, DataPoint), " ",
    value(Value), " ", timestamp(), $\n],
  case gen_udp:send(Socket, IP, Port, Line) of
    ok ->
      ?debug("Success sending ~s", [Line]),
      {ok, St};
    {error, Reason} ->
      ?info("Unable to write metric ~s. ~p~n", [Line, Reason]),
      {ok, St}
  end.

exometer_subscribe(_Metric, _DataPoint, _Extra, _Interval, St) ->
    {ok, St }.

exometer_unsubscribe(_Metric, _DataPoint, _Extra, St) ->
    {ok, St }.

exometer_call(Unknown, From, St) ->
    ?info("Unknown call ~p from ~p", [Unknown, From]),
    {ok, St}.

exometer_cast(Unknown, St) ->
    ?info("Unknown cast: ~p", [Unknown]),
    {ok, St}.

exometer_info(Unknown, St) ->
    ?info("Unknown info: ~p", [Unknown]),
    {ok, St}.

exometer_newentry(_Entry, St) ->
    {ok, St}.

exometer_setopts(_Metric, _Options, _Status, St) ->
    {ok, St}.

exometer_terminate(_, _) ->
    ignore.

%% Format a graphite key from API key, prefix, prob and datapoint
key([], [], Prob, DataPoint) ->
    name(Prob, DataPoint);
key([], Prefix, Prob, DataPoint) ->
    [Prefix, $., name(Prob, DataPoint)];
key(APIKey, [], Prob, DataPoint) ->
    [APIKey, $., name(Prob, DataPoint)];
key(APIKey, Prefix, Prob, DataPoint) ->
    [APIKey, $., Prefix, $., name(Prob, DataPoint)].

%% Add probe and datapoint within probe

name(Probe, value)->
  string:join([metric_elem_to_list(I) || I <- Probe], ".");
name(Probe, DataPoint) ->
  [[[metric_elem_to_list(I), $.] || I <- Probe ], datapoint(DataPoint)].

metric_elem_to_list(V) when is_atom(V) -> atom_to_list(V);
metric_elem_to_list(V) when is_binary(V) -> binary_to_list(V);
metric_elem_to_list(V) when is_integer(V) -> integer_to_list(V);
metric_elem_to_list(V) when is_list(V) -> V.

datapoint(V) when is_integer(V) -> integer_to_list(V);
datapoint(V) when is_atom(V) -> atom_to_list(V).

%% Add value, int or float, converted to list
value(V) when is_integer(V) -> integer_to_list(V);
value(V) when is_float(V)   -> float_to_list(V);
value(_) -> 0.

timestamp() ->
    integer_to_list(unix_time()).

unix_time() ->
    datetime_to_unix_time(erlang:universaltime()).

datetime_to_unix_time({{_,_,_},{_,_,_}} = DateTime) ->
    calendar:datetime_to_gregorian_seconds(DateTime) - ?UNIX_EPOCH.

get_opt(K, Opts) ->
    case lists:keyfind(K, 1, Opts) of
        {_, V} -> V;
        false  -> error({required, K})
    end.


get_opt(K, Opts, Default) ->
    exometer_util:get_opt(K, Opts, Default).
