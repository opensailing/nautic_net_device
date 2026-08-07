defmodule RacingOrg.Tracker.Pro.WebClients.UDPClient.Server do
  @moduledoc """
  Sends DataSet protobuf packets to the RacingOrg app over a
  device-initiated UDP socket, and receives RacingOrg command replies on that
  same socket, forwarding them to `RacingOrg.Tracker.Pro.Commands`.
  """

  use GenServer

  require Logger

  alias RacingOrg.Tracker.Pro.SecureTransport.BootProvisioner
  alias RacingOrg.Tracker.Pro.SecureTransport.Frame
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  def send(binary) do
    GenServer.cast(__MODULE__, {:send, binary})
  end

  @impl true
  def init(opts) do
    hostname = opts[:hostname] || raise "the :hostname option is required"
    port = opts[:port] || raise "the :port option is required"
    commands = opts[:commands] || RacingOrg.Tracker.Pro.Commands
    session_holder = opts[:session_holder] || SessionHolder
    credential_epoch_fun = opts[:credential_epoch_fun] || fn -> BootProvisioner.credential_epoch() end

    # Port 0 binds to a random available port specified by the OS. The socket is
    # left in active mode so RacingOrg can reply with commands on the same source
    # address/port. The `:inet` option forces IPv4, because Fly does not support
    # UDP over IPv6 yet.
    {:ok, socket} = :gen_udp.open(0, [:inet, :binary, active: true])

    {:ok,
     %{
       hostname: hostname,
       port: port,
       socket: socket,
       commands: commands,
       session_holder: session_holder,
       credential_epoch_fun: credential_epoch_fun
     }}
  end

  @impl true
  def handle_cast({:send, binary}, state) do
    case send_if_session_live(binary, state) do
      :ok -> :ok
      :drop -> :ok
      {:error, reason} -> Logger.warning("Error sending UDP packet: #{inspect(reason)}")
    end

    {:noreply, state}
  end

  # Legacy RacingOrg reply on the device-initiated socket. Full authenticated
  # control_v1 framing is intentionally out of scope, so fail closed unless a
  # current secure session exists and keep the final forwarding boundary fenced
  # against concurrent replacement/clear.
  @impl true
  def handle_info(
        {:udp, _socket, _ip, _port, packet},
        %{
          commands: commands,
          session_holder: holder,
          credential_epoch_fun: credential_epoch_fun
        } = state
      ) do
    _ = forward_if_session_live(holder, credential_epoch_fun, commands, packet)
    {:noreply, state}
  end

  def handle_info({:udp_passive, _socket}, state), do: {:noreply, state}

  defp send_if_session_live(
         binary,
         %{socket: socket, hostname: hostname, port: port, session_holder: holder}
       ) do
    with {:ok, frame} <- parse_frame_route(binary),
         generation when is_integer(generation) <- SessionHolder.generation(holder) do
      case SessionHolder.with_session(holder, generation, fn session ->
             if frame_matches_session?(frame, session) do
               :gen_udp.send(socket, String.to_charlist(hostname), port, binary)
             else
               :drop
             end
           end) do
        {:ok, :ok} -> :ok
        {:ok, :drop} -> :drop
        {:ok, {:error, reason}} -> {:error, reason}
        {:error, _stale_or_missing_session} -> :drop
      end
    else
      _invalid_or_unavailable -> :drop
    end
  rescue
    _exception -> :drop
  catch
    :exit, _reason -> :drop
  end

  defp parse_frame_route(binary) when is_binary(binary) do
    header_size = RacingOrg.Tracker.Pro.SecureTransport.header_size()

    if byte_size(binary) >= header_size do
      binary
      |> binary_part(0, header_size)
      |> Frame.parse_header()
    else
      {:error, :bad_header}
    end
  end

  defp frame_matches_session?(frame, session) do
    frame.epoch == session.epoch and
      Primitives.secure_compare(frame.session_id, session.session_id)
  end

  defp forward_if_session_live(holder, credential_epoch_fun, commands, packet) do
    with {:ok, credential_epoch} <- current_credential_epoch(credential_epoch_fun),
         {:ok, session} <- SessionHolder.get_current_session(holder),
         true <- session.credential_epoch == credential_epoch,
         generation when is_integer(generation) <- session.generation,
         {:ok, :ok} <-
           SessionHolder.with_session(holder, generation, fn current ->
             if current.session_id == session.session_id and
                  current.credential_epoch == credential_epoch do
               GenServer.cast(commands, {:packet, packet})
             else
               {:error, :stale_session}
             end
           end) do
      :ok
    else
      _no_current_session -> :ok
    end
  rescue
    _ -> :ok
  catch
    :exit, _ -> :ok
  end

  defp current_credential_epoch(fun) when is_function(fun, 0) do
    case fun.() do
      {:ok, epoch} when is_integer(epoch) and epoch >= 0 and epoch <= 0xFFFF_FFFF ->
        {:ok, epoch}

      _unavailable_or_invalid ->
        {:error, :credential_epoch_unavailable}
    end
  end
end
