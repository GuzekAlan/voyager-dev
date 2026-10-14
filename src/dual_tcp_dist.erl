-module(dual_tcp_dist).
-moduledoc false.

%% The only -proto_dist carrier: net_kernel tries several carriers in reverse order, so IPv4-first is decided in setup/5.
%% As the IPv4 driver it accepts IPv6 literal hosts, so app@<IPv6> reached over the v4 SSH tunnel passes fam_setup's host check.

-export([select/1, setup/5, close/1, address/0, is_node_name/1]).
-export([setopts/2, getopts/2]).
-export([family/0, parse_address/1, connect/3, send/2, send/3, recv/3]).
-export([do_setup/7, allowed/1]).

-include_lib("kernel/include/net_address.hrl").
-include_lib("kernel/include/dist.hrl").
-include_lib("kernel/include/dist_util.hrl").

%% Without the header atom cache and fragments every frame is <<112, ControlTerm, Payload>>.
-define(REJECT_FLAGS, (?DFLAG_DIST_HDR_ATOM_CACHE bor ?DFLAG_FRAGMENTS)).

%% Replies to our own erpc calls: MONITOR_P_EXIT, PAYLOAD_MONITOR_P_EXIT, SPAWN_REPLY, SPAWN_REPLY_TT.
-define(ALLOWED_OPS, [21, 28, 31, 32]).

select(Node) -> inet_tcp_dist:fam_select(inet, Node) orelse inet_tcp_dist:fam_select(inet6, Node).

setup(Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Driver =
        case inet_tcp_dist:fam_select(inet, Node) of
            true -> ?MODULE;
            false -> inet6_tcp
        end,
    spawn_opt(?MODULE, do_setup, [self(), Driver, Node, Type, MyNode, LongOrShortNames, SetupTime],
              dist_util:net_ticker_spawn_options()).

%% Every frame from the remote node passes allowed/1 before the VM sees it, so it cannot spawn, send to
%% registered names or pids, link or exit our processes: only answers to calls we made get through.
do_setup(Kernel, Driver, Node, Type, MyNode, LongOrShortNames, SetupTime) ->
    Timer = dist_util:start_timer(SetupTime),
    {NetAddress, Options, Version} =
        inet_tcp_dist:fam_setup(Driver:family(), Node, LongOrShortNames, fun Driver:parse_address/1),
    #net_address{address = {Ip, Port}} = NetAddress,
    dist_util:reset_timer(Timer),
    case Driver:connect(Ip, Port, Options) of
        {ok, Socket} ->
            Ctrl = spawn_link(fun() -> connection(Socket) end),
            dist_util:handshake_we_started(
              #hs_data{kernel_pid = Kernel,
                       other_node = Node,
                       this_node = MyNode,
                       socket = Ctrl,
                       timer = Timer,
                       this_flags = 0,
                       other_version = Version,
                       request_type = Type,
                       reject_flags = ?REJECT_FLAGS,
                       f_send = fun(_, Packet) -> gen_tcp:send(Socket, Packet) end,
                       f_recv = fun(_, Length, Timeout) -> gen_tcp:recv(Socket, Length, Timeout) end,
                       f_setopts_pre_nodeup = fun(_) -> inet:setopts(Socket, [{packet, 4}]) end,
                       f_setopts_post_nodeup = fun(_) -> inet:setopts(Socket, [{packet, 4}]) end,
                       f_getll = fun(_) -> {ok, Ctrl} end,
                       f_address = fun(_, _) -> NetAddress end,
                       f_handshake_complete =
                           fun(_, _, DHandle) ->
                                   ok = gen_tcp:controlling_process(Socket, Ctrl),
                                   Ctrl ! {handshake_complete, DHandle},
                                   ok
                           end,
                       mf_tick = fun(_) -> Ctrl ! tick end,
                       mf_getstat = fun(_) -> getstat(Socket) end,
                       mf_setopts = fun(_, _) -> {error, enotsup} end,
                       mf_getopts = fun(_, _) -> {error, enotsup} end});
        _ ->
            ?shutdown(Node)
    end.

-spec allowed(binary()) -> boolean().
allowed(<<>>) -> true;
allowed(<<112, 131, 104, _Arity, 97, Op, _/binary>>) -> lists:member(Op, ?ALLOWED_OPS);
allowed(_) -> false.

connection(Socket) ->
    receive {handshake_complete, DHandle} -> ok end,
    ok = inet:setopts(Socket, [binary, {active, once}]),
    erlang:dist_ctrl_get_data_notification(DHandle),
    loop(DHandle, Socket).

loop(DHandle, Socket) ->
    receive
        {tcp, Socket, Data} ->
            allowed(Data) andalso erlang:dist_ctrl_put_data(DHandle, Data),
            ok = inet:setopts(Socket, [{active, once}]);
        dist_data ->
            send_data(DHandle, Socket);
        tick ->
            ok = gen_tcp:send(Socket, <<>>);
        {tcp_closed, Socket} ->
            exit(connection_closed)
    end,
    loop(DHandle, Socket).

send_data(DHandle, Socket) ->
    case erlang:dist_ctrl_get_data(DHandle) of
        none ->
            erlang:dist_ctrl_get_data_notification(DHandle);
        Data ->
            ok = gen_tcp:send(Socket, Data),
            send_data(DHandle, Socket)
    end.

getstat(Socket) ->
    {ok, Stats} = inet:getstat(Socket, [recv_cnt, send_cnt, send_pend]),
    [R, W, P] = [proplists:get_value(K, Stats) || K <- [recv_cnt, send_cnt, send_pend]],
    {ok, R, W, P}.

address() -> inet_tcp_dist:gen_address(?MODULE).
close(Socket) -> inet_tcp:close(Socket).
is_node_name(Node) -> inet_tcp_dist:is_node_name(Node).
setopts(S, Opts) -> inet_tcp_dist:setopts(S, Opts).
getopts(S, Opts) -> inet_tcp_dist:getopts(S, Opts).

family() -> inet.
parse_address(Host) -> inet:parse_address(Host).
connect(Ip, Port, Opts) -> inet_tcp:connect(Ip, Port, Opts).
send(Socket, Packet) -> inet_tcp:send(Socket, Packet).
send(Socket, Packet, Opts) -> inet_tcp:send(Socket, Packet, Opts).
recv(Socket, Length, Timeout) -> inet_tcp:recv(Socket, Length, Timeout).
