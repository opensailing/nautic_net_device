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

    assert_receive {:send_started, callback_pid, %{generation: generation}}
    assert callback_pid == send_task.pid
    assert generation == first.generation

    replace_task =
      Task.async(fn ->
        SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)
      end)

    assert Task.yield(replace_task, 20) == nil
    send(callback_pid, :finish_send)

    assert {:ok, {:sent, generation}} = Task.await(send_task)
    assert {:ok, replacement} = Task.await(replace_task)
    assert replacement.generation > generation
    assert {:error, :stale_session} = SessionHolder.take_send_counter(h, generation)
  end

  describe "public callback leases" do
    test "with_session runs blocking re-entrant work in its caller while reads stay responsive and mutations wait", %{
      holder: h
    } do
      parent = self()
      release_ref = make_ref()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<30::128>>))

      callback_task =
        Task.async(fn ->
          SessionHolder.with_session(h, first.generation, fn current ->
            snapshot =
              {SessionHolder.live?(h), SessionHolder.generation(h), SessionHolder.get_current_session(h)}

            send(parent, {:with_session_blocked, self(), current, snapshot})

            receive do
              {:release_callback, ^release_ref} -> :session_done
            end
          end)
        end)

      assert_receive {:with_session_blocked, callback_pid, current, snapshot}, 1_000
      assert callback_pid == callback_task.pid
      assert current.session_id == first.session_id
      assert_live_snapshot(snapshot, first)
      assert_live_snapshot(holder_snapshot(h), first)

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<31::128>>), first.generation)
        end)

      assert eventually(fn -> deferred_count(h) == 1 end)
      clear_task = Task.async(fn -> SessionHolder.clear(h) end)
      assert eventually(fn -> deferred_count(h) == 2 end)
      assert Task.yield(replace_task, 20) == nil
      assert Task.yield(clear_task, 20) == nil
      assert_live_snapshot(holder_snapshot(h), first)

      send(callback_pid, {:release_callback, release_ref})

      assert {:ok, :session_done} = Task.await(callback_task)
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > first.generation
      assert :ok = Task.await(clear_task)
      refute SessionHolder.live?(h)
    end

    test "with_send_counter grants atomically then runs blocking re-entrant send work in its caller", %{
      holder: h
    } do
      parent = self()
      release_ref = make_ref()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<32::128>>))

      callback_task =
        Task.async(fn ->
          SessionHolder.with_send_counter(h, first.generation, fn grant ->
            snapshot =
              {SessionHolder.live?(h), SessionHolder.generation(h), SessionHolder.get_current_session(h)}

            send(parent, {:with_send_counter_blocked, self(), grant, snapshot})

            receive do
              {:release_callback, ^release_ref} -> :send_done
            end
          end)
        end)

      assert_receive {:with_send_counter_blocked, callback_pid, grant, snapshot}, 1_000
      assert callback_pid == callback_task.pid
      assert grant.generation == first.generation
      assert grant.session_id == first.session_id
      assert grant.counter == 0
      assert_live_snapshot(snapshot, first, send_counter: 1)
      assert_live_snapshot(holder_snapshot(h), first, send_counter: 1)

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<33::128>>), first.generation)
        end)

      assert eventually(fn -> deferred_count(h) == 1 end)
      clear_task = Task.async(fn -> SessionHolder.clear(h) end)
      assert eventually(fn -> deferred_count(h) == 2 end)
      assert Task.yield(replace_task, 20) == nil
      assert Task.yield(clear_task, 20) == nil
      assert_live_snapshot(holder_snapshot(h), first, send_counter: 1)

      send(callback_pid, {:release_callback, release_ref})

      assert {:ok, :send_done} = Task.await(callback_task)
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > first.generation
      assert :ok = Task.await(clear_task)
      refute SessionHolder.live?(h)
    end

    test "with_control_send seals atomically then runs blocking re-entrant transport work in its caller", %{
      holder: h
    } do
      parent = self()
      release_ref = make_ref()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<34::128>>))

      callback_task =
        Task.async(fn ->
          SessionHolder.with_control_send(
            h,
            first.generation,
            :readiness,
            control_payload(:readiness),
            fn frame ->
              snapshot =
                {SessionHolder.live?(h), SessionHolder.generation(h), SessionHolder.get_current_session(h)}

              send(parent, {:with_control_send_blocked, self(), frame, snapshot})

              receive do
                {:release_callback, ^release_ref} -> :control_done
              end
            end
          )
        end)

      assert_receive {:with_control_send_blocked, callback_pid, frame, snapshot}, 1_000
      assert callback_pid == callback_task.pid
      assert control_counter(frame) == 0
      assert_live_snapshot(snapshot, first)
      assert_live_snapshot(holder_snapshot(h), first)

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<35::128>>), first.generation)
        end)

      assert eventually(fn -> deferred_count(h) == 1 end)
      clear_task = Task.async(fn -> SessionHolder.clear(h) end)
      assert eventually(fn -> deferred_count(h) == 2 end)
      assert Task.yield(replace_task, 20) == nil
      assert Task.yield(clear_task, 20) == nil
      assert_live_snapshot(holder_snapshot(h), first)

      send(callback_pid, {:release_callback, release_ref})

      assert {:ok, :control_done} = Task.await(callback_task)
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > first.generation
      assert :ok = Task.await(clear_task)
      refute SessionHolder.live?(h)
    end

    test "named holder restart kills a callback leased from the prior incarnation", %{
      holder: _default_holder
    } do
      parent = self()
      name_key = {__MODULE__, make_ref()}
      name = {:global, name_key}

      {:ok, old_holder} =
        start_supervised(
          {SessionHolder, name: name},
          id: {:restarting_named_holder, make_ref()}
        )

      assert {:ok, published} =
               SessionHolder.publish(name, session(session_id: <<36::128>>))

      caller =
        spawn(fn ->
          result =
            SessionHolder.with_session(name, published.generation, fn _session ->
              send(parent, {:prior_incarnation_callback_started, self()})

              receive do
                :finish_prior_incarnation_callback -> :completed
              end
            end)

          send(parent, {:prior_incarnation_callback_result, self(), result})
        end)

      caller_ref = Process.monitor(caller)
      assert_receive {:prior_incarnation_callback_started, ^caller}, 1_000

      holder_ref = Process.monitor(old_holder)
      Process.exit(old_holder, :kill)
      assert_receive {:DOWN, ^holder_ref, :process, ^old_holder, :killed}, 1_000
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000

      assert eventually(fn ->
               case :global.whereis_name(name_key) do
                 new_holder when is_pid(new_holder) -> new_holder != old_holder
                 :undefined -> false
               end
             end)

      send(caller, :finish_prior_incarnation_callback)
      refute_receive {:prior_incarnation_callback_result, ^caller, _result}
      assert SessionHolder.generation(name) == 0
    end

    test "a release-side holder exit is contained as the callback API's typed error" do
      parent = self()
      generation = 7
      current = session(session_id: <<37::128>>)

      one_shot_holder =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:take_session_lease, ^generation}} ->
              lease = %{
                ref: make_ref(),
                holder: self(),
                generation: generation,
                session_id: current.session_id
              }

              GenServer.reply(from, {:ok, current, lease})
          end
        end)

      holder_ref = Process.monitor(one_shot_holder)

      caller =
        spawn(fn ->
          result =
            SessionHolder.with_session(one_shot_holder, generation, fn _session ->
              send(parent, {:release_exit_callback_started, self()})

              receive do
                :finish_release_exit_callback -> :completed
              end
            end)

          send(parent, {:release_exit_callback_result, self(), result})
        end)

      assert_receive {:release_exit_callback_started, ^caller}, 1_000
      assert_receive {:DOWN, ^holder_ref, :process, ^one_shot_holder, :normal}, 1_000
      send(caller, :finish_release_exit_callback)

      assert_receive {:release_exit_callback_result, ^caller, {:error, :session_callback_failed}},
                     1_000
    end

    test "normal return, raise, throw, and exit all release callback leases with legacy results", %{
      holder: h
    } do
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<36::128>>))

      assert {:ok, :normal} =
               SessionHolder.with_session(h, first.generation, fn _session -> :normal end)

      assert {:error, :session_callback_failed} =
               SessionHolder.with_session(h, first.generation, fn _session -> raise "failed" end)

      assert {:ok, second} =
               SessionHolder.publish(h, session(session_id: <<37::128>>), first.generation)

      assert {:error, :send_failed} =
               SessionHolder.with_send_counter(h, second.generation, fn _grant ->
                 throw(:failed)
               end)

      assert {:ok, third} =
               SessionHolder.publish(h, session(session_id: <<38::128>>), second.generation)

      assert {:error, :control_send_failed} =
               SessionHolder.with_control_send(
                 h,
                 third.generation,
                 :readiness,
                 control_payload(:readiness),
                 fn _frame -> exit(:failed) end
               )

      assert {:ok, fourth} =
               SessionHolder.publish(h, session(session_id: <<39::128>>), third.generation)

      assert fourth.generation > third.generation
    end

    test "a callback owner attempting session mutations fails fast instead of deadlocking", %{
      holder: h
    } do
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<40::128>>))

      assert {:ok,
              %{
                put: {:error, :send_lease_active},
                publish: {:error, :send_lease_active},
                clear: {:error, :send_lease_active},
                fence: {:error, :send_lease_active}
              }} =
               SessionHolder.with_session(h, first.generation, fn _session ->
                 %{
                   put: SessionHolder.put(h, session(session_id: <<45::128>>)),
                   publish:
                     SessionHolder.publish(
                       h,
                       session(session_id: <<41::128>>),
                       first.generation
                     ),
                   clear: SessionHolder.clear(h, first.generation),
                   fence: SessionHolder.fence_for_credential_epoch(h, first.credential_epoch + 1)
                 }
               end)

      assert_live_snapshot(holder_snapshot(h), first)
    end

    test "concurrent caller-side UDP grants remain unique", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<42::128>>))
      count = 100

      counters =
        1..count
        |> Task.async_stream(
          fn _ ->
            assert {:ok, counter} =
                     SessionHolder.with_send_counter(h, published.generation, & &1.counter)

            counter
          end,
          max_concurrency: 50,
          ordered: false
        )
        |> Enum.map(fn {:ok, counter} -> counter end)

      assert Enum.sort(counters) == Enum.to_list(0..(count - 1))
      assert length(Enum.uniq(counters)) == count
    end

    test "an expired caller-side lease kills a hung owner before allowing replacement", %{
      holder: _default_holder
    } do
      {:ok, h} =
        start_supervised(
          {SessionHolder, name: nil, send_lease_ttl: 200},
          id: {:expiring_lease_holder, make_ref()}
        )

      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<43::128>>))

      owner =
        spawn(fn ->
          SessionHolder.with_send_counter(h, first.generation, fn grant ->
            send(parent, {:hung_send_started, self(), grant})

            receive do
              :transmit_old_session -> send(parent, :expired_old_session_transmitted)
            end
          end)
        end)

      owner_ref = Process.monitor(owner)
      assert_receive {:hung_send_started, callback_pid, %{counter: 0}}, 1_000
      assert callback_pid == owner

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<44::128>>), first.generation)
        end)

      assert eventually(fn -> deferred_count(h) == 1 end)
      assert Task.yield(replace_task, 20) == nil

      assert {:ok, replacement} = Task.await(replace_task, 1_000)
      assert replacement.generation > first.generation
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000
      refute Process.alive?(owner)

      send(owner, :transmit_old_session)
      refute_receive :expired_old_session_transmitted, 50
    end

    test "normal release cancels the lease timer without killing its still-live owner", %{
      holder: _default_holder
    } do
      {:ok, h} =
        start_supervised(
          {SessionHolder, name: nil, send_lease_ttl: 50},
          id: {:released_lease_holder, make_ref()}
        )

      parent = self()
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<46::128>>))

      owner =
        spawn(fn ->
          result =
            SessionHolder.with_session(h, published.generation, fn _session -> :released end)

          send(parent, {:released_callback_result, self(), result})

          receive do
            :prove_still_alive -> send(parent, {:released_owner_alive, self()})
          end
        end)

      owner_ref = Process.monitor(owner)
      assert_receive {:released_callback_result, ^owner, {:ok, :released}}, 1_000
      Process.sleep(100)
      refute_receive {:DOWN, ^owner_ref, :process, ^owner, _reason}

      send(owner, :prove_still_alive)
      assert_receive {:released_owner_alive, ^owner}
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :normal}
    end
  end

  describe "send leases" do
    # A lease keeps the 881ae91 guarantee — replacement/clear cannot overtake an
    # approved send — WITHOUT parking the holder inside caller transport work.
    # The holder authorizes, records the lease, and replies immediately; publish and
    # clear then block until the lease is released. This is the same mutual exclusion
    # as running the callback in the holder, minus the head-of-line blocking.
    test "an open lease defers replacement and clear until it is released", %{holder: h} do
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<1::128>>))

      assert {:ok, lease} = SessionHolder.acquire_send_lease(h, first.generation)
      assert lease.holder == h
      assert lease.session_id == first.session_id
      assert lease.generation == first.generation

      # The holder stays responsive to every other API while the lease is open.
      assert SessionHolder.live?(h)
      assert SessionHolder.generation(h) == first.generation
      assert {:ok, ^first} = SessionHolder.get_current_session(h)

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<2::128>>), first.generation)
        end)

      # Park the replacement FIRST, deterministically, so the replay order below is
      # arrival order and not a scheduling race between the two mutations.
      assert eventually(fn -> deferred_count(h) == 1 end)

      clear_task = Task.async(fn -> SessionHolder.clear(h) end)
      assert eventually(fn -> deferred_count(h) == 2 end)

      # Neither mutation may land while the authorized send is still in flight.
      assert Task.yield(replace_task, 50) == nil
      assert Task.yield(clear_task, 50) == nil
      assert {:ok, ^first} = SessionHolder.get_current_session(h)

      assert :ok = SessionHolder.release_send_lease(h, lease)

      # Replayed in arrival order: the fenced publish lands, then the clear.
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > first.generation
      assert :ok = Task.await(clear_task)
      refute SessionHolder.live?(h)
    end

    test "a caller-owned token cancels deferred publish before holder observes DOWN", %{
      holder: h
    } do
      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<47::128>>))

      lease_owner =
        spawn(fn ->
          result =
            SessionHolder.with_session(h, first.generation, fn _session ->
              send(parent, {:deferred_token_lease_started, self()})

              receive do
                :release_deferred_token_lease -> :released
              end
            end)

          send(parent, {:deferred_token_lease_result, self(), result})
        end)

      assert_receive {:deferred_token_lease_started, ^lease_owner}, 1_000

      publisher =
        spawn(fn ->
          result =
            SessionHolder.publish(
              h,
              session(session_id: <<48::128>>),
              first.generation
            )

          send(parent, {:deferred_publish_result, self(), result})
        end)

      publisher_ref = Process.monitor(publisher)
      assert eventually(fn -> deferred_count(h) == 1 end)

      holder_state = :sys.get_state(h)
      [deferred_monitor_ref] = holder_state.deferred |> :queue.to_list()
      %{token_table: token_table, token: token} = holder_state.deferred_monitors[deferred_monitor_ref]

      assert :ets.lookup(token_table, token) == [{token, true}]
      [lease_ref] = Map.keys(holder_state.send_leases)

      try do
        :ok = :sys.suspend(h)
        send(lease_owner, :release_deferred_token_lease)

        assert eventually(fn ->
                 not is_nil(
                   queued_message_index(h, fn
                     {:"$gen_call", _from, {:release_send_lease, ^lease_ref}} -> true
                     _message -> false
                   end)
                 )
               end)

        Process.exit(publisher, :kill)
        assert_receive {:DOWN, ^publisher_ref, :process, ^publisher, :killed}, 1_000
        assert :ets.info(token_table) == :undefined

        assert Map.has_key?(:sys.get_state(h).deferred_monitors, deferred_monitor_ref)
      after
        :ok = :sys.resume(h)
      end

      assert_receive {:deferred_token_lease_result, ^lease_owner, {:ok, :released}}, 1_000
      refute_receive {:deferred_publish_result, ^publisher, _result}
      assert SessionHolder.generation(h) == first.generation
      assert {:ok, ^first} = SessionHolder.get_current_session(h)

      assert {:ok, replacement} =
               SessionHolder.publish(
                 h,
                 session(session_id: <<49::128>>),
                 first.generation
               )

      assert replacement.generation == first.generation + 1
    end

    test "the first deferred mutation drains existing leases and rejects later leases", %{holder: h} do
      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<50::128>>))
      assert {:ok, lease} = SessionHolder.acquire_send_lease(h, first.generation)

      clear_task = Task.async(fn -> SessionHolder.clear(h, first.generation) end)
      assert eventually(fn -> deferred_count(h) == 1 end)

      assert {:error, :stale_session} = SessionHolder.acquire_send_lease(h, first.generation)
      assert {:error, :stale_session} = SessionHolder.take_send_counter_lease(h, first.generation)

      assert {:error, :stale_session} =
               SessionHolder.with_session(h, first.generation, fn _session ->
                 send(parent, :draining_session_callback_ran)
               end)

      assert {:error, :no_session} =
               SessionHolder.with_send_counter(h, fn _grant ->
                 send(parent, :draining_send_callback_ran)
               end)

      assert {:error, :stale_session} =
               SessionHolder.seal_control_send(
                 h,
                 first.generation,
                 :readiness,
                 control_payload(:readiness)
               )

      refute_receive :draining_session_callback_ran
      refute_receive :draining_send_callback_ran

      assert :ok = SessionHolder.release_send_lease(h, lease)
      assert :ok = Task.await(clear_task)
      refute SessionHolder.live?(h)
    end

    test "a lease cannot be acquired against a stale generation or an idle holder", %{holder: h} do
      assert {:error, :no_session} = SessionHolder.acquire_send_lease(h, 0)

      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<3::128>>))
      assert {:ok, second} = SessionHolder.publish(h, session(session_id: <<4::128>>), first.generation)

      assert {:error, :stale_session} = SessionHolder.acquire_send_lease(h, first.generation)
      assert {:ok, lease} = SessionHolder.acquire_send_lease(h, second.generation)
      assert :ok = SessionHolder.release_send_lease(h, lease)
    end

    test "a copied lease cannot be released by a process other than its owner", %{holder: h} do
      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<51::128>>))

      owner =
        spawn(fn ->
          {:ok, lease} = SessionHolder.acquire_send_lease(h, first.generation)
          send(parent, {:owned_lease, self(), lease})

          receive do
            :transmit -> send(parent, {:old_session_transmitted, self()})
            :release -> :ok = SessionHolder.release_send_lease(h, lease)
          end
        end)

      assert_receive {:owned_lease, ^owner, lease}, 1_000
      assert {:error, :not_send_lease_owner} = SessionHolder.release_send_lease(h, lease)

      replacement =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<52::128>>), first.generation)
        end)

      assert Task.yield(replacement, 50) == nil
      send(owner, :transmit)
      assert_receive {:old_session_transmitted, ^owner}, 1_000

      send(owner, :release)
      assert {:ok, published} = Task.await(replacement)
      assert published.generation > first.generation
    end

    test "guard death kills active lease owners before holder replacement", %{
      holder: _default_holder
    } do
      parent = self()
      name_key = {__MODULE__, make_ref()}
      name = {:global, name_key}

      {:ok, old_holder} =
        start_supervised(
          {SessionHolder, name: name},
          id: {:guard_death_with_lease, make_ref()}
        )

      assert {:ok, published} =
               SessionHolder.publish(name, session(session_id: <<53::128>>))

      owner =
        spawn(fn ->
          SessionHolder.with_session(name, published.generation, fn _session ->
            send(parent, {:guard_death_lease_started, self()})

            receive do
              :transmit -> send(parent, {:guard_death_old_session_transmitted, self()})
            end
          end)
        end)

      owner_ref = Process.monitor(owner)
      assert_receive {:guard_death_lease_started, ^owner}, 1_000

      old_holder_ref = Process.monitor(old_holder)
      guard = :sys.get_state(old_holder).incarnation_guard
      Process.exit(guard, :kill)

      assert_receive {:DOWN, ^old_holder_ref, :process, ^old_holder, _reason}, 1_000
      assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, 1_000

      assert eventually(fn ->
               case :global.whereis_name(name_key) do
                 replacement when is_pid(replacement) -> replacement != old_holder
                 :undefined -> false
               end
             end)

      send(owner, :transmit)
      refute_receive {:guard_death_old_session_transmitted, ^owner}
    end

    test "the holder cannot outlive a failed incarnation guard", %{holder: _default_holder} do
      name_key = {__MODULE__, make_ref()}
      name = {:global, name_key}

      {:ok, holder} =
        start_supervised(
          {SessionHolder, name: name},
          id: {:guarded_named_holder, make_ref()}
        )

      holder_ref = Process.monitor(holder)
      guard = :sys.get_state(holder).incarnation_guard
      Process.exit(guard, :kill)

      assert_receive {:DOWN, ^holder_ref, :process, ^holder, _reason}, 1_000

      assert eventually(fn ->
               case :global.whereis_name(name_key) do
                 new_holder when is_pid(new_holder) -> new_holder != holder
                 :undefined -> false
               end
             end)
    end

    # The holder must never be wedged by a caller that dies mid-send. It monitors
    # every lease holder and releases the lease on DOWN.
    test "a crashed lease holder releases its lease automatically", %{holder: h} do
      parent = self()
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<5::128>>))

      leaser =
        spawn(fn ->
          {:ok, lease} = SessionHolder.acquire_send_lease(h, first.generation)
          send(parent, {:leased, lease})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:leased, _lease}

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<6::128>>), first.generation)
        end)

      assert Task.yield(replace_task, 50) == nil

      Process.exit(leaser, :kill)

      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > first.generation
    end

    test "take_send_counter_lease reserves the UDP nonce and fences its transport", %{
      holder: h
    } do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<24::128>>))

      assert {:ok, grant, lease} =
               SessionHolder.take_send_counter_lease(h, published.generation)

      assert grant.counter == 0
      assert grant.generation == published.generation
      assert grant.session_id == published.session_id
      assert lease.generation == published.generation
      assert lease.session_id == published.session_id
      assert_live_snapshot(holder_snapshot(h), published, send_counter: 1)

      replace_task =
        Task.async(fn ->
          SessionHolder.publish(
            h,
            session(session_id: <<25::128>>),
            published.generation
          )
        end)

      assert eventually(fn -> deferred_count(h) == 1 end)
      assert Task.yield(replace_task, 20) == nil
      assert :ok = SessionHolder.release_send_lease(h, lease)
      assert {:ok, replacement} = Task.await(replace_task)
      assert replacement.generation > published.generation
    end

    # The control path DOES allocate a nonce, so the seal must stay inside the
    # holder. Only the transport write moves out, under the same lease: the counter
    # is consumed atomically, the frame is handed back, and replacement is deferred
    # until the caller releases — so a sealed frame can never be transmitted after
    # its session was replaced, and the holder never waits on caller transport.
    test "seal_control_send consumes a counter in the holder and leases the transport", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<20::128>>))

      assert {:ok, frame, lease} =
               SessionHolder.seal_control_send(
                 h,
                 published.generation,
                 :readiness,
                 control_payload(:readiness)
               )

      assert control_counter(frame) == 0
      assert lease.generation == published.generation

      # Holder is responsive while the caller is still transmitting.
      assert SessionHolder.live?(h)

      # ...but a replacement cannot overtake the sealed, in-flight frame.
      replace_task =
        Task.async(fn -> SessionHolder.publish(h, session(session_id: <<21::128>>), published.generation) end)

      assert Task.yield(replace_task, 50) == nil
      assert :ok = SessionHolder.release_send_lease(h, lease)
      assert {:ok, _replacement} = Task.await(replace_task)
    end

    test "a failed contract encode consumes no control counter and takes no lease", %{holder: h} do
      assert {:ok, published} = SessionHolder.publish(h, session(session_id: <<22::128>>))

      assert {:error, :wrong_message_direction} =
               SessionHolder.seal_control_send(
                 h,
                 published.generation,
                 :control_accept,
                 control_payload(:control_accept)
               )

      # No lease was taken, so a replacement proceeds immediately.
      assert {:ok, replacement} =
               SessionHolder.publish(h, session(session_id: <<23::128>>), published.generation)

      # And the counter was never consumed for the new session's control state.
      assert {:ok, frame, lease} =
               SessionHolder.seal_control_send(
                 h,
                 replacement.generation,
                 :readiness,
                 control_payload(:readiness)
               )

      assert control_counter(frame) == 0
      assert :ok = SessionHolder.release_send_lease(h, lease)
    end

    # A stale lease must never gate the holder after its generation is gone.
    test "releasing a lease twice or after replacement is inert", %{holder: h} do
      assert {:ok, first} = SessionHolder.publish(h, session(session_id: <<7::128>>))
      assert {:ok, lease} = SessionHolder.acquire_send_lease(h, first.generation)

      assert :ok = SessionHolder.release_send_lease(h, lease)
      assert :ok = SessionHolder.release_send_lease(h, lease)

      assert {:ok, replacement} = SessionHolder.publish(h, session(session_id: <<8::128>>), first.generation)
      assert :ok = SessionHolder.release_send_lease(h, lease)
      assert {:ok, current} = SessionHolder.get_current_session(h)
      assert current.generation == replacement.generation
    end
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

      assert_receive {:control_send_started, callback_pid, 0}
      assert callback_pid == send_task.pid

      replacement_task =
        Task.async(fn ->
          SessionHolder.publish(h, session(session_id: <<8::128>>), first.generation)
        end)

      assert Task.yield(replacement_task, 20) == nil
      send(callback_pid, :finish_control_send)

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

    # The uniqueness that matters is CRYPTOGRAPHIC, and the handshake already
    # provides it: `session_id` and both direction keys are HKDF-derived from a
    # transcript binding fresh ephemeral keys and the server nonce, so every
    # handshake yields distinct keys AND a distinct session_id. Two sessions can
    # only collide by re-deriving the same transcript, which also re-derives the
    # same keys — the accepting-a-duplicate case the holder must refuse. Rejecting
    # the CURRENT session's id is exactly that check, and it needs no history.
    #
    # A process-local denylist cannot be a durable nonce-reuse invariant anyway: it
    # is lost on every holder restart, so it never actually protected across the
    # boundary it appears to. What it DID create is an availability cliff — after
    # enough legitimate reconnects on one credential epoch, publication fails until
    # the epoch rotates, permanently bricking reconnect on a device that cannot
    # rotate on its own.
    @tag :session_identity_cliff
    test "many legitimate reconnects on one credential epoch never brick publication", %{holder: h} do
      reconnects = 5_000

      final =
        Enum.reduce(1..reconnects, nil, fn n, previous ->
          expected = if previous, do: previous.generation, else: SessionHolder.generation(h)

          assert {:ok, published} =
                   SessionHolder.publish(h, session(session_id: <<n::128>>, epoch: 7), expected),
                 "reconnect ##{n} was refused on a single credential epoch"

          published
        end)

      assert final.generation == reconnects
      assert SessionHolder.live?(h)

      # Fresh sessions still work, and the CURRENT one is still refused.
      assert {:error, :session_reused} = SessionHolder.publish(h, final, final.generation)
    end

    # Distinct keys are the whole point: a re-derived session_id means re-derived
    # keys, so accepting a RECENT one would reset counters/replay windows under keys
    # that already carried traffic.
    @tag :session_identity_cliff
    test "a recently fenced identity is refused even after clear", %{holder: h} do
      live = session(session_id: <<0xAB::128>>, epoch: 7)
      assert {:ok, published} = SessionHolder.publish(h, live)
      assert {:error, :session_reused} = SessionHolder.publish(h, live, published.generation)

      # Clearing drops the session, and a re-published identity would restart its
      # counters and replay window from zero under the SAME derived keys.
      assert :ok = SessionHolder.clear(h, published.generation)
      cleared = SessionHolder.generation(h)
      assert {:error, :session_reused} = SessionHolder.publish(h, live, cleared)

      # A genuinely different handshake (different transcript -> different id and
      # keys) is accepted, so reconnect is never bricked.
      assert {:ok, next} = SessionHolder.publish(h, session(session_id: <<0xAC::128>>, epoch: 7), cleared)
      assert next.generation > published.generation
    end

    # The identity history is bounded, but it must EVICT rather than refuse: a full
    # ring may age out old replay protection, it may never turn a fresh, legitimate
    # session into a publication failure.
    @tag :session_identity_cliff
    test "a full identity history evicts the oldest entry instead of refusing", %{holder: h} do
      first_session = session(session_id: <<20::128>>, epoch: 7)
      assert {:ok, first} = SessionHolder.publish(h, first_session)
      assert_control_counter(h, first.generation, 0)

      # Recent identities are still refused...
      assert {:error, :session_reused} = SessionHolder.publish(h, first_session, first.generation)

      # ...while a long run of genuinely new handshakes keeps publishing.
      final =
        Enum.reduce(1..512, first, fn n, previous ->
          assert {:ok, published} =
                   SessionHolder.publish(h, session(session_id: <<n + 100::128>>, epoch: 7), previous.generation)

          published
        end)

      # Memory is bounded: the ring holds at most its cap, oldest evicted first.
      assert length(:sys.get_state(h).used_session_ids) <= 256

      # The most recent identities are still refused (protection where it counts).
      assert {:error, :session_reused} = SessionHolder.publish(h, final, final.generation)

      # And an evicted, long-superseded identity no longer blocks availability.
      assert {:ok, revived} = SessionHolder.publish(h, first_session, final.generation)
      assert revived.generation > final.generation
      assert_control_counter(h, revived.generation, 0)
    end

    test "a higher credential epoch prunes the identity history" do
      {:ok, h} = start_supervised({SessionHolder, name: nil}, id: {:epoch_holder, make_ref()})

      reused = session(session_id: <<22::128>>, epoch: 7)
      assert {:ok, published} = SessionHolder.publish(h, reused)
      assert {:error, :session_reused} = SessionHolder.publish(h, reused, published.generation)

      assert {:ok, rotated_generation, :evicted} = SessionHolder.fence_for_credential_epoch(h, 8)

      # The epoch is bound into the transcript, so the same id under a HIGHER epoch
      # is a different session with different keys — it must publish cleanly.
      rotated_session = session(session_id: <<22::128>>, epoch: 8)
      assert {:ok, rotated} = SessionHolder.publish(h, rotated_session, rotated_generation)
      assert_control_counter(h, rotated.generation, 0)
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

  defp holder_snapshot(holder) do
    {SessionHolder.live?(holder), SessionHolder.generation(holder), SessionHolder.get_current_session(holder)}
  end

  defp assert_live_snapshot({true, generation, {:ok, current}}, published, opts \\ []) do
    assert generation == published.generation
    assert current.generation == published.generation
    assert current.session_id == published.session_id

    if expected_counter = Keyword.get(opts, :send_counter) do
      assert current.send_counter == expected_counter
    end
  end

  # How many session mutations are currently parked behind open send leases. Used
  # to sequence deferrals deterministically instead of racing two Task spawns.
  defp deferred_count(holder) do
    holder |> :sys.get_state() |> Map.fetch!(:deferred) |> :queue.len()
  end

  defp queued_message_index(holder, matcher) do
    {:messages, messages} = Process.info(holder, :messages)
    Enum.find_index(messages, matcher)
  end

  defp eventually(fun, retries \\ 100) do
    cond do
      fun.() -> true
      retries <= 0 -> false
      true -> Process.sleep(5) && eventually(fun, retries - 1)
    end
  end
end
