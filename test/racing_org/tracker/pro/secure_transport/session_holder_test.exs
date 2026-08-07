defmodule RacingOrg.Tracker.Pro.SecureTransport.SessionHolderTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

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
          in_key: :binary.copy(<<0xBB>>, 32)
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
end
