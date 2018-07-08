%%%-------------------------------------------------------------------
%%% @author sarunas
%%% @copyright (C) 2018, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 23. Jun 2018 08.33
%%%-------------------------------------------------------------------
-module(erltorrent_downloader).
-compile([{parse_transform, lager_transform}]).
-author("bartimaeus").

-behaviour(gen_server).

-include("erltorrent.hrl").

%% API
-export([
    start/8
]).

%% gen_server callbacks
-export([
    init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
]).

-record(state, {
    torrent_id                  :: integer(), % Unique torrent ID in Mnesia
    peer_ip                     :: tuple(),
    port                        :: integer(),
    socket                      :: port(),
    piece_id                    :: binary(),
    piece_length                :: integer(), % Full length of piece
    count           = 0         :: integer(),
    parser_pid                  :: pid(),
    server_pid                  :: pid(),
    peer_state      = choke     :: choke | unchoke,
    give_up_limit   = 3         :: integer(), % How much tries to get unchoke before giveup
    peer_id,
    hash,
    last_action                 :: integer() % Gregorian seconds when last packet was received
}).

% @todo išhardkodinti, nes visas failas gali būti mažesnis už šitą skaičių
-define(DEFAULT_REQUEST_LENGTH, 16384).


%%%===================================================================
%%% API
%%%===================================================================


%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start(TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength) ->
    gen_server:start(?MODULE, [TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength], []).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init([TorrentId, PieceId, PeerIp, Port, ServerPid, PeerId, Hash, PieceLength]) ->
    State = #state{
        torrent_id      = TorrentId,
        peer_ip         = PeerIp,
        port            = Port,
        piece_id        = PieceId,
        server_pid      = ServerPid,
        peer_id         = PeerId,
        hash            = Hash,
        piece_length    = PieceLength,
        last_action     = calendar:datetime_to_gregorian_seconds(calendar:local_time())
    },
    self() ! start,
    {ok, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling cast messages
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% @todo move to handle_info
%%
handle_cast(request_piece, State) ->
    #state{
        socket       = Socket,
        piece_id     = PieceId,
        piece_length = PieceLength,
        count        = Count
    } = State,
    {ok, {NextLength, OffsetBin}} = get_request_data(Count, PieceLength),
    % Check if file isn't downloaded yet
    case NextLength > 0 of
        true ->
            ok = erltorrent_message:request_piece(Socket, PieceId, OffsetBin, NextLength),
            ok = erltorrent_helper:get_packet(Socket);
        false ->
            exit(self(), completed)
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling all non call/cast messages
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
%% Start downloading from peer: open socket, make a handshake, start is alive checking timer.
%%
handle_info(start, State = #state{peer_ip = PeerIp, port = Port, peer_id = PeerId, hash = Hash}) ->
    {ok, Socket} = do_connect(PeerIp, Port),
    {ok, ParserPid} = erltorrent_packet:start_link(),
    ok = erltorrent_message:handshake(Socket, PeerId, Hash),
    ok = erltorrent_helper:get_packet(Socket),
    erlang:send_after(15000, self(), is_alive),
    {noreply, State#state{socket = Socket, parser_pid = ParserPid}};

%% @doc
%% Handle incoming packets.
%%
handle_info({tcp, _Port, Packet}, State) ->
    #state{
        torrent_id  = TorrentId,
        port        = Port,
        count       = Count,
        parser_pid  = ParserPid,
        socket      = Socket,
        peer_ip     = PeerIp,
        peer_state  = PeerState
    } = State,
    {ok, Data} = erltorrent_packet:parse(ParserPid, Packet),
    ok = case proplists:get_value(handshake, Data) of
        true ->
%%            lager:info("xxxxxxxxxx Received handshake from ~p:~p for file: ~p", [PeerIp, Port, TorrentId]),
            ok = erltorrent_message:interested(Socket);
        _    ->
            ok
    end,
    % Identify new my peer state
    % @todo implement unchoke waiting giveup
    NewPeerState = lists:foldl(
        fun
            ({unchoke, true}, _Acc) -> unchoke;
            ({choke, true}, _Acc) -> choke;
            (_, Acc) -> Acc
        end,
        PeerState,
        Data
    ),
    % If my peer state changed and new my peer state is unchoke, request for a piece
    ok = case {NewPeerState =:= PeerState, NewPeerState} of
        {false, unchoke} -> request_piece();
        _                -> ok
    end,
    % We need to loop because we can receive more than 1 piece at the same time
    WriteFun = fun
        ({piece, Piece = #piece_data{payload = Payload, piece_index = PieceId, block_offset = BlockOffset}}) ->
            <<PieceBegin:32>> = BlockOffset,
            FileName = filename:join(["temp", TorrentId, integer_to_list(PieceId), integer_to_list(PieceBegin) ++ ".part"]),
            filelib:ensure_dir(FileName),
            file:write_file(FileName, Payload),
            {true, Piece};
       (_Else) ->
           false
    end,
    % Check current my peer state. If it's unchoke - request for piece. If it's choke - try to get unchoke by sending interested.
    NewCount = case NewPeerState of
        unchoke ->
            case lists:filtermap(WriteFun, Data) of
                [_|_]   ->
                    request_piece(),                      % If we have received any piece, go to another one
                    Count + 1;
                _       ->
                    erltorrent_helper:get_packet(Socket), % If we haven't received any piece, take more from socket
                    Count
            end;
        choke ->
            ok = erltorrent_message:interested(Socket),
            ok = erltorrent_helper:get_packet(Socket),
            Count
    end,
    {noreply, State#state{count = NewCount, peer_state = NewPeerState, last_action = calendar:datetime_to_gregorian_seconds(calendar:local_time())}};

%% @doc
%% Check is peer still alive every 15 seconds. If not - kill the process.
%%
handle_info(is_alive, State = #state{last_action = LastAction}) ->
    erlang:send_after(15000, self(), is_alive),
    CurrentTime = calendar:datetime_to_gregorian_seconds(calendar:local_time()),
    case CurrentTime - LastAction >= 15 of
        % @todo pagalvoti, ar reikia atskirai handlinti serveryje timeouted.
        true  -> exit(self(), timeouted);
        false -> ok
    end,
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.


%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%%%===================================================================
%%% Internal functions
%%%===================================================================

%% @doc
%% Connect to peer
%%
do_connect(PeerIp, Port) ->
    {ok, _Socket} = gen_tcp:connect(PeerIp, Port, [{active, false}, binary], 10000).


%% @doc
%% Get increased `length` and `offset`
%%
get_request_data(Count, PieceLength) ->
    OffsetBin = <<(?DEFAULT_REQUEST_LENGTH * Count):32>>,
    <<OffsetInt:32>> = OffsetBin,
    % Last chunk of piece would be shorter than default length so we need to check if next chunk isn't a last
    NextLength = case (OffsetInt + ?DEFAULT_REQUEST_LENGTH) =< PieceLength of
        true  -> ?DEFAULT_REQUEST_LENGTH;
        false -> PieceLength - OffsetInt
    end,
    {ok, {NextLength, OffsetBin}}.


%% @doc
%% Start parsing data (sync. call)
%%
request_piece() ->
    gen_server:cast(self(), request_piece).



%%%===================================================================
%%% EUnit tests
%%%===================================================================


-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

get_request_data_test_() ->
    [
        ?_assertEqual(
            {ok, {?DEFAULT_REQUEST_LENGTH, <<0, 0, 64, 0>>}},
            get_request_data(1, 290006769)
        ),
        ?_assertEqual(
            {ok, {?DEFAULT_REQUEST_LENGTH, <<0, 1, 128, 0>>}},
            get_request_data(6, 290006769)
        ),
        ?_assertEqual(
            {ok, {1696, <<0, 1, 128, 0>>}},
            get_request_data(6, 100000)
        ),
        ?_assertEqual(
            {ok, {-14688, <<0, 1, 192, 0>>}},
            get_request_data(7, 100000)
        )
    ].


-endif.


