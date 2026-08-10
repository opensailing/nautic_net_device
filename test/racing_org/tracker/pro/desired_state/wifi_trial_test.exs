defmodule RacingOrg.Tracker.Pro.DesiredState.WiFiTrialTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias RacingOrg.Tracker.Pro.WiFi.Store
  alias RacingOrg.Tracker.Pro.WiFiManager
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "desired_state_wifi_trial_#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "candidate PSK is transient until bounded authenticated confirmation succeeds", %{dir: dir} do
    prior = %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}
    assert :ok = Store.save(dir, prior)

    parent = self()

    pid =
      start_manager(dir,
        confirm_fun: fn ->
          send(parent, :authenticated_confirmation)
          :ok
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    secret = Secret.new("candidate-secret")
    refute inspect(secret) =~ "candidate-secret"
    assert inspect(secret) =~ "REDACTED"

    activation_id = :crypto.strong_rand_bytes(32)

    log =
      capture_log(fn ->
        assert {:ok, %{version: 2, enabled: true, ssid: "candidate"}} =
                 WiFiManager.trial_config(
                   pid,
                   %{"version" => 2, "enabled" => true, "ssid" => "candidate"},
                   secret,
                   activation_id
                 )
      end)

    refute log =~ "candidate-secret"
    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive :authenticated_confirmation

    assert {:ok, persisted} = Store.load(dir)

    assert persisted == %{
             version: 2,
             enabled: true,
             ssid: "candidate",
             desired_activation_id: activation_id
           }

    assert {:ok, durable_bytes} = File.read(Path.join(dir, "current.wifi"))
    refute durable_bytes =~ "candidate-secret"
    assert WiFiManager.desired_activation_id(pid) == activation_id

    status = :sys.get_state(pid) |> inspect()
    refute status =~ "candidate-secret"
    refute status =~ "prior-secret"
  end

  test "a committed candidate still reconnects after reboot from a credential the marker never carries",
       %{dir: dir} do
    assert :ok = Store.save(dir, %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"})

    pid = start_manager(dir, confirm_fun: fn -> :ok end)
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    activation_id = <<9::256>>

    assert {:ok, %{version: 6, enabled: true, ssid: "candidate"}} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 6, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock

    assert {:ok, marker} = Store.load(dir)
    refute Map.has_key?(marker, :psk)

    assert {:ok, marker_bytes} = File.read(Path.join(dir, "current.wifi"))
    refute marker_bytes =~ "candidate-secret"

    # Reboot: the owner marker is secretless, but the durable authority still holds
    # the credential the candidate network needs to reassociate.
    :ok = stop_supervised(WiFiManager)

    rebooted = start_manager(dir, [])
    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert WiFiManager.desired_activation_id(rebooted) == activation_id
  end

  test "crash-report formatting redacts credential material that Erlang term formatting would expose" do
    secret = Secret.new("candidate-secret")

    status = %{
      state: %{store_dir: "/data/wifi", psk: "prior-secret", pending: secret},
      message:
        {:apply_config,
         %{
           "version" => 1,
           "enabled" => true,
           "ssid" => "candidate",
           "psk" => "legacy-secret",
           "PassPhrase" => "ignored-secret"
         }},
      reason: {:badmatch, %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}},
      log: [{:in, {:"$gen_call", {self(), make_ref()}, {:trial_config, %{}, secret, <<9::256>>}}}]
    }

    rendered =
      status
      |> WiFiManager.format_status()
      |> then(&:io_lib.format(~c"~0p", [&1]))
      |> IO.iodata_to_binary()

    refute rendered =~ "candidate-secret"
    refute rendered =~ "prior-secret"
    refute rendered =~ "legacy-secret"
    refute rendered =~ "ignored-secret"
  end

  test "a manager crash cannot return a Secret-bearing call in the caller exit reason" do
    server =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:trial_config, _config, %Secret{}, _activation_id}} ->
            exit(:simulated_crash)
        end
      end)

    result =
      WiFiManager.trial_config(
        server,
        %{"version" => 2, "enabled" => true, "ssid" => "candidate"},
        Secret.new("caller-visible-secret"),
        <<9::256>>
      )

    assert result == {:error, :wifi_manager_unavailable}

    rendered = result |> then(&:io_lib.format(~c"~p", [&1])) |> IO.iodata_to_binary()
    refute rendered =~ "caller-visible-secret"
  end

  test "an ambiguous owner-marker write is resolved by rereading the nonsecret authority", %{dir: dir} do
    prior = %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}
    assert :ok = Store.save(dir, prior)

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        store_save_fun: fn store_dir, record ->
          assert :ok = Store.save(store_dir, record)
          {:error, :after_durable_commit}
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    activation_id = <<7::256>>

    assert {:ok, %{version: 5, enabled: true, ssid: "candidate"}} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    refute_receive {:configure, "prior", "prior-secret"}

    assert {:ok,
            %{
              version: 5,
              enabled: true,
              ssid: "candidate",
              desired_activation_id: ^activation_id
            }} = Store.load(dir)
  end

  test "directory-sync uncertainty is never reconciled from visible owner-marker bytes", %{dir: dir} do
    prior = %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}
    assert :ok = Store.save(dir, prior)

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        store_save_fun: fn store_dir, record ->
          assert :ok = Store.save(store_dir, record)
          {:error, {:durability_uncertain, :directory_sync}}
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<8::256>>
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert WiFiManager.desired_activation_id(pid) == nil
  end

  test "an unreadable owner marker aborts a trial before radio mutation", %{dir: dir} do
    prior_activation_id = <<5::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    assert :ok = Store.save(dir, prior)

    assert :ok =
             Store.put_credential(
               dir,
               Secret.new("prior-secret"),
               %{ssid: "prior", desired_activation_id: prior_activation_id}
             )

    {:ok, authority_mode} = Agent.start_link(fn -> :readable end)
    parent = self()

    authority_load_fun = fn store_dir ->
      case Agent.get(authority_mode, & &1) do
        :readable -> Store.read_authority(store_dir)
        :unreadable -> {:error, :eio}
      end
    end

    pid =
      start_manager(dir,
        authority_load_fun: authority_load_fun,
        confirm_fun: fn ->
          send(parent, :unexpected_confirmation)
          :ok
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock
    assert WiFiManager.desired_activation_id(pid) == prior_activation_id
    Agent.update(authority_mode, fn _current -> :unreadable end)

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<6::256>>
             )

    refute_receive {:configure, "candidate", "candidate-secret"}
    refute_receive :unexpected_confirmation
    refute_receive :deconfigure
    refute_receive :rfkill_block
    assert WiFiManager.desired_activation_id(pid) == nil
    assert Store.load(dir) == {:ok, prior}
  end

  test "an unreadable ambiguous marker stays fail-closed until durable authority can be rederived", %{
    dir: dir
  } do
    prior = %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}
    assert :ok = Store.save(dir, prior)

    activation_id = <<6::256>>
    {:ok, authority} = Agent.start_link(fn -> :readable end)

    authority_load_fun = fn store_dir ->
      case Agent.get(authority, & &1) do
        :readable -> Store.load(store_dir)
        :unreadable -> {:error, :eio}
      end
    end

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        authority_load_fun: authority_load_fun,
        store_save_fun: fn store_dir, record ->
          assert :ok = Store.save(store_dir, record)
          Agent.update(authority, fn _current -> :unreadable end)
          {:error, :after_durable_commit}
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    refute_receive {:configure, "prior", "prior-secret"}

    assert {:ok, %{desired_activation_id: ^activation_id}} = Store.load(dir)

    assert {:ok, _candidate_credential} =
             Store.credential(dir, %{ssid: "candidate", desired_activation_id: activation_id})

    Agent.update(authority, fn _current -> :readable end)

    assert :ok = WiFiManager.reconcile_desired_activation(pid, activation_id)
    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert WiFiManager.desired_activation_id(pid) == activation_id
  end

  test "indeterminate marker authority preserves both credential choices until it resolves", %{
    dir: dir
  } do
    prior_activation_id = <<5::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    assert :ok = Store.save(dir, prior)

    assert :ok =
             Store.put_credential(
               dir,
               Secret.new("prior-secret"),
               %{ssid: "prior", desired_activation_id: prior_activation_id}
             )

    candidate_activation_id = <<6::256>>
    {:ok, authority} = Agent.start_link(fn -> :readable end)

    authority_load_fun = fn store_dir ->
      case Agent.get(authority, & &1) do
        :readable -> Store.read_authority(store_dir)
        :unreadable -> {:error, :eio}
      end
    end

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        authority_load_fun: authority_load_fun,
        store_save_fun: fn _store_dir, record ->
          if Map.get(record, :desired_activation_id) == candidate_activation_id do
            Agent.update(authority, fn _current -> :unreadable end)
            {:error, :before_durable_commit}
          else
            {:error, :unexpected_marker_write}
          end
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               candidate_activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    refute_receive {:configure, "prior", "prior-secret"}
    assert Store.load(dir) == {:ok, prior}

    assert {:ok, _prior_credential} =
             Store.credential(dir, %{
               ssid: "prior",
               desired_activation_id: prior_activation_id
             })

    assert {:ok, _candidate_credential} =
             Store.credential(dir, %{
               ssid: "candidate",
               desired_activation_id: candidate_activation_id
             })

    Agent.update(authority, fn _current -> :readable end)

    assert {:error, :wifi_activation_mismatch} =
             WiFiManager.reconcile_desired_activation(pid, candidate_activation_id)

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock
    assert WiFiManager.desired_activation_id(pid) == prior_activation_id

    assert {:ok, _prior_credential} =
             Store.credential(dir, %{
               ssid: "prior",
               desired_activation_id: prior_activation_id
             })

    assert :empty =
             Store.credential(dir, %{
               ssid: "candidate",
               desired_activation_id: candidate_activation_id
             })
  end

  test "an unreadable prior credential aborts a trial without deleting the intact sidecar", %{
    dir: dir
  } do
    prior_activation_id = <<5::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    binding = %{ssid: "prior", desired_activation_id: prior_activation_id}
    assert :ok = Store.save(dir, prior)
    assert :ok = Store.put_credential(dir, Secret.new("prior-secret"), binding)

    {:ok, credential_mode} = Agent.start_link(fn -> :readable end)
    parent = self()

    credential_load_fun = fn store_dir, requested_binding ->
      case Agent.get(credential_mode, & &1) do
        :readable -> Store.credential(store_dir, requested_binding)
        :unreadable -> {:error, {:credential_read_failed, :eio}}
      end
    end

    pid =
      start_manager(dir,
        credential_load_fun: credential_load_fun,
        confirm_fun: fn ->
          send(parent, :unexpected_confirmation)
          :ok
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock
    Agent.update(credential_mode, fn _current -> :unreadable end)

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<6::256>>
             )

    refute_receive {:configure, "candidate", "candidate-secret"}
    refute_receive :unexpected_confirmation
    refute_receive :deconfigure
    refute_receive :rfkill_block
    assert Process.alive?(pid)
    assert Store.load(dir) == {:ok, prior}
    assert {:ok, _prior_credential} = Store.credential(dir, binding)
  end

  test "a chosen rollback durably restores the prior marker and sidecar", %{dir: dir} do
    prior_activation_id = <<5::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    assert :ok = Store.save(dir, prior)

    assert :ok =
             Store.put_credential(
               dir,
               Secret.new("prior-secret"),
               %{ssid: "prior", desired_activation_id: prior_activation_id}
             )

    candidate_activation_id = <<7::256>>

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        authority_load_fun: fn _store_dir -> {:ok, prior} end,
        store_save_fun: fn store_dir, record ->
          assert :ok = Store.save(store_dir, record)

          if Map.get(record, :desired_activation_id) == candidate_activation_id,
            do: {:error, :after_durable_commit},
            else: :ok
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, {:persistence_failed, :after_durable_commit}} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 5, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               candidate_activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert Store.load(dir) == {:ok, prior}

    assert {:ok, _prior_credential} =
             Store.credential(dir, %{ssid: "prior", desired_activation_id: prior_activation_id})

    assert :empty =
             Store.credential(dir, %{
               ssid: "candidate",
               desired_activation_id: candidate_activation_id
             })
  end

  test "boot prunes an orphan credential only when owner authority is exactly empty", %{dir: dir} do
    binding = %{ssid: "orphan", desired_activation_id: <<7::256>>}
    assert :ok = Store.put_credential(dir, Secret.new("orphan-secret"), binding)

    _pid = start_manager(dir, compile_default: false)

    assert_receive :rfkill_block
    assert :empty = Store.credential(dir, binding)
    refute File.exists?(Path.join(dir, "current.wifi.credential"))
  end

  test "boot preserves credentials and avoids compile-default mutation when marker authority is unreadable", %{
    dir: dir
  } do
    binding = %{ssid: "prior", desired_activation_id: <<7::256>>}
    assert :ok = Store.put_credential(dir, Secret.new("prior-secret"), binding)
    File.write!(Path.join(dir, "current.wifi"), <<0, 1, 2, 3>>)

    pid = start_manager(dir, compile_default: false)

    refute_receive {:configure, _, _}
    refute_receive :deconfigure
    refute_receive :rfkill_block
    refute_receive :rfkill_unblock
    assert {:ok, _credential} = Store.credential(dir, binding)
    assert WiFiManager.desired_activation_id(pid) == nil
  end

  test "boot loads a secretless desired owner marker without applying or logging a credential", %{dir: dir} do
    activation_id = <<8::256>>

    assert :ok =
             Store.save(dir, %{
               version: 2,
               enabled: true,
               ssid: "candidate",
               desired_activation_id: activation_id
             })

    pid = start_manager(dir, [])

    refute_receive {:configure, _, _}
    refute_receive :deconfigure
    refute_receive :rfkill_block
    refute_receive :rfkill_unblock
    assert WiFiManager.desired_activation_id(pid) == activation_id
  end

  test "failed confirmation rolls back and leaves the prior owner record authoritative", %{dir: dir} do
    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      psk: "prior-secret",
      desired_activation_id: <<1::256>>
    }

    assert :ok = Store.save(dir, prior)
    pid = start_manager(dir, confirm_fun: fn -> {:error, :not_authenticated} end)
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, :not_authenticated} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<2::256>>
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock
    assert Store.load(dir) == {:ok, prior}
    assert WiFiManager.desired_activation_id(pid) == prior.desired_activation_id
  end

  test "rollback onto a sidecar-less secretless marker fails closed without crashing", %{dir: dir} do
    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: <<1::256>>
    }

    assert :ok = Store.save(dir, prior)
    pid = start_manager(dir, confirm_fun: fn -> {:error, :not_authenticated} end)

    refute_receive {:configure, _, _}
    refute_receive :deconfigure
    refute_receive :rfkill_block
    refute_receive :rfkill_unblock

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<2::256>>
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive :deconfigure
    assert_receive :rfkill_block
    assert Process.alive?(pid)
    assert Store.load(dir) == {:ok, prior}
    assert WiFiManager.desired_activation_id(pid) == nil
  end

  test "owner-store failure after confirmation rolls back", %{dir: dir} do
    prior = %{version: 4, enabled: true, ssid: "prior", psk: "prior-secret"}
    assert :ok = Store.save(dir, prior)

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        store_save_fun: fn _dir, _record -> {:error, :disk_full} end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, {:persistence_failed, :disk_full}} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<3::256>>
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock
    assert Store.load(dir) == {:ok, prior}
  end

  test "rollback to empty restores the compile-time WiFi default", %{dir: dir} do
    parent = self()

    pid =
      start_manager(dir,
        compile_default: true,
        confirm_fun: fn -> {:error, :not_authenticated} end,
        reset_to_defaults_fun: fn iface -> send(parent, {:reset_to_defaults, iface}) end
      )

    refute_receive :deconfigure
    refute_receive :rfkill_block

    assert {:error, :not_authenticated} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<3::256>>
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive {:reset_to_defaults, "wlan0"}
    assert_receive :rfkill_unblock
    refute_receive :deconfigure
    refute_receive :rfkill_block
    assert Store.load(dir) == :empty
  end

  test "rollback to empty retries credential cleanup after a partial owner clear", %{dir: dir} do
    activation_id = <<3::256>>

    pid =
      start_manager(dir,
        confirm_fun: fn -> :ok end,
        store_save_fun: fn _store_dir, _record -> {:error, :disk_full} end,
        store_clear_fun: fn _store_dir -> {:error, :credential_delete_failed} end
      )

    assert_receive :rfkill_block

    assert {:error, {:persistence_failed, :disk_full}} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               activation_id
             )

    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive :deconfigure
    assert_receive :rfkill_block
    assert Store.load(dir) == :empty

    assert :empty =
             Store.credential(dir, %{ssid: "candidate", desired_activation_id: activation_id})
  end

  test "confirmation timeout is bounded and rolls back", %{dir: dir} do
    prior = %{version: 4, enabled: false, ssid: nil, psk: nil}
    assert :ok = Store.save(dir, prior)

    pid = start_manager(dir, confirm_fun: fn -> Process.sleep(5_000) end, trial_timeout: 20)
    assert_receive :deconfigure
    assert_receive :rfkill_block

    started = System.monotonic_time(:millisecond)

    assert {:error, :confirmation_timeout} =
             WiFiManager.trial_config(
               pid,
               %{"version" => 1, "enabled" => true, "ssid" => "candidate"},
               Secret.new("candidate-secret"),
               <<3::256>>
             )

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed < 1_000
    assert_receive {:configure, "candidate", "candidate-secret"}
    assert_receive :rfkill_unblock
    assert_receive :deconfigure
    assert_receive :rfkill_block
    assert Store.load(dir) == {:ok, prior}
  end

  test "a Wi-Fi tombstone disables the radio and commits a secretless marker", %{dir: dir} do
    prior_activation_id = <<3::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    assert :ok = Store.save(dir, prior)

    assert :ok =
             Store.put_credential(
               dir,
               Secret.new("prior-secret"),
               %{ssid: "prior", desired_activation_id: prior_activation_id}
             )

    pid = start_manager(dir, [])
    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    activation_id = <<4::256>>
    assert :ok = WiFiManager.apply_desired_tombstone(pid, activation_id)
    assert_receive :deconfigure
    assert_receive :rfkill_block
    refute_receive {:configure, _, _}
    refute_receive :rfkill_unblock

    assert {:ok, persisted} = Store.load(dir)

    assert persisted == %{
             version: 4,
             enabled: false,
             ssid: nil,
             desired_tombstone: true,
             desired_activation_id: activation_id
           }

    refute Map.has_key?(persisted, :psk)
    assert :empty = Store.credential(dir, prior)
    refute File.exists?(Path.join(dir, "current.wifi.credential"))
    assert WiFiManager.desired_activation_id(pid) == activation_id
    refute :sys.get_state(pid) |> inspect() =~ "prior-secret"
  end

  test "an indeterminate tombstone keeps prior credentials until exact authority clears them", %{
    dir: dir
  } do
    prior_activation_id = <<3::256>>

    prior = %{
      version: 4,
      enabled: true,
      ssid: "prior",
      desired_activation_id: prior_activation_id
    }

    assert :ok = Store.save(dir, prior)

    assert :ok =
             Store.put_credential(
               dir,
               Secret.new("prior-secret"),
               %{ssid: "prior", desired_activation_id: prior_activation_id}
             )

    tombstone_activation_id = <<4::256>>
    {:ok, authority} = Agent.start_link(fn -> :readable end)

    authority_load_fun = fn store_dir ->
      case Agent.get(authority, & &1) do
        :readable -> Store.read_authority(store_dir)
        :unreadable -> {:error, :eio}
      end
    end

    pid =
      start_manager(dir,
        authority_load_fun: authority_load_fun,
        store_save_fun: fn store_dir, record ->
          assert :ok = Store.save(store_dir, record)
          Agent.update(authority, fn _current -> :unreadable end)
          {:error, :after_durable_commit}
        end
      )

    assert_receive {:configure, "prior", "prior-secret"}
    assert_receive :rfkill_unblock

    assert {:error, :wifi_authority_indeterminate} =
             WiFiManager.apply_desired_tombstone(pid, tombstone_activation_id)

    assert_receive :deconfigure
    assert_receive :rfkill_block
    assert {:ok, %{desired_activation_id: ^tombstone_activation_id}} = Store.load(dir)
    assert {:ok, _prior_credential} = Store.credential(dir, prior)

    Agent.update(authority, fn _current -> :readable end)

    assert :ok = WiFiManager.reconcile_desired_activation(pid, tombstone_activation_id)
    assert_receive :deconfigure
    assert_receive :rfkill_block
    assert :empty = Store.credential(dir, prior)
    refute File.exists?(Path.join(dir, "current.wifi.credential"))
  end

  test "pure validation rejects secret-bearing public content" do
    assert {:ok, %{version: 1, enabled: true, ssid: "candidate"}} =
             WiFiManager.validate_desired_config(%{
               "version" => 1,
               "enabled" => true,
               "ssid" => "candidate"
             })

    assert {:error, :plaintext_wifi_secret_forbidden} =
             WiFiManager.validate_desired_config(%{
               "version" => 1,
               "enabled" => true,
               "ssid" => "candidate",
               "psk" => "forbidden"
             })
  end

  defp start_manager(dir, extra) do
    parent = self()

    opts =
      [
        name: nil,
        store_dir: dir,
        configure_fun: fn _iface, config, _opts ->
          [network] = config.vintage_net_wifi.networks
          send(parent, {:configure, network.ssid, network.psk})
          :ok
        end,
        deconfigure_fun: fn _iface -> send(parent, :deconfigure) end,
        rfkill_block_fun: fn -> send(parent, :rfkill_block) end,
        rfkill_unblock_fun: fn -> send(parent, :rfkill_unblock) end,
        status_fun: fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end,
        subscribe_fun: fn _property -> :ok end,
        compile_default: false,
        trial_timeout: 100
      ]
      |> Keyword.merge(extra)

    pid = start_supervised!({WiFiManager, opts})

    # Reconciliation runs in handle_continue/2. Synchronize every test with that
    # startup work so scheduler load cannot be mistaken for a missing radio effect.
    _activation_id = WiFiManager.desired_activation_id(pid)
    pid
  end
end
