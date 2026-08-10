defmodule RacingOrg.Tracker.Pro.SecureTransport.SessionHolderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport

  alias RacingOrg.Tracker.Pro.SecureTransport.{ReplayWindow, Session, SessionHolder}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Control

  setup do
    {:ok, pid} = start_supervised({SessionHolder, name: nil})
    %{holder: pid}
  end

  defp session(opts \\ []) do
    Session.new(
      Keyword.merge(
        [
          role: :initiator,
          session_id: <<0::128>>,
          epoch: 0,
          out_key: :binary.copy(<<0xAA>>, 32),
          in_key: :binary.copy(<<0xBB>>, 32),
          prk: :binary.copy(<<0xCC>>, 32),
          identity_fingerprint: :binary.copy(<<0xDD>>, 32),
          transcript_hash: :binary.copy(<<0xEE>>, 32)
        ],
        opts
      )
    )
  end

  test "starts idle (no session)", %{holder: h} do
    assert SessionHolder.get_current_session(h) == {:error, :no_session}
    refute SessionHolder.live?(h)
    assert SessionHolder.take_send_counter(h) == {:error, :no_session}
  end

  test "stores and returns the live session", %{holder: h} do
    s = session()
    assert :ok = SessionHolder.put(h, s)
    assert SessionHolder.live?(h)
    assert {:ok, stored} = SessionHolder.get_current_session(h)
    assert stored.session_id == s.session_id
    assert stored.generation == 1
  end

  test "publish assigns a monotonically increasing generation to each replacement", %{holder: h} do
    assert SessionHolder.generation(h) == 0

    assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))
    assert first.generation == 1
    assert SessionHolder.generation(h) == 1

    assert {:ok, second} =
             SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)

    assert second.generation == 2
    assert SessionHolder.generation(h) == 2
    assert {:ok, ^second} = SessionHolder.get_current_session(h)
  end

  test "republishing the same cryptographic session cannot reset its send counter", %{holder: h} do
    assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<1::128>>))
    assert {:ok, %{counter: 0}} = SessionHolder.take_send_counter(h, published.generation)

    assert {:error, :session_reused} =
             SessionHolder.publish(h, published, published.generation)

    assert SessionHolder.generation(h) == published.generation
    assert {:ok, %{counter: 1}} = SessionHolder.take_send_counter(h, published.generation)
  end

  test "advancing a credential epoch atomically evicts a lower-epoch session and returns the new fence", %{holder: h} do
    assert {:ok, published} = SessionHolder.publish(h, session(epoch: 3))

    assert {:ok, next_generation, :evicted} =
             SessionHolder.fence_for_credential_epoch(h, 4)

    assert next_generation == published.generation + 1
    assert SessionHolder.generation(h) == next_generation
    assert {:error, :no_session} = SessionHolder.get_current_session(h)
    assert {:error, :stale_session} = SessionHolder.take_send_counter(h, published.generation)
  end

  test "advancing an epoch with no live session invalidates a pending publication fence", %{holder: h} do
    assert {:ok, pending_generation, :current} =
             SessionHolder.fence_for_credential_epoch(h, 3)

    assert {:ok, advanced_generation, :evicted} =
             SessionHolder.fence_for_credential_epoch(h, 4)

    assert advanced_generation == pending_generation + 1

    assert {:error, :stale_session} =
             SessionHolder.publish(h, session(epoch: 3), pending_generation)

    assert {:ok, published} =
             SessionHolder.publish(h, session(epoch: 4), advanced_generation)

    assert published.credential_epoch == 4
  end

  test "a publication cannot install a session below the holder credential epoch", %{holder: h} do
    assert {:ok, generation, :current} = SessionHolder.fence_for_credential_epoch(h, 4)

    assert {:error, :epoch_downgrade} =
             SessionHolder.publish(h, session(epoch: 3), generation)

    assert SessionHolder.generation(h) == generation
    assert {:error, :no_session} = SessionHolder.get_current_session(h)
  end

  test "credential epoch fencing reuses an equal epoch and rejects a downgrade", %{holder: h} do
    assert {:ok, published} = SessionHolder.publish(h, session(epoch: 4))

    generation = published.generation

    assert {:ok, ^generation, :current} =
             SessionHolder.fence_for_credential_epoch(h, 4)

    assert {:error, :epoch_downgrade} = SessionHolder.fence_for_credential_epoch(h, 3)
    assert {:ok, ^published} = SessionHolder.get_current_session(h)
  end

  test "publish rejects a stale replacement fence without changing the current session", %{holder: h} do
    assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))
    assert {:ok, second} = SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)

    assert {:error, :stale_session} =
             SessionHolder.publish(h, session(session_id: <<3::128>>), first.generation)

    assert SessionHolder.generation(h) == second.generation
    assert {:ok, ^second} = SessionHolder.get_current_session(h)
  end

  test "take_send_counter hands out monotonic, never-reused counters", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    counters =
      for _ <- 1..5 do
        {:ok, grant} = SessionHolder.take_send_counter(h)
        grant.counter
      end

    assert counters == [0, 1, 2, 3, 4]
  end

  test "grant carries the sealing key, epoch, session_id, role, and generation", %{holder: h} do
    s = session(epoch: 7, session_id: <<1::128>>)
    assert {:ok, published} = SessionHolder.publish(h, s)

    {:ok, grant} = SessionHolder.take_send_counter(h, published.generation)

    assert grant.session_id == s.session_id
    assert grant.out_key == s.out_key
    assert grant.epoch == 7
    assert grant.credential_epoch == 7
    assert grant.generation == published.generation
    assert grant.role == :initiator
    assert grant.counter == 0
  end

  test "a stale generation cannot reserve a counter from a replacement session", %{holder: h} do
    assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))
    assert {:ok, second} = SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)

    assert {:error, :stale_session} = SessionHolder.take_send_counter(h, first.generation)
    assert {:ok, grant} = SessionHolder.take_send_counter(h, second.generation)
    assert grant.session_id == second.session_id
    assert grant.counter == 0
  end

  test "get_current_session does NOT advance the counter (only take does)", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    {:ok, s1} = SessionHolder.get_current_session(h)
    {:ok, s2} = SessionHolder.get_current_session(h)
    assert s1.send_counter == s2.send_counter

    {:ok, g} = SessionHolder.take_send_counter(h)
    assert g.counter == 0
    {:ok, after_take} = SessionHolder.get_current_session(h)
    assert after_take.send_counter == 1
  end

  test "take_send_counters/2 reserves a consecutive block", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    {:ok, grants} = SessionHolder.take_send_counters(h, 3)
    assert Enum.map(grants, & &1.counter) == [0, 1, 2]

    {:ok, next} = SessionHolder.take_send_counter(h)
    assert next.counter == 3
  end

  test "concurrent takes never collide (counter uniqueness under contention)", %{holder: h} do
    :ok = SessionHolder.put(h, session())

    n = 200

    counters =
      1..n
      |> Task.async_stream(
        fn _ ->
          {:ok, grant} = SessionHolder.take_send_counter(h)
          grant.counter
        end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, c} -> c end)

    assert length(counters) == n
    assert Enum.sort(counters) == Enum.to_list(0..(n - 1))
    assert length(Enum.uniq(counters)) == n
  end

  test "concurrent fenced takes remain unique within one generation", %{holder: h} do
    assert {:ok, published} = SessionHolder.publish(h, session())
    n = 200

    counters =
      1..n
      |> Task.async_stream(
        fn _ ->
          {:ok, grant} = SessionHolder.take_send_counter(h, published.generation)
          {grant.generation, grant.counter}
        end,
        max_concurrency: 50,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.uniq(Enum.map(counters, &elem(&1, 0))) == [published.generation]
    assert counters |> Enum.map(&elem(&1, 1)) |> Enum.sort() == Enum.to_list(0..(n - 1))
  end

  test "with_session rejects stale delayed work without invoking its callback", %{holder: h} do
    parent = self()
    assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))
    assert {:ok, second} = SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)

    assert {:error, :stale_session} =
             SessionHolder.with_session(h, first.generation, fn _session ->
               send(parent, :stale_callback_ran)
             end)

    refute_receive :stale_callback_ran

    assert {:ok, :current} =
             SessionHolder.with_session(h, second.generation, fn current ->
               assert current.session_id == second.session_id
               :current
             end)
  end

  test "send work is serialized with replacement and cannot outlive its generation", %{holder: h} do
    parent = self()
    assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))

    send_task =
      Task.async(fn ->
        SessionHolder.with_send_counter(h, first.generation, fn grant ->
          send(parent, {:send_started, self(), grant})

          receive do
            :finish_send -> {:sent, grant.generation}
          end
        end)
      end)

    assert_receive {:send_started, holder_pid, %{generation: generation}}
    assert holder_pid == h
    assert generation == first.generation

    replace_task =
      Task.async(fn ->
        SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)
      end)

    assert Task.yield(replace_task, 20) == nil
    send(h, :finish_send)

    assert {:ok, {:sent, generation}} = Task.await(send_task)
    assert {:ok, replacement} = Task.await(replace_task)
    assert replacement.generation > generation
    assert {:error, :stale_session} = SessionHolder.take_send_counter(h, generation)
  end

  test "put resets the counter base to the new session's send_counter", %{holder: h} do
    :ok = SessionHolder.put(h, session())
    {:ok, _} = SessionHolder.take_send_counter(h)
    {:ok, _} = SessionHolder.take_send_counter(h)

    # New handshake -> fresh session (counter 0).
    :ok = SessionHolder.put(h, session(session_id: <<9::128>>))
    {:ok, grant} = SessionHolder.take_send_counter(h)
    assert grant.counter == 0
  end

  test "clear drops the session and advances the generation fence", %{holder: h} do
    assert {:ok, published} = SessionHolder.publish(h, session())
    assert SessionHolder.live?(h)

    assert :ok = SessionHolder.clear(h, published.generation)
    refute SessionHolder.live?(h)
    assert SessionHolder.generation(h) == published.generation + 1
    assert SessionHolder.get_current_session(h) == {:error, :no_session}
    assert SessionHolder.take_send_counter(h) == {:error, :no_session}

    assert {:error, :stale_session} = SessionHolder.clear(h, published.generation)

    # Unconditional clear remains idempotent in effect but advances the fence so
    # delayed work carrying an older generation can never become current again.
    next_generation = SessionHolder.generation(h)
    assert :ok = SessionHolder.clear(h)
    assert SessionHolder.generation(h) == next_generation + 1
  end

  describe "control_v1 state" do
    test "requires a live session under the current generation fence", %{holder: h} do
      payload = control_payload(:readiness)

      assert {:error, :no_session} =
               SessionHolder.with_control_send(h, 0, :readiness, payload, fn _frame ->
                 flunk("idle control callback ran")
               end)

      assert {:error, :no_session} = SessionHolder.open_control(h, 0, <<>>)

      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<1::128>>))
      assert {:ok, replacement} = SessionHolder.publish(h, session(session_id: <<2::128>>))
      parent = self()

      assert {:error, :stale_session} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 fn _frame -> send(parent, :stale_control_callback_ran) end
               )

      assert {:error, :stale_session} =
               SessionHolder.open_control(h, published.generation, <<>>)

      refute_receive :stale_control_callback_ran

      assert {:ok, 0} =
               SessionHolder.with_control_send(
                 h,
                 replacement.generation,
                 :readiness,
                 payload,
                 &control_counter/1
               )
    end

    test "seals with control counters independently from UDP telemetry state", %{holder: h} do
      udp_window = accepted_window(41)

      device =
        session(
          session_id: <<3::128>>,
          epoch: 7,
          send_counter: 41,
          replay_window: udp_window
        )

      assert {:ok, published} = SessionHolder.publish(h, device)
      payload = control_payload(:readiness)

      assert {:ok, frame0} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 & &1
               )

      assert control_counter(frame0) == 0
      assert control_session_id(frame0) == published.session_id
      assert control_credential_epoch(frame0) == 7

      assert {:ok, server_control} = Control.new(:server, peer_session(device))
      assert {:ok, :readiness, ^payload, _server_control} = Control.open(server_control, frame0)

      assert {:ok, udp} = SessionHolder.take_send_counter(h, published.generation)
      assert udp.counter == 41

      assert {:ok, 1} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 &control_counter/1
               )

      assert {:ok, stored} = SessionHolder.get_current_session(h)
      assert stored.send_counter == 42
      assert stored.replay_window == udp_window
    end

    test "owns an independent authenticated receive replay window", %{holder: h} do
      udp_window = accepted_window(12)
      device = session(session_id: <<4::128>>, epoch: 7, replay_window: udp_window)
      assert {:ok, published} = SessionHolder.publish(h, device)
      malformed_payload = Contract.payload_domain(:readiness) <> <<Contract.version(), 0x01, 0>>

      malformed_frame =
        control_frame(
          peer_session(device),
          :control_accept,
          0,
          malformed_payload,
          validate_payload_domain: false
        )

      assert {:error, :payload_domain_mismatch} =
               SessionHolder.open_control(h, published.generation, malformed_frame)

      assert {:error, :replayed} =
               SessionHolder.open_control(h, published.generation, malformed_frame)

      frame = control_frame(peer_session(device), :control_accept, 1)

      assert {:ok, :control_accept, payload} =
               SessionHolder.open_control(h, published.generation, frame)

      assert payload == control_payload(:control_accept)

      assert {:error, :replayed} =
               SessionHolder.open_control(h, published.generation, frame)

      assert {:ok, stored} = SessionHolder.get_current_session(h)
      assert stored.replay_window == udp_window
    end

    test "concurrent control allocations are serialized without collisions", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<5::128>>))
      count = 200
      payload = control_payload(:readiness)

      counters =
        1..count
        |> Task.async_stream(
          fn _ ->
            {:ok, counter} =
              SessionHolder.with_control_send(
                h,
                published.generation,
                :readiness,
                payload,
                &control_counter/1
              )

            counter
          end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, counter} -> counter end)

      assert Enum.sort(counters) == Enum.to_list(0..(count - 1))
      assert length(Enum.uniq(counters)) == count

      assert {:ok, ^count} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 &control_counter/1
               )
    end

    test "consumes a sealed counter even when the transport callback fails", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<6::128>>))
      payload = control_payload(:readiness)

      assert {:error, :control_send_failed} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 fn _frame -> raise "transport down" end
               )

      assert {:ok, 1} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 &control_counter/1
               )
    end

    test "serializes control transport work with session replacement", %{holder: h} do
      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<7::128>>))
      payload = control_payload(:readiness)

      send_task =
        Task.async(fn ->
          SessionHolder.with_control_send(
            h,
            first.generation,
            :readiness,
            payload,
            fn frame ->
              send(parent, {:control_send_started, self(), control_counter(frame)})

              receive do
                :finish_control_send -> :sent
              end
            end
          )
        end)

      assert_receive {:control_send_started, holder_pid, 0}
      assert holder_pid == h

      replacement_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<8::128>>), first.generation)
        end)

      assert Task.yield(replacement_task, 20) == nil
      send(h, :finish_control_send)

      assert {:ok, :sent} = Task.await(send_task)
      assert {:ok, replacement} = Task.await(replacement_task)
      assert replacement.generation > first.generation
    end

    test "contract failures do not consume a control send counter", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<9::128>>))

      assert {:error, :wrong_message_direction} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :control_accept,
                 control_payload(:control_accept),
                 fn _frame -> flunk("invalid-direction callback ran") end
               )

      assert {:ok, 0} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 control_payload(:readiness),
                 &control_counter/1
               )
    end

    test "replacement, clear/reconnect, and epoch eviction reset all control state", %{holder: h} do
      first_session = session(session_id: <<10::128>>, epoch: 7)
      assert {:ok, first} = SessionHolder.publish(h, first_session)
      assert_control_counter(h, first.generation, 0)

      first_frame = control_frame(peer_session(first_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, first.generation, first_frame)

      replacement_session = session(session_id: <<11::128>>, epoch: 7)
      assert {:ok, replacement} = SessionHolder.publish(h, replacement_session, first.generation)
      assert_control_counter(h, replacement.generation, 0)

      replacement_frame = control_frame(peer_session(replacement_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, replacement.generation, replacement_frame)

      assert :ok = SessionHolder.clear(h, replacement.generation)
      cleared_generation = SessionHolder.generation(h)

      assert {:error, :stale_session} =
               SessionHolder.open_control(h, replacement.generation, replacement_frame)

      reconnect_session = session(session_id: <<12::128>>, epoch: 7)

      assert {:ok, reconnect} =
               SessionHolder.publish(h, reconnect_session, cleared_generation)

      assert_control_counter(h, reconnect.generation, 0)
      reconnect_frame = control_frame(peer_session(reconnect_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, reconnect.generation, reconnect_frame)

      assert {:ok, epoch_generation, :evicted} =
               SessionHolder.fence_for_credential_epoch(h, 8)

      assert {:error, :stale_session} =
               SessionHolder.open_control(h, reconnect.generation, reconnect_frame)

      epoch_session = session(session_id: <<13::128>>, epoch: 8)

      assert {:ok, epoch_replacement} =
               SessionHolder.publish(h, epoch_session, epoch_generation)

      assert_control_counter(h, epoch_replacement.generation, 0)
      epoch_frame = control_frame(peer_session(epoch_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, epoch_replacement.generation, epoch_frame)
    end

    test "cannot reinstall a used cryptographic session after replacement", %{holder: h} do
      first_session = session(session_id: <<16::128>>, epoch: 7)
      assert {:ok, first} = SessionHolder.publish(h, first_session)
      assert_control_counter(h, first.generation, 0)
      assert {:ok, %{counter: 0}} = SessionHolder.take_send_counter(h, first.generation)

      first_frame = control_frame(peer_session(first_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, first.generation, first_frame)

      replacement_session = session(session_id: <<17::128>>, epoch: 7)

      assert {:ok, replacement} =
               SessionHolder.publish(h, replacement_session, first.generation)

      assert_control_counter(h, replacement.generation, 0)
      assert {:ok, %{counter: 0}} = SessionHolder.take_send_counter(h, replacement.generation)
      replacement_frame = control_frame(peer_session(replacement_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, replacement.generation, replacement_frame)

      assert {:error, :session_reused} = SessionHolder.put(h, first_session)

      assert_control_counter(h, replacement.generation, 1)
      assert {:ok, %{counter: 1}} = SessionHolder.take_send_counter(h, replacement.generation)

      assert {:error, :replayed} =
               SessionHolder.open_control(h, replacement.generation, replacement_frame)
    end

    test "cannot reinstall a used cryptographic session after clear", %{holder: h} do
      used_session = session(session_id: <<18::128>>, epoch: 7)
      assert {:ok, published} = SessionHolder.publish(h, used_session)
      assert_control_counter(h, published.generation, 0)
      assert {:ok, %{counter: 0}} = SessionHolder.take_send_counter(h, published.generation)

      frame = control_frame(peer_session(used_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, published.generation, frame)

      assert :ok = SessionHolder.clear(h, published.generation)
      cleared_generation = SessionHolder.generation(h)

      assert {:error, :session_reused} =
               SessionHolder.publish(h, used_session, cleared_generation)

      assert SessionHolder.generation(h) == cleared_generation
      assert {:error, :no_session} = SessionHolder.get_current_session(h)
      assert {:error, :no_session} = SessionHolder.take_send_counter(h)

      assert {:error, :no_session} =
               SessionHolder.with_control_send(
                 h,
                 cleared_generation,
                 :readiness,
                 control_payload(:readiness),
                 fn _frame -> flunk("reused control send ran") end
               )

      assert {:error, :no_session} =
               SessionHolder.open_control(h, cleared_generation, frame)
    end

    test "a higher credential epoch can reuse the id under new keys and resets the epoch set", %{
      holder: h
    } do
      session_id = <<19::128>>
      old_session = session(session_id: session_id, epoch: 7)
      assert {:ok, old} = SessionHolder.publish(h, old_session)
      assert_control_counter(h, old.generation, 0)

      old_frame = control_frame(peer_session(old_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, old.generation, old_frame)

      new_session = session(session_id: session_id, epoch: 8)
      assert {:ok, new} = SessionHolder.publish(h, new_session, old.generation)
      assert_control_counter(h, new.generation, 0)

      new_frame = control_frame(peer_session(new_session), :control_accept, 0)

      assert {:ok, :control_accept, _payload} =
               SessionHolder.open_control(h, new.generation, new_frame)

      assert {:error, :epoch_downgrade} =
               SessionHolder.publish(h, old_session, new.generation)
    end

    test "reports control counter rekey and exhaustion without advancing state", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<14::128>>))
      payload = control_payload(:readiness)
      assert_control_counter(h, published.generation, 0)

      set_control_counter(h, SecureTransport.rekey_after())

      assert {:error, :rekey_required} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 fn _frame -> flunk("rekey callback ran") end
               )

      set_control_counter(h, SecureTransport.counter_max())

      assert {:error, :counter_exhausted} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 payload,
                 fn _frame -> flunk("exhausted callback ran") end
               )
    end

    test "sessions without a purpose-key PRK retain backward-compatible UDP behavior", %{holder: h} do
      udp_only = session(session_id: <<15::128>>, prk: nil)
      assert {:ok, published} = SessionHolder.publish(h, udp_only)

      assert {:error, :session_missing_prk} =
               SessionHolder.with_control_send(
                 h,
                 published.generation,
                 :readiness,
                 control_payload(:readiness),
                 fn _frame -> flunk("unavailable control callback ran") end
               )

      assert {:ok, %{counter: 0}} =
               SessionHolder.take_send_counter(h, published.generation)

      assert {:ok, stored} = SessionHolder.get_current_session(h)
      assert stored.send_counter == 1
    end
  end

  defp peer_session(%Session{} = device) do
    %{device | role: :responder, out_key: device.in_key, in_key: device.out_key, generation: nil}
  end

  defp control_frame(%Session{} = peer, type, counter) do
    control_frame(peer, type, counter, control_payload(type), [])
  end

  defp control_frame(%Session{} = peer, type, counter, payload, opts) do
    assert {:ok, control} = Control.new(:server, peer)

    assert {:ok, frame} =
             Control.seal_with(
               control.send_key,
               control.session_id,
               control.credential_epoch,
               control.send_direction,
               type,
               counter,
               payload,
               opts
             )

    frame
  end

  defp control_counter(
         <<"ROC1", _version, _aead, _direction, _type, _session_id::binary-size(16), _credential_epoch::32, counter::64,
           _rest::binary>>
       ),
       do: counter

  defp control_session_id(<<"ROC1", _version, _aead, _direction, _type, session_id::binary-size(16), _rest::binary>>),
    do: session_id

  defp control_credential_epoch(
         <<"ROC1", _version, _aead, _direction, _type, _session_id::binary-size(16), credential_epoch::32,
           _rest::binary>>
       ),
       do: credential_epoch

  defp assert_control_counter(holder, generation, expected) do
    assert {:ok, ^expected} =
             SessionHolder.with_control_send(
               holder,
               generation,
               :readiness,
               control_payload(:readiness),
               &control_counter/1
             )
  end

  defp control_payload(type) do
    assert {:ok, type_code, _direction} = Contract.message_type(type)
    Contract.payload_domain(type) <> <<Contract.version(), type_code, 0>>
  end

  defp accepted_window(counter) do
    assert {:ok, window} = ReplayWindow.check_and_commit(ReplayWindow.new(), counter)
    window
  end

  defp set_control_counter(holder, counter) do
    :sys.replace_state(holder, fn state ->
      put_in(state.control.send_counter, counter)
    end)
  end
end
