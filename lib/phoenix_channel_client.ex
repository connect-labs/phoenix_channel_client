defmodule PhoenixChannelClient do

  @callback handle_in(event :: String.t, payload :: map, state :: map) ::
              {:noreply, state :: map}

  @callback handle_reply(reply :: Tuple.t, state :: map) ::
              {:noreply, state :: map}

  @callback handle_close(reply :: Tuple.t, state :: map) ::
              {:noreply, state :: map} |
              {:stop, reason :: term, state :: map}

  defmacro __using__(_opts) do
    quote do
      alias PhoenixChannelClient.Server

      @behaviour unquote(__MODULE__)

      # def start_link(opts) do
      #   Server.start_link(__MODULE__, opts)
      # end

      def join do
        Server.join(__MODULE__, %{})
      end

      def join(channel_name) when is_binary(channel_name) or is_atom(channel_name) do
        Server.join(channel_name, %{})
      end

      def join(params) do
        Server.join(__MODULE__, params)
      end

      def join(channel_name, params) when is_binary(channel_name) or is_atom(channel_name) do
        Server.join(channel_name, params)
      end

      def leave do
        Server.leave(__MODULE__)
      end
      def leave(channel_name) when is_binary(channel_name) or is_atom(channel_name) do
        Server.leave(channel_name)
      end

      def cancel_push(push_ref) do
        Server.cancel_push(__MODULE__, push_ref)
      end

      def cancel_push(channel_name, push_ref) when is_binary(channel_name) or is_atom(channel_name) do
        Server.cancel_push(channel_name, push_ref)
      end

      def push(channel_name, event, payload, reply_pid) when is_binary(channel_name) or is_atom(channel_name) do
        Server.push(channel_name, event, payload, reply_pid, [])
      end

      def push(channel_name, event, payload, reply_pid, opts) when is_binary(channel_name) or is_atom(channel_name) do
        Server.push(channel_name, event, payload, reply_pid, opts)
      end

      def push(event, payload, reply_pid) do
        Server.push(__MODULE__, event, payload, reply_pid, [])
      end

      def push(event, payload, reply_pid, opts) do
        Server.push(__MODULE__, event, payload, reply_pid, opts)
      end

      def handle_in(event, payload, state) do
        IO.inspect "Handle in: #{event} #{inspect payload}"
        {:noreply, state}
      end

      def handle_reply(payload, state) do
        {:noreply, state}
      end

      def handle_close(payload, %{state: :errored} = state) do
        IO.inspect "Handle Close"
        {:noreply, state}
      end

      defoverridable handle_in: 3, handle_reply: 2, handle_close: 2
    end
  end

  def channel(sender, opts) do
    PhoenixChannelClient.Server.start_link(sender, opts)
  end

  def terminate(message, _state) do
    IO.puts "Terminate: #{inspect message}"
    :shutdown
  end
end
