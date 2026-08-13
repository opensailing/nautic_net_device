defmodule RacingOrg.Tracker.Pro.WebClients.UDPClientTest do
  @moduledoc """
  P9-job-4: the gated AEAD-UDP telemetry send path.

  Exercises `UDPClient.send_data_set/2` with an injected `SessionHolder` and an
  injected `send_fun` so we can assert the EXACT bytes that would hit the wire,
  without opening a real socket.
  """
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.{Frame, Session, SessionHolder}
  alias RacingOrg.Tracker.Pro.WebClients.UDPClient

  @magic RacingOrg.Tracker.Pro.SecureTransport.magic()
  @version RacingOrg.Tracker.Pro.SecureTransport.protocol_version()
  @type_data RacingOrg.Tracker.Pro.SecureTransport.type_data()
  @aead_id RacingOrg.Tracker.Pro.SecureTransport.aead_chacha20_poly1305()
  @header_size RacingOrg.Tracker.Pro.SecureTransport.header_size()

  # A DataSet protobuf binary is just opaque bytes to the seal; any binary works for
  # the wire-framing assertions (the inner encoding round-trips identically).
  @dataset_plaintext "encoded-DataSet-protobuf-bytes"

  defp capture_fun(test_pid) do
    fn bytes -> send(test_pid, {:sent, bytes}) end
  end

  defp loopback_sessions(epoch \\ 7) do
    session_id = :crypto.strong_rand_bytes(16)
    k_d2s = :crypto.strong_rand_bytes(32)
    k_s2d = :crypto.strong_rand_bytes(32)

    device =
      Session.new(
        role: :initiator,
        session_id: session_id,
        epoch: epoch,
        out_key: k_d2s,
        in_key: k_s2d
      )

    # Server's view: in_key is the device's out_key (so it can OPEN device frames).
    server =
      Session.new(
        role: :responder,
        session_id: session_id,
        epoch: epoch,
        out_key: k_s2d,
        in_key: k_d2s
      )

    {device, server}
  end

  defp start_holder(session \\ nil) do
    {:ok, holder} = start_supervised({SessionHolder, name: nil})
    if session, do: :ok = SessionHolder.put(holder, session)
    holder
  end

  describe "with a live session" do
    test "sends a valid SRT1 TYPE_DATA frame whose session_id matches the session" do
      {device, server} = loopback_sessions()
      holder = start_holder(device)

      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: holder,
          send_fun: capture_fun(self())
        )

      assert_receive {:sent, frame}

      # Cleartext header is a well-formed SRT1 data frame routed to this session.
      <<@magic, @version, @type_data, @aead_id, session_id::binary-size(16), _epoch::32, _counter::64>> =
        binary_part(frame, 0, @header_size)

      assert session_id == device.session_id
      assert {:ok, %{session_id: ^session_id}} = Frame.parse_header(binary_part(frame, 0, @header_size))

      # And it round-trips: the server opens it back to the DataSet plaintext.
      assert {:ok, @dataset_plaintext, _} = Frame.open(server, frame)
    end

    test "drops the datagram while the operational gate fences output" do
      {device, _server} = loopback_sessions()
      holder = start_holder(device)

      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: holder,
          send_fun: capture_fun(self()),
          output_fence: fn -> false end
        )

      refute_receive {:sent, _frame}, 50
    end

    test "a raising output fence fails closed without crashing the pipeline" do
      {device, _server} = loopback_sessions()
      holder = start_holder(device)

      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: holder,
          send_fun: capture_fun(self()),
          output_fence: fn -> raise "fence unavailable" end
        )

      refute_receive {:sent, _frame}, 50
    end

    test "consecutive sends use strictly increasing counters (no reuse)" do
      {device, _server} = loopback_sessions()
      holder = start_holder(device)

      counters =
        for _ <- 1..5 do
          :ok =
            UDPClient.send_data_set(@dataset_plaintext,
              session_holder: holder,
              send_fun: capture_fun(self())
            )

          assert_receive {:sent, frame}
          {:ok, %{counter: counter}} = Frame.parse_header(binary_part(frame, 0, @header_size))
          counter
        end

      assert counters == [0, 1, 2, 3, 4]
      assert length(Enum.uniq(counters)) == 5
    end

    test "the frame plaintext IS exactly the DataSet bytes (server-ingest contract)" do
      {device, server} = loopback_sessions()
      holder = start_holder(device)

      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: holder,
          send_fun: capture_fun(self())
        )

      assert_receive {:sent, frame}
      # This is what SecureUDPIngest hands to DataSetIngest.ingest_binary/2.
      assert {:ok, @dataset_plaintext, _} = Frame.open(server, frame)
      refute frame == @dataset_plaintext
    end
  end

  describe "with no live session" do
    test "drops the datagram (sends nothing) -- never plaintext" do
      holder = start_holder()

      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: holder,
          send_fun: capture_fun(self())
        )

      refute_receive {:sent, _bytes}
    end

    test "a not-running holder is treated as no-session and dropped (no crash)" do
      # No process registered under this name: take_send_counter exits; the send path
      # must catch it and drop (never leak plaintext).
      :ok =
        UDPClient.send_data_set(@dataset_plaintext,
          session_holder: :no_such_holder_process,
          send_fun: capture_fun(self())
        )

      refute_receive {:sent, _bytes}
    end
  end

  describe "robustness" do
    test "queued work carrying a stale session generation is dropped before sealing" do
      {first_device, _first_server} = loopback_sessions()
      {second_device, _second_server} = loopback_sessions()
      holder = start_holder(first_device)
      {:ok, first} = SessionHolder.get_current_session(holder)
      assert {:ok, _second} = SessionHolder.publish(holder, second_device, first.generation)

      assert :ok =
               UDPClient.send_data_set(@dataset_plaintext,
                 session_holder: holder,
                 session_generation: first.generation,
                 send_fun: capture_fun(self())
               )

      refute_receive {:sent, _frame}
    end

    test "session replacement cannot overtake a delayed send using the old generation" do
      parent = self()
      {first_device, first_server} = loopback_sessions()
      {second_device, _second_server} = loopback_sessions()
      holder = start_holder(first_device)
      {:ok, first} = SessionHolder.get_current_session(holder)

      send_task =
        Task.async(fn ->
          UDPClient.send_data_set(@dataset_plaintext,
            session_holder: holder,
            send_fun: fn frame ->
              send(parent, {:udp_send_started, self(), frame})

              receive do
                :finish_udp_send -> :ok
              end
            end
          )
        end)

      assert_receive {:udp_send_started, send_process, frame}
      assert send_process == send_task.pid
      assert {:ok, @dataset_plaintext, _server_session} = Frame.open(first_server, frame)
      assert SessionHolder.live?(holder)
      assert SessionHolder.generation(holder) == first.generation
      assert {:ok, current} = SessionHolder.get_current_session(holder)
      assert current.session_id == first.session_id
      assert current.send_counter == 1

      replace_task =
        Task.async(fn -> SessionHolder.publish(holder, second_device, first.generation) end)

      assert Task.yield(replace_task, 20) == nil
      send(send_process, :finish_udp_send)

      assert :ok = Task.await(send_task)
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.session_id == second_device.session_id
      assert replacement.generation > first.generation
    end

    test "a seal error drops the one datagram and does not crash the sender" do
      # A short out_key forces Primitives.aead_seal -> {:error, :bad_key_length},
      # exercising the seal-error branch.
      session_id = :crypto.strong_rand_bytes(16)

      bad_session =
        Session.new(
          role: :initiator,
          session_id: session_id,
          epoch: 1,
          out_key: <<0::8>>,
          in_key: :crypto.strong_rand_bytes(32)
        )

      holder = start_holder(bad_session)

      assert :ok =
               UDPClient.send_data_set(@dataset_plaintext,
                 session_holder: holder,
                 send_fun: capture_fun(self())
               )

      # Dropped: neither a frame nor plaintext is emitted, and we did not crash.
      refute_receive {:sent, _bytes}
    end
  end
end
