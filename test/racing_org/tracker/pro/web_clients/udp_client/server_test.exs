defmodule RacingOrg.Tracker.Pro.WebClients.UDPClient.ServerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Pro.SecureTransport.Frame
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply
  alias RacingOrg.Tracker.Pro.WebClients.UDPClient.Server

  test "forwards received UDP packets only while a secure session is live" do
    commands = start_supervised!({Commands, device_id: "dev-1"})
    Commands.subscribe(commands, self())
    holder = start_supervised!({SessionHolder, name: nil})
    assert :ok = SessionHolder.put(holder, session())

    server =
      start_supervised!(
        {Server,
         hostname: "localhost",
         port: 65_000,
         commands: commands,
         session_holder: holder,
         credential_epoch_fun: fn -> {:ok, 0} end,
         name: nil}
      )

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, command_packet()})

    assert_receive {:racing_org_command, %DeviceCommand{command_id: "udp-1"}}, 500
  end

  test "drops legacy UDP command packets when the live session credential epoch is stale" do
    commands = start_supervised!({Commands, device_id: "dev-1"})
    Commands.subscribe(commands, self())
    holder = start_supervised!({SessionHolder, name: nil})
    assert :ok = SessionHolder.put(holder, session())

    server =
      start_supervised!(
        {Server,
         hostname: "localhost",
         port: 65_003,
         commands: commands,
         session_holder: holder,
         credential_epoch_fun: fn -> {:ok, 1} end,
         name: nil}
      )

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, command_packet()})

    refute_receive {:racing_org_command, %DeviceCommand{}}, 50
    assert Process.alive?(server)
  end

  test "drops legacy UDP command packets when no secure session is live" do
    commands = start_supervised!({Commands, device_id: "dev-1"})
    Commands.subscribe(commands, self())
    holder = start_supervised!({SessionHolder, name: nil})

    server =
      start_supervised!(
        {Server, hostname: "localhost", port: 65_002, commands: commands, session_holder: holder, name: nil}
      )

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, command_packet()})

    refute_receive {:racing_org_command, %DeviceCommand{}}, 50
    assert Process.alive?(server)
  end

  test "sends an outbound epoch-zero frame while its session remains current" do
    {:ok, receiver} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(receiver) end)
    {:ok, {_address, port}} = :inet.sockname(receiver)

    holder = start_supervised!({SessionHolder, name: nil})
    assert {:ok, published} = SessionHolder.publish(holder, session())
    assert {:ok, grant} = SessionHolder.take_send_counter(holder, published.generation)

    assert {:ok, frame} =
             Frame.seal_with(
               grant.session_id,
               grant.epoch,
               grant.counter,
               grant.out_key,
               "current-session-telemetry"
             )

    server =
      start_supervised!({Server, name: nil, hostname: "127.0.0.1", port: port, session_holder: holder})

    GenServer.cast(server, {:send, frame})

    assert {:ok, {_address, _port, ^frame}} = :gen_udp.recv(receiver, 0, 100)
  end

  test "drops an outbound frame queued before its session is replaced" do
    {:ok, receiver} = :gen_udp.open(0, [:binary, active: false])
    on_exit(fn -> :gen_udp.close(receiver) end)
    {:ok, {_address, port}} = :inet.sockname(receiver)

    holder = start_supervised!({SessionHolder, name: nil})
    old_session = session(:crypto.strong_rand_bytes(16), 4)
    assert {:ok, published} = SessionHolder.publish(holder, old_session)
    assert {:ok, grant} = SessionHolder.take_send_counter(holder, published.generation)

    assert {:ok, frame} =
             Frame.seal_with(
               grant.session_id,
               grant.epoch,
               grant.counter,
               grant.out_key,
               "old-session-telemetry"
             )

    server =
      start_supervised!({Server, name: nil, hostname: "127.0.0.1", port: port, session_holder: holder})

    :ok = :sys.suspend(server)
    GenServer.cast(server, {:send, frame})

    replacement = session(:crypto.strong_rand_bytes(16), 4)
    assert {:ok, _replacement} = SessionHolder.publish(holder, replacement)
    :ok = :sys.resume(server)

    assert {:error, :timeout} = :gen_udp.recv(receiver, 0, 100)
  end

  test "a malformed received packet does not crash the server" do
    commands = start_supervised!({Commands, device_id: "dev-1"})

    server =
      start_supervised!({Server, hostname: "localhost", port: 65_001, commands: commands, name: nil})

    send(server, {:udp, :fake_socket, {127, 0, 0, 1}, 4001, <<0xFF, 0xFF, 0xFF, 0xFF>>})

    # The server is still alive and responsive.
    assert Process.alive?(server)
    assert Commands.current_assignment(commands) == nil
  end

  defp session, do: session(<<0::128>>, 0)

  defp session(session_id, epoch) do
    Session.new(
      role: :initiator,
      session_id: session_id,
      epoch: epoch,
      out_key: :binary.copy(<<0xAA>>, 32),
      in_key: :binary.copy(<<0xBB>>, 32)
    )
  end

  defp command_packet do
    struct(ServerReply,
      protocol_version: 1,
      device_id: "dev-1",
      command:
        struct(DeviceCommand,
          command_id: "udp-1",
          assignment_id: "asg-1",
          assignment_version: 1,
          payload: {:race_assignment, %RaceAssignment{}}
        )
    )
    |> ServerReply.encode()
  end
end
