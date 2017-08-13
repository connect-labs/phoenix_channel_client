defmodule PhoenixChannelClient.Socket do
  require Logger

  @heartbeat_interval 30_000
  @reconnect_interval 15_000

  @callback handle_close(reply :: Tuple.t, state :: map) ::
              {:noreply, state :: map} |
              {:stop, reason :: term, state :: map}

  defmacro __using__(_opts) do
    quote do
      require Logger
      unquote(socket())
    end
  end

  defp socket do
    quote unquote: false do
      use GenServer

      #alias PhoenixChannelClient.Push

      def start_link(url) do
        options = [
          serializer: Poison,
          url: url
        ]
        unquote(Logger.debug("Socket start_link #{__MODULE__}"))
        GenServer.start_link(PhoenixChannelClient.Socket, {unquote(__MODULE__), options}, name: __MODULE__)
      end

      def push(pid, topic, event, payload) do
        GenServer.call(pid, {:push, topic, event, payload})
      end

      def channel_link(pid, channel, topic) do
        GenServer.call(pid, {:channel_link, channel, topic})
      end

      def channel_unlink(pid, channel, topic) do
        GenServer.call(pid, {:channel_unlink, channel, topic})
      end

      def handle_close(_reason, state) do
        {:noreply, state}
      end

      defoverridable handle_close: 2
    end
  end

  ## Callbacks

  def init({sender, opts}) do
    adapter = opts[:adapter] || PhoenixChannelClient.Adapters.WebsocketClient

    :crypto.start
    :ssl.start
    reconnect = Keyword.get(opts, :reconnect, true)
    opts = Keyword.put_new(opts, :headers, [])
    heartbeat_interval = opts[:heartbeat_interval] || @heartbeat_interval
    reconnect_interval = opts[:reconnect_interval] || @reconnect_interval
    ws_opts = Keyword.put(opts, :sender, self())

    {:ok, pid} = adapter.open(ws_opts[:url], ws_opts)

    {:ok, %{
      sender: sender,
      opts: opts,
      socket: pid,
      channels: [],
      reconnect: reconnect,
      reconnect_timer: nil,
      heartbeat_interval: heartbeat_interval,
      heartbeat_timer: nil,
      reconnect_interval: reconnect_interval,
      status: :disconnected,
      adapter: adapter,
      queue: :queue.new(),
      ws_opts: ws_opts,
      ref: 0
    }}
  end

  def handle_call({:push, topic, event, payload}, _from, state) do
    ref = state.ref + 1
    push = %{topic: topic, event: event, payload: payload, ref: to_string(ref)}
    send(self(), :flush)
    {:reply, push, %{state | ref: ref, queue: :queue.in(push, state.queue)}}
  end

  def handle_call({:channel_link, channel, topic}, _from, state) do
    channels = state.channels
    channels =
      if Enum.any?(channels, fn({c, t})-> c == channel and t == topic end) do
        channels
      else
        [{channel, topic} | state.channels]
      end
    {:reply, channel, %{state | channels: channels}}
  end

  def handle_call({:channel_unlink, channel, topic}, _from, state) do
    channels = Enum.reject(state.channels, fn({c, t}) -> c == channel and t == topic end)
    {:reply, channel, %{state | channels: channels}}
  end

  def handle_info({:connected, socket}, %{socket: socket, channels: channels} = state) do
    Logger.debug "Connected Socket: #{inspect __MODULE__}"

    # Restart/Start and channels tied to the socket.  Usually these only exist if the
    # socket was disconnected.  If the process crashes, the state is cleared and they
    # will not be restarted.  If the channel server is still running, it may try to reconnect
    # from there. 
    channels
    |> Enum.map(fn {chan_pid, _} -> Process.send(chan_pid, :rejoin, []) end)

    heartbeat_timer = :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | status: :connected, heartbeat_timer: heartbeat_timer}}
  end

  def handle_info(:heartbeat, state) do
    ref = state.ref + 1
    send(state.socket, {:send, %{topic: "phoenix", event: "heartbeat", payload: %{}, ref: ref}})
    heartbeat_timer = :erlang.send_after(state.heartbeat_interval, self(), :heartbeat)
    {:noreply, %{state | ref: ref, heartbeat_timer: heartbeat_timer}}
  end

  # New Messages from the socket come in here
  def handle_info({:receive, %{"topic" => topic, "event" => event, "payload" => payload, "ref" => ref}} = msg, %{channels: channels} = state) do
    Logger.debug "Socket Received: #{inspect msg}"
    Enum.filter(channels, fn({_channel, channel_topic}) ->
      topic == channel_topic
    end)
    |> Enum.each(fn({channel, _}) ->
      send(channel, {:trigger, event, payload, ref})
    end)
    {:noreply, state}
  end

  def handle_info({:closed, reason, socket}, %{socket: socket} = state) do
    Logger.debug "Socket Closed: #{inspect reason}"
    Enum.each(state.channels, fn({pid, _channel})-> send(pid, {:trigger, "phx_error", :closed, nil}) end)
    if state.reconnect == true do
      if state.heartbeat_timer != nil do
        :erlang.cancel_timer(state.heartbeat_timer)
      end
      :erlang.send_after(state[:reconnect_interval], self(), :connect)
    end
    state.sender.handle_close(reason, %{state | status: :disconnected})
  end

  def handle_info(:flush, %{status: :connected} = state) do
    state =
      case :queue.out(state.queue) do
        {:empty, _queue} -> state
        {{:value, push}, queue} ->
          Logger.debug "Socket Push: #{inspect push}"
          send(state.socket, {:send, push})
          :erlang.send_after(100, self(), :flush)
          %{state | queue: queue}
      end
    {:noreply, state}
  end

  def handle_info(:flush, state) do
    :erlang.send_after(100, self(), :flush)
    {:noreply, state}
  end

  def handle_info(:connect, state) do
    {:ok, pid} = state[:adapter].open(state[:ws_opts][:url], state[:ws_opts])
    {:noreply, %{state| socket: pid}}
  end

  def terminate(reason, _state) do
    Logger.debug("Socket terminating: #{inspect reason}")
    :ok
  end
end
