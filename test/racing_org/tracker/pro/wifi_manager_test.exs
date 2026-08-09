defmodule RacingOrg.Tracker.Pro.WiFiManagerTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.WiFi.Store
  alias RacingOrg.Tracker.Pro.WiFiManager
  alias RacingOrg.Tracker.Pro.WiFiManager.Secret

  setup do
    dir = Path.join(System.tmp_dir!(), "nn_wifi_mgr_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  # Build an injectable-side-effects opts list that forwards every effect to the
  # test process as a tagged message, so we can assert exactly what was applied.
  defp recording_opts(dir, extra) do
    parent = self()

    [
      name: nil,
      store_dir: dir,
      configure_fun: fn iface, config, opts -> send(parent, {:configure, iface, config, opts}) end,
      deconfigure_fun: fn iface -> send(parent, {:deconfigure, iface}) end,
      rfkill_block_fun: fn -> send(parent, :rfkill_block) end,
      rfkill_unblock_fun: fn -> send(parent, :rfkill_unblock) end,
      status_fun: fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end,
      subscribe_fun: fn _property -> :ok end,
      compile_default: false
    ]
    |> Keyword.merge(extra)
  end

  defp start(opts) do
    pid = start_supervised!({WiFiManager, opts})
    pid
  end

  describe "boot reconciliation" do
    test "persisted state PRESENT takes precedence over the compile default", %{dir: dir} do
      # Persist a runtime "enable" while compile default is false: it must be applied,
      # NOT re-blocked at boot.
      Store.save(dir, %{version: 5, enabled: true, ssid: "boat-net", psk: "pw"})

      start(recording_opts(dir, compile_default: false))

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
      refute_received :rfkill_block
    end

    test "persisted :empty + compile_default=false → rfkill block (mirror WiFiPower)", %{dir: dir} do
      start(recording_opts(dir, compile_default: false))

      assert_receive :rfkill_block
      refute_received {:configure, _, _, _}
    end

    test "persisted :empty + compile_default=true → no rfkill block", %{dir: dir} do
      start(recording_opts(dir, compile_default: true))

      refute_received :rfkill_block
      refute_received {:deconfigure, _}
    end
  end

  test "a manager crash cannot return an inline PSK in the caller exit reason" do
    server =
      spawn(fn ->
        receive do
          {:"$gen_call", _from, {:apply_config, %{"psk" => "caller-visible-secret"}}} ->
            exit(:simulated_crash)
        end
      end)

    result = WiFiManager.apply_config(server, %{"psk" => "caller-visible-secret"})

    assert result == {:error, :wifi_manager_unavailable}

    rendered = result |> then(&:io_lib.format(~c"~p", [&1])) |> IO.iodata_to_binary()
    refute rendered =~ "caller-visible-secret"
  end

  describe "apply_config/2 enable" do
    test "configures wlan0, unblocks rfkill, and persists state + version", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: false))
      # drain boot effects
      assert_receive :rfkill_block

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{
                 "version" => 1,
                 "enabled" => true,
                 "ssid" => "boat-net",
                 "psk" => "secret"
               })

      assert applied.enabled == true
      assert applied.ssid == "boat-net"
      assert applied.version == 1

      assert_receive {:configure, "wlan0", config, opts}
      assert config.type == VintageNetWiFi
      assert [%{ssid: "boat-net", psk: "secret", key_mgmt: :wpa_psk}] = config.vintage_net_wifi.networks
      assert Keyword.get(opts, :persist) == false
      assert_receive :rfkill_unblock

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.enabled == true
      assert persisted.ssid == "boat-net"
      assert persisted.psk == "secret"
      assert persisted.version == 1
    end

    test "a legacy enable prunes a superseded Desired State credential", %{dir: dir} do
      activation_id = <<1::256>>
      binding = %{ssid: "desired-net", desired_activation_id: activation_id}

      assert :ok =
               Store.save(dir, %{
                 version: 5,
                 enabled: true,
                 ssid: "desired-net",
                 desired_activation_id: activation_id
               })

      assert :ok = Store.put_credential(dir, Secret.new("desired-secret"), binding)

      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      assert {:ok, %{enabled: true, ssid: "legacy-net", psk: "legacy-secret"}} =
               WiFiManager.apply_config(pid, %{
                 "version" => 6,
                 "enabled" => true,
                 "ssid" => "legacy-net",
                 "psk" => "legacy-secret"
               })

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
      assert :empty = Store.credential(dir, binding)
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end

    test "atom keys are accepted and normalized", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{version: 2, enabled: true, ssid: "s", psk: "p"})

      assert applied.ssid == "s"
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
    end

    test "enable without ssid returns {:error, :ssid_required} and applies nothing", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:error, :ssid_required} =
               WiFiManager.apply_config(pid, %{"version" => 1, "enabled" => true, "psk" => "p"})

      refute_received {:configure, _, _, _}
      refute_received :rfkill_unblock
      assert :empty = Store.load(dir)
    end
  end

  describe "apply_config/2 disable" do
    test "a legacy disable prunes a superseded Desired State credential", %{dir: dir} do
      activation_id = <<1::256>>
      binding = %{ssid: "desired-net", desired_activation_id: activation_id}

      assert :ok =
               Store.save(dir, %{
                 version: 5,
                 enabled: true,
                 ssid: "desired-net",
                 desired_activation_id: activation_id
               })

      assert :ok = Store.put_credential(dir, Secret.new("desired-secret"), binding)

      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      assert {:ok, %{enabled: false}} =
               WiFiManager.apply_config(pid, %{"version" => 6, "enabled" => false})

      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block
      assert :empty = Store.credential(dir, binding)
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end

    test "a failed legacy marker commit restores the prior radio and credential authority", %{
      dir: dir
    } do
      activation_id = <<1::256>>
      binding = %{ssid: "desired-net", desired_activation_id: activation_id}

      prior = %{
        version: 5,
        enabled: true,
        ssid: "desired-net",
        desired_activation_id: activation_id
      }

      assert :ok = Store.save(dir, prior)
      assert :ok = Store.put_credential(dir, Secret.new("desired-secret"), binding)

      store_save_fun = fn store_dir, record ->
        if Map.get(record, :desired_activation_id) == activation_id,
          do: Store.save(store_dir, record),
          else: {:error, :disk_full}
      end

      pid = start(recording_opts(dir, compile_default: false, store_save_fun: store_save_fun))
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      assert {:error, {:persistence_failed, :disk_full}} =
               WiFiManager.apply_config(pid, %{"version" => 6, "enabled" => false})

      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block
      assert_receive {:configure, "wlan0", restored, _opts}
      assert [%{ssid: "desired-net", psk: "desired-secret"}] = restored.vintage_net_wifi.networks
      assert_receive :rfkill_unblock
      assert Store.load(dir) == {:ok, prior}
      assert {:ok, _prior_credential} = Store.credential(dir, binding)
    end

    test "deconfigures wlan0, blocks rfkill, and persists disabled state", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: true))

      assert {:ok, applied} =
               WiFiManager.apply_config(pid, %{"version" => 1, "enabled" => false})

      assert applied.enabled == false
      assert applied.version == 1

      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block

      assert {:ok, persisted} = Store.load(dir)
      assert persisted.enabled == false
      assert persisted.version == 1
    end
  end

  describe "idempotency on durable authority" do
    test "apply_config with version <= durable owner version is a no-op", %{dir: dir} do
      Store.save(dir, %{version: 10, enabled: true, ssid: "boat-net", psk: "pw"})
      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:configure, "wlan0", _, _}
      assert_receive :rfkill_unblock

      # Equal version → no-op
      assert {:ok, :unchanged} =
               WiFiManager.apply_config(pid, %{"version" => 10, "enabled" => false})

      # Lower version → no-op
      assert {:ok, :unchanged} =
               WiFiManager.apply_config(pid, %{"version" => 9, "enabled" => false})

      refute_received {:configure, _, _, _}
      refute_received {:deconfigure, _}
      refute_received :rfkill_block
      refute_received :rfkill_unblock
    end

    test "same-version retry rechecks authority after an indeterminate marker write", %{dir: dir} do
      prior = %{version: 5, enabled: true, ssid: "prior", psk: "prior-secret"}
      assert :ok = Store.save(dir, prior)

      {:ok, reads} = Agent.start_link(fn -> 0 end)
      {:ok, writes} = Agent.start_link(fn -> 0 end)

      authority_load_fun = fn store_dir ->
        read = Agent.get_and_update(reads, fn count -> {count + 1, count + 1} end)

        if read == 3,
          do: {:error, :eio},
          else: Store.read_authority(store_dir)
      end

      store_save_fun = fn store_dir, record ->
        write = Agent.get_and_update(writes, fn count -> {count + 1, count + 1} end)
        if write == 1, do: {:error, :disk_full}, else: Store.save(store_dir, record)
      end

      pid =
        start(
          recording_opts(dir,
            authority_load_fun: authority_load_fun,
            store_save_fun: store_save_fun,
            compile_default: false
          )
        )

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      candidate = %{"version" => 6, "enabled" => false}

      assert {:error, :wifi_authority_indeterminate} = WiFiManager.apply_config(pid, candidate)
      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block
      assert Store.load(dir) == {:ok, prior}

      assert {:ok, %{version: 6, enabled: false}} = WiFiManager.apply_config(pid, candidate)
      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block
      assert {:ok, %{version: 6, enabled: false}} = Store.load(dir)
    end

    test "same-version retry completes credential cleanup for the exact committed marker", %{
      dir: dir
    } do
      prior = %{version: 5, enabled: true, ssid: "prior", psk: "prior-secret"}
      assert :ok = Store.save(dir, prior)
      {:ok, cleanup} = Agent.start_link(fn -> :disarmed end)

      credential_save_fun = fn store_dir, secret, binding ->
        disposition =
          Agent.get_and_update(cleanup, fn
            :armed when is_nil(secret) -> {:fail, :failed}
            state -> {:ok, state}
          end)

        if disposition == :fail,
          do: {:error, :eio},
          else: Store.put_credential(store_dir, secret, binding)
      end

      pid = start(recording_opts(dir, credential_save_fun: credential_save_fun, compile_default: false))
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      stale_binding = %{ssid: "stale", desired_activation_id: <<1::256>>}
      assert :ok = Store.put_credential(dir, Secret.new("stale-secret"), stale_binding)
      Agent.update(cleanup, fn _state -> :armed end)

      candidate = %{"version" => 6, "enabled" => false}

      assert {:error, :wifi_authority_indeterminate} = WiFiManager.apply_config(pid, candidate)
      assert {:ok, %{version: 6, enabled: false}} = Store.load(dir)
      assert {:ok, _stale_secret} = Store.credential(dir, stale_binding)

      assert {:ok, :unchanged} = WiFiManager.apply_config(pid, candidate)
      assert :empty = Store.credential(dir, stale_binding)
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end
  end

  describe "legacy authority repair" do
    test "an inline-PSK owner ignores an unrelated corrupt sidecar", %{dir: dir} do
      prior = %{version: 5, enabled: true, ssid: "prior", psk: "prior-secret"}
      assert :ok = Store.save(dir, prior)

      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock

      File.write!(Path.join(dir, "current.wifi.credential"), <<0, 1, 2, 3>>)

      assert {:ok, %{version: 6, enabled: false}} =
               WiFiManager.apply_config(pid, %{"version" => 6, "enabled" => false})

      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end

    test "a disabled owner ignores an unrelated corrupt sidecar", %{dir: dir} do
      prior = %{version: 5, enabled: false, ssid: nil}
      assert :ok = Store.save(dir, prior)

      pid = start(recording_opts(dir, compile_default: false))
      assert_receive {:deconfigure, "wlan0"}
      assert_receive :rfkill_block

      File.write!(Path.join(dir, "current.wifi.credential"), <<0, 1, 2, 3>>)

      assert {:ok, %{version: 6, enabled: true, ssid: "candidate"}} =
               WiFiManager.apply_config(pid, %{
                 "version" => 6,
                 "enabled" => true,
                 "ssid" => "candidate",
                 "psk" => "candidate-secret"
               })

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end

    test "a complete authenticated legacy config replaces unreadable owner authority", %{dir: dir} do
      pid = start(recording_opts(dir, compile_default: false))
      assert_receive :rfkill_block

      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "current.wifi"), <<0, 1, 2, 3>>)
      File.write!(Path.join(dir, "current.wifi.credential"), <<4, 5, 6, 7>>)

      assert {:ok, %{version: 6, enabled: true, ssid: "candidate"}} =
               WiFiManager.apply_config(pid, %{
                 "version" => 6,
                 "enabled" => true,
                 "ssid" => "candidate",
                 "psk" => "candidate-secret"
               })

      assert_receive {:configure, "wlan0", _config, _opts}
      assert_receive :rfkill_unblock
      assert {:ok, %{version: 6, enabled: true, ssid: "candidate"}} = Store.load(dir)
      refute File.exists?(Path.join(dir, "current.wifi.credential"))
    end
  end

  describe "current_status/1" do
    test "reads the injected status_fun", %{dir: dir} do
      status = %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}
      pid = start(recording_opts(dir, compile_default: true, status_fun: fn -> status end))

      assert ^status = WiFiManager.current_status(pid)
    end
  end
end
