defmodule RacingOrg.Tracker.Pro.SecureTransport.ChannelClientTest do
  @moduledoc """
  Tests for the gating logic (safe-to-start-idle) and a socket-layer smoke test
  using `Slipstream.SocketTest` (a conceptual server, no real websocket): the
  client connects, joins `device:<fp>`, and on a server `handshake_hello` push
  pushes a `handshake_init` back.
  """
  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  # A per-test KeyStore in a temp dir + a pinned server keypair.
  setup do
    base = Path.join(System.tmp_dir!(), "cc_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    {srv_pub, srv_priv} = identity(<<0xB2>>)
    prev = Application.get_env(:racing_org_tracker, ServerIdentity)
    Application.put_env(:racing_org_tracker, ServerIdentity, public_key: srv_pub)
    on_exit(fn -> restore_env(ServerIdentity, prev) end)

    %{base: base, identity: identity, srv_pub: srv_pub, srv_priv: srv_priv}
  end

  defp identity(byte) do
    seed = :binary.copy(byte, 32)
    {Primitives.ed25519_public_from_secret(seed), seed}
  end

  defp restore_env(key, nil), do: Application.delete_env(:racing_org_tracker, key)
  defp restore_env(key, prev), do: Application.put_env(:racing_org_tracker, key, prev)

  # --- gating: safe to start idle, never connects when not configured ---

  describe "gating / connectable?" do
    test "host/unclaimed device is NOT connectable (stays idle)", %{base: base} do
      # On host the :target is :host and there is no claim marker -> not connectable.
      refute ChannelClient.connectable?(keystore_opts: [base_path: base])
    end

    test "starts and stays idle when not auto-connecting (no crash loop)", %{base: base} do
      pid =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: base]})

      assert Process.alive?(pid)
      # Give it a beat; it must NOT crash or busy-loop.
      Process.sleep(50)
      assert Process.alive?(pid)
    end

    test "idle client polls :recheck and reschedules without crashing", %{base: base} do
      # Provisioning can complete after boot (BootProvisioner is async), so an idle
      # client must keep re-checking connectable?/1 rather than idle forever. With a
      # tiny recheck interval, several timers fire; auto_connect? stays false so it
      # reschedules each time and never connects/crashes.
      pid =
        start_supervised!(
          {ChannelClient, name: nil, auto_connect?: false, recheck_ms: 15, keystore_opts: [base_path: base]}
        )

      Process.sleep(80)
      assert Process.alive?(pid)
    end
  end

  # --- socket-layer smoke test (conceptual server) ---

  describe "handshake over the channel (SocketTest)" do
    test "connects, joins device:<fp>, and answers handshake_hello with handshake_init", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           keystore_opts: [base_path: ctx.base]}
        )

      # Connect + join (the conceptual server accepts).
      connect_and_assert_join(client, ^topic, %{}, :ok)

      # Server (us) builds a real HELLO and pushes it.
      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})

      # The client must push back a valid handshake_init.
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)

      # And the INIT finalizes server-side into a matching session.
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      # When the server confirms with handshake_ok, the client publishes the live
      # session to the holder.
      push(client, topic, "handshake_ok", %{
        "session_id" => Base.encode64(server_session.session_id)
      })

      # Wait for the holder to be populated.
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {:ok, device_session} = SessionHolder.get_current_session(holder)
      assert device_session.session_id == server_session.session_id
      assert device_session.out_key == server_session.in_key
    end

    test "validates the running firmware once the RacingOrg session is live", ctx do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      parent = self()
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           firmware_validator: fn -> send(parent, :firmware_validated) end,
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      assert {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      # The firmware is validated exactly when the device connects to RacingOrg correctly.
      assert_receive :firmware_validated
    end
  end

  # --- remote WiFi management (J5): set_wifi / wifi_status over the channel ---

  describe "set_wifi / wifi_status (SocketTest)" do
    # A fake WiFi collaborator (mirrors the RacingOrg.Tracker.Pro.WiFiManager API surface J5
    # uses) that records apply_config/2 calls to the test process and returns a
    # canned current_status/1 — so no real WiFiManager / VintageNet is needed.
    defmodule FakeWiFi do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}),
           apply_result:
             Keyword.get(opts, :apply_result, {:ok, %{version: 0, enabled: true, ssid: "boat-net", psk: "secret"}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def current_status(server), do: GenServer.call(server, :current_status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_config_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:current_status, _from, state) do
        {:reply, state.status, state}
      end
    end

    defp connect_client(ctx, wifi_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised({FakeWiFi, [parent: self()] ++ wifi_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {FakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, wifi}
    end

    test "server set_wifi (enable) → apply_config called + wifi_status pushed without psk", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:ok, %{version: 2, enabled: true, ssid: "boat-net", psk: "secret"}},
          status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55}
        )

      push(client, topic, "set_wifi", %{
        "ssid" => "boat-net",
        "psk" => "secret",
        "enabled" => true,
        "version" => 2
      })

      # The injected wifi fake's apply_config was called with the server config.
      assert_receive {:apply_config_called, config}
      assert config["ssid"] == "boat-net"
      assert config["version"] == 2
      assert config["enabled"] == true

      # The client reports status back to the server, echoing applied_version.
      assert_push(^topic, "wifi_status", status)
      assert status.applied_version == 2
      assert status.enabled == true
      assert status.ssid == "boat-net"
      assert Map.has_key?(status, :connection)
      assert Map.has_key?(status, :signal)

      # The status NEVER leaks the psk.
      refute Map.has_key?(status, :psk)
      refute Map.has_key?(status, "psk")
    end

    test "server set_wifi (disable) → apply_config called + wifi_status pushed", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:ok, %{version: 3, enabled: false, ssid: nil, psk: nil}},
          status: %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
        )

      push(client, topic, "set_wifi", %{"enabled" => false, "version" => 3})

      assert_receive {:apply_config_called, config}
      assert config["enabled"] == false
      assert config["version"] == 3

      assert_push(^topic, "wifi_status", status)
      assert status.enabled == false
      assert status.applied_version == 3
      refute Map.has_key?(status, :psk)
    end

    test "set_wifi apply error → still pushes status (no crash) and never leaks psk", ctx do
      {client, topic, _wifi} =
        connect_client(ctx,
          apply_result: {:error, :ssid_required},
          status: %{enabled: false, ssid: nil, connection: :disconnected, signal: nil}
        )

      push(client, topic, "set_wifi", %{"enabled" => true, "psk" => "p", "version" => 4})

      assert_receive {:apply_config_called, _config}
      assert_push(^topic, "wifi_status", status)
      assert Map.has_key?(status, :enabled)
      refute Map.has_key?(status, :psk)
      assert Process.alive?(client)
    end

    test "a simulated wlan0 connection-change pushes a fresh wifi_status", ctx do
      {client, topic, _wifi} =
        connect_client(ctx, status: %{enabled: true, ssid: "boat-net", connection: :lan, signal: -60})

      # Drive the VintageNet property-change handler directly (the real subscription
      # is a no-op in test_mode, so we simulate the message it would deliver).
      send(client, {VintageNet, ["interface", "wlan0", "connection"], :disconnected, :lan, %{}})

      assert_push(^topic, "wifi_status", status)
      assert status.connection == :lan
      assert status.enabled == true
      refute Map.has_key?(status, :psk)
    end

    test "pushes an initial wifi_status shortly after a successful handshake", ctx do
      {client, topic, _wifi} =
        connect_client(ctx, status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -50})

      # Complete the handshake so the session goes live, which should trigger an
      # initial status report to the server.
      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)

      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", status)
      assert status.enabled == true
      assert status.ssid == "boat-net"
      refute Map.has_key?(status, :psk)
    end
  end

  # --- per-state tracking config (Phase 5): set_tracking / tracking_status ---

  describe "set_tracking / tracking_status (SocketTest)" do
    # A fake Tracking collaborator mirroring the RacingOrg.Tracker.Pro.Tracking.Config API
    # surface the channel uses: apply_config/2 (records the call) + status/1.
    defmodule FakeTracking do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 0,
               active_state: :race,
               active_rate_hz: 10.0,
               active_damping_seconds: 0.5
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 0}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def tracking_status(server), do: GenServer.call(server, :tracking_status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_tracking_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:tracking_status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_tracking_client(ctx, tracking_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, tracking} = start_supervised({FakeTracking, [parent: self()] ++ tracking_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           tracking: {FakeTracking, tracking},
           tracking_status: {FakeTracking, tracking},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, tracking}
    end

    test "server set_tracking → apply_config called + tracking_status pushed", ctx do
      {client, topic, _tracking} =
        connect_tracking_client(ctx,
          apply_result: {:ok, %{version: 0}},
          status: %{applied_version: 0, active_state: :race, active_rate_hz: 10.0, active_damping_seconds: 0.5}
        )

      push(client, topic, "set_tracking", %{
        "version" => 0,
        "states" => %{
          "pre_race" => %{"damping_seconds" => 2.0, "send_rate_hz" => 1.0},
          "starting" => %{"damping_seconds" => 1.0, "send_rate_hz" => 5.0},
          "race" => %{"damping_seconds" => 0.5, "send_rate_hz" => 10.0}
        }
      })

      assert_receive {:apply_tracking_called, config}
      assert config["version"] == 0
      assert config["states"]["race"]["send_rate_hz"] == 10.0

      assert_push(^topic, "tracking_status", status)
      assert status.applied_version == 0
      assert status.active_state == :race
      assert status.active_rate_hz == 10.0
      assert status.active_damping_seconds == 0.5
      assert Map.has_key?(status, :reported_at)
    end

    test "set_tracking apply error → still pushes status (no crash)", ctx do
      {client, topic, _tracking} =
        connect_tracking_client(ctx,
          apply_result: {:error, :malformed},
          status: %{applied_version: 0, active_state: :pre_race, active_rate_hz: 1.0, active_damping_seconds: 2.0}
        )

      push(client, topic, "set_tracking", %{"version" => 9, "states" => %{}})

      assert_receive {:apply_tracking_called, _config}
      assert_push(^topic, "tracking_status", status)
      assert Map.has_key?(status, :active_state)
      assert Process.alive?(client)
    end
  end

  # --- clock-source policy: set_clock_source / clock_source_status ---

  describe "set_clock_source / clock_source_status (SocketTest)" do
    # A fake ClockSource collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeClockSource do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 2,
               mode: "sensor_priority",
               active_source_sensor_id: "sensor-abc",
               active_source_label: "Masthead GPS",
               active_hw_id: "hw-1",
               active_source_address: "35",
               timebase: "sensor",
               fallback_reason: nil,
               last_gps_time: "2026-06-30T12:00:00.000Z",
               status: "ok"
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 2}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_clock_source_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_clock_source_client(ctx, clock_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, clock} = start_supervised({FakeClockSource, [parent: self()] ++ clock_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           clock_source: {FakeClockSource, clock},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, clock}
    end

    test "server set_clock_source → apply_config called + clock_source_status pushed", ctx do
      {client, topic, _clock} = connect_clock_source_client(ctx, [])

      push(client, topic, "set_clock_source", %{
        "version" => 2,
        "mode" => "sensor_priority",
        "fallback" => "tracker_receive_time",
        "sources" => [
          %{"priority" => 1, "sensor_id" => "sensor-abc", "source_address" => "35", "label" => "Masthead GPS"}
        ]
      })

      assert_receive {:apply_clock_source_called, config}
      assert config["version"] == 2
      assert config["mode"] == "sensor_priority"

      assert_push(^topic, "clock_source_status", status)
      assert status.applied_version == 2
      assert status.mode == "sensor_priority"
      assert status.timebase == "sensor"
      assert status.active_source_sensor_id == "sensor-abc"
      assert status.active_source_label == "Masthead GPS"
      assert status.active_hw_id == "hw-1"
      assert status.active_source_address == "35"
      assert status.fallback_reason == nil
      assert status.last_gps_time == "2026-06-30T12:00:00.000Z"
      assert status.status == "ok"
      assert Map.has_key?(status, :reported_at)
    end

    test "set_clock_source apply error → still pushes status (no crash)", ctx do
      {client, topic, _clock} =
        connect_clock_source_client(ctx,
          apply_result: {:error, :bad_version},
          status: %{
            applied_version: nil,
            mode: "tracker_receive_time",
            timebase: "tracker_receive_time",
            fallback_reason: "default_mode"
          }
        )

      push(client, topic, "set_clock_source", %{"mode" => "sensor_priority"})

      assert_receive {:apply_clock_source_called, _config}
      assert_push(^topic, "clock_source_status", status)
      assert status.mode == "tracker_receive_time"
      assert status.timebase == "tracker_receive_time"
      assert Process.alive?(client)
    end
  end

  # --- calibration policy: set_calibration / calibration_status ---

  describe "set_calibration / calibration_status (SocketTest)" do
    # A fake Calibration.Config collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeCalibration do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status:
             Keyword.get(opts, :status, %{
               applied_version: 3,
               modes: %{
                 "awa_offset" => "auto",
                 "awa_upwash" => "auto",
                 "stw_scale" => "auto",
                 "aws_scale" => "shadow"
               },
               sensors: [
                 %{
                   hardware_identifier: "1A2B",
                   parameter: "awa_offset",
                   state: "applied",
                   value: 2.5,
                   confidence: 0.9,
                   sample_count: 500
                 }
               ],
               status: "ok"
             }),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 3}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_calibration_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    defp connect_calibration_client(ctx, calibration_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, calibration} = start_supervised({FakeCalibration, [parent: self()] ++ calibration_opts})
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           calibration: {FakeCalibration, calibration},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, calibration}
    end

    test "server set_calibration → apply_config called + calibration_status pushed", ctx do
      {client, topic, _calibration} = connect_calibration_client(ctx, [])

      push(client, topic, "set_calibration", %{
        "version" => 3,
        "parameters" => %{"awa_offset" => %{"mode" => "auto"}, "aws_scale" => %{"mode" => "shadow"}},
        "sensors" => [
          %{"hardware_identifier" => "1A2B", "parameter" => "awa_offset", "locked" => true, "value" => 2.5}
        ]
      })

      assert_receive {:apply_calibration_called, config}
      assert config["version"] == 3
      assert config["parameters"]["awa_offset"]["mode"] == "auto"

      assert_push(^topic, "calibration_status", status)
      assert status.applied_version == 3
      assert status.modes["awa_offset"] == "auto"
      assert status.modes["aws_scale"] == "shadow"
      assert [%{hardware_identifier: "1A2B", parameter: "awa_offset", state: "applied"}] = status.sensors
      assert status.status == "ok"
      assert Map.has_key?(status, :reported_at)
      # Allowlist: nothing beyond the contract fields.
      assert Map.keys(status) |> Enum.sort() == [:applied_version, :modes, :reported_at, :sensors, :status]
    end

    test "calibration_status with curve-valued learned entries is JSON-encodable", ctx do
      # A REAL Calibration.Config holding CURVE-valued learned entries (tuple
      # lists internally): the status it reports must already be rendered into
      # JSON-encodable maps, or the channel push would crash the serializer.
      alias RacingOrg.Tracker.Pro.Calibration.Config, as: CalConfig

      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, calibration} = start_supervised({CalConfig, name: nil, store_dir: nil})
      topic = "device:" <> ctx.identity.fingerprint

      entry = %{confidence: 0.9, sample_count: 8, state: "applied"}

      assert :ok =
               CalConfig.put_learned(calibration, "1A2B", "awa_upwash", Map.put(entry, :value, [{5, 3.0}, {9, 1.0}]))

      assert :ok = CalConfig.put_learned(calibration, "3C4D", "stw_scale", Map.put(entry, :value, [{1, 1.05}]))

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           calibration: {CalConfig, calibration},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      push(client, topic, "set_calibration", %{"version" => 1, "parameters" => %{}, "sensors" => []})

      assert_push(^topic, "calibration_status", status)

      assert %{value: [%{center: 5, value: 3.0}, %{center: 9, value: 1.0}]} =
               Enum.find(status.sensors, &(&1.parameter == "awa_upwash"))

      assert %{value: [%{center: 1, gain: 1.05}]} = Enum.find(status.sensors, &(&1.parameter == "stw_scale"))
      assert is_binary(Jason.encode!(status))
    end

    test "set_calibration apply error → still pushes status (no crash)", ctx do
      {client, topic, _calibration} =
        connect_calibration_client(ctx,
          apply_result: {:error, :bad_version},
          status: %{
            applied_version: nil,
            modes: %{
              "awa_offset" => "auto",
              "awa_upwash" => "auto",
              "stw_scale" => "auto",
              "aws_scale" => "shadow"
            },
            sensors: []
          }
        )

      push(client, topic, "set_calibration", %{"parameters" => %{}})

      assert_receive {:apply_calibration_called, _config}
      assert_push(^topic, "calibration_status", status)
      assert status.applied_version == nil
      assert status.sensors == []
      assert Process.alive?(client)
    end
  end

  # --- computed values (Phase 7): set_computed_values / computed_values_status ---

  describe "set_computed_values / computed_values_status (SocketTest)" do
    # A fake Compute.Engine collaborator mirroring the API the channel uses:
    # apply_config/2 (records the call) + status/1.
    defmodule FakeCompute do
      use GenServer

      def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

      @impl true
      def init(opts) do
        {:ok,
         %{
           parent: Keyword.fetch!(opts, :parent),
           status: Keyword.get(opts, :status, %{applied_version: 0, active_count: 2}),
           apply_result: Keyword.get(opts, :apply_result, {:ok, %{version: 0}})
         }}
      end

      def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
      def status(server), do: GenServer.call(server, :status)

      @impl true
      def handle_call({:apply_config, config}, _from, state) do
        send(state.parent, {:apply_computed_called, config})
        {:reply, state.apply_result, state}
      end

      def handle_call(:status, _from, state), do: {:reply, state.status, state}
    end

    # A fake Compute.Broadcaster collaborator: broadcasting?/1 returns a fixed bool.
    defmodule FakeBroadcaster do
      use Agent

      def start_link(opts), do: Agent.start_link(fn -> Keyword.get(opts, :broadcasting?, false) end)
      def broadcasting?(agent), do: Agent.get(agent, & &1)
    end

    defp connect_compute_client(ctx, compute_opts) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, compute} = start_supervised({FakeCompute, [parent: self()] ++ compute_opts})

      {:ok, broadcaster} =
        start_supervised({FakeBroadcaster, broadcasting?: Keyword.get(compute_opts, :broadcasting?, false)})

      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           compute: {FakeCompute, compute},
           compute_broadcaster: {FakeBroadcaster, broadcaster},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)
      {client, topic, compute}
    end

    test "server set_computed_values → apply_config called + computed_values_status pushed", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:ok, %{version: 3}},
          status: %{applied_version: 3, active_count: 2}
        )

      push(client, topic, "set_computed_values", %{
        "version" => 3,
        "values" => [
          %{
            "id" => "abc",
            "name" => "AWS x2",
            "definition_type" => "expression",
            "library_key" => nil,
            "input_bindings" => %{},
            "rpn" => [%{"signal" => "apparent_wind_speed"}, %{"const" => 2.0}, %{"op" => "*"}],
            "signals" => ["apparent_wind_speed"],
            "output_pgn" => 128_259,
            "output_field" => "speed_water_referenced",
            "output_reference" => nil,
            "output_unit" => "m/s",
            "output_instance" => nil,
            "damping_seconds" => 0.5,
            "broadcast_rate_hz" => 2.0,
            "broadcast_enabled" => true,
            "stream_to_backend" => true
          }
        ]
      })

      assert_receive {:apply_computed_called, config}
      assert config["version"] == 3
      assert [value] = config["values"]
      assert value["id"] == "abc"

      assert_push(^topic, "computed_values_status", status)
      assert status.applied_version == 3
      assert status.active_count == 2
      assert Map.has_key?(status, :reported_at)
      # broadcasting reflects the Compute.Broadcaster (default fake: not broadcasting).
      assert status.broadcasting == false
    end

    test "computed_values_status reports broadcasting=true when the broadcaster is active", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:ok, %{version: 1}},
          status: %{applied_version: 1, active_count: 1},
          broadcasting?: true
        )

      push(client, topic, "set_computed_values", %{"version" => 1, "values" => []})

      assert_receive {:apply_computed_called, _config}
      assert_push(^topic, "computed_values_status", status)
      assert status.broadcasting == true
    end

    test "set_computed_values apply error → still pushes status (no crash)", ctx do
      {client, topic, _compute} =
        connect_compute_client(ctx,
          apply_result: {:error, :malformed},
          status: %{applied_version: 0, active_count: 0}
        )

      push(client, topic, "set_computed_values", %{"version" => 9, "values" => "bad"})

      assert_receive {:apply_computed_called, _config}
      assert_push(^topic, "computed_values_status", status)
      assert Map.has_key?(status, :active_count)
      assert Map.has_key?(status, :applied_version)
      assert Process.alive?(client)
    end
  end

  # --- computed-value streamback (Phase 10): send_computed_values_data/2 ---

  describe "send_computed_values_data (SocketTest)" do
    # Bring a client all the way to a LIVE session (handshake complete) so a
    # subsequent streamback push has a joined topic + session to push over. A fake
    # WiFi collaborator is injected so the post-handshake :report_wifi_status read does
    # not depend on a real (target-only) WiFiManager.
    # A minimal WiFi collaborator: current_status/1 returns a canned status so the
    # post-handshake :report_wifi_status read never depends on a real WiFiManager.
    defmodule StreamFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(StreamFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {StreamFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      # handshake_ok triggers an initial :report_wifi_status push; drain it so the
      # client isn't blocked on that synchronous push when the streamback arrives.
      assert_push(^topic, "wifi_status", _wifi)

      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes computed_values_data over the channel when a session is live", ctx do
      {client, topic} = connect_live(ctx)

      values = [%{id: "abc", value: 12.3}, %{id: "def", value: 4.0}]
      assert :ok = ChannelClient.send_computed_values_data(client, values)

      assert_push(^topic, "computed_values_data", payload)
      assert payload.values == values
      # No batch/per-sample timestamp — the server stamps receipt time.
      refute Map.has_key?(payload, :at)
    end

    test "no-ops (no push) when there is no live session", ctx do
      # An idle client (never connected/handshaked) has no joined topic — streamback
      # must be a best-effort no-op, exactly like telemetry is dropped with no session.
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      assert :ok = ChannelClient.send_computed_values_data(client, [%{id: "abc", value: 1.0}])
      # The conceptual server must NOT receive any streamback push.
      refute_push("computed_values_data", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      # Best-effort: a streamback to a dead/unregistered name never raises.
      assert :ok = ChannelClient.send_computed_values_data(:no_such_channel_client, [%{id: "x", value: 1.0}])
    end
  end

  # --- route-deviation recalc (P3): request_route_recalc over the channel ---

  describe "request_route_recalc (SocketTest)" do
    # Bring a client to a LIVE session, reusing the streamback fakes/flow.
    defmodule RecalcFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_recalc(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(RecalcFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {RecalcFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes request_route_recalc with the current position when a session is live", ctx do
      {client, topic} = connect_live_recalc(ctx)

      assert :ok = ChannelClient.request_route_recalc(client, {42.5, -70.83})

      assert_push(^topic, "request_route_recalc", payload)
      assert payload.position.latitude == 42.5
      assert payload.position.longitude == -70.83
    end

    test "pushes request_route_recalc with no position when none is available", ctx do
      {client, topic} = connect_live_recalc(ctx)

      assert :ok = ChannelClient.request_route_recalc(client, nil)

      assert_push(^topic, "request_route_recalc", payload)
      # The server resolves the device→active race + position from telemetry, so an
      # absent position is a valid (empty) request, never a crash.
      refute Map.has_key?(payload, :position)
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      assert :ok = ChannelClient.request_route_recalc(client, {42.0, -71.0})
      refute_push("request_route_recalc", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      assert :ok = ChannelClient.request_route_recalc(:no_such_channel_client, {42.0, -71.0})
    end
  end

  # --- sailed-polar streamback (Phase 4): send_sailed_polar_update/2 ---

  describe "send_sailed_polar_update (SocketTest)" do
    defmodule SailedFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_sailed(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(SailedFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {SailedFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes sailed_polar_update over the channel when a session is live", ctx do
      {client, topic} = connect_live_sailed(ctx)

      update = %{
        boat_identifier: "boat-42",
        seq: 7,
        cells: [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 12}]
      }

      assert :ok = ChannelClient.send_sailed_polar_update(client, update)

      assert_push(^topic, "sailed_polar_update", payload)
      assert payload.boat_identifier == "boat-42"
      assert payload.seq == 7
      assert [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 12}] = payload.cells
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      update = %{
        boat_identifier: "boat-42",
        seq: 1,
        cells: [%{tws_mps: 4.9, twa_deg: 52.5, boat_speed_mps: 4.0, count: 1}]
      }

      assert :ok = ChannelClient.send_sailed_polar_update(client, update)
      refute_push("sailed_polar_update", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      update = %{boat_identifier: "boat-42", seq: 1, cells: []}
      assert :ok = ChannelClient.send_sailed_polar_update(:no_such_channel_client, update)
    end
  end

  # --- calibration streamback (auto-calibration): send_calibration_update/2 ---

  describe "send_calibration_update (SocketTest)" do
    defmodule CalibrationFakeWiFi do
      use Agent

      def start_link(_opts),
        do: Agent.start_link(fn -> %{enabled: false, ssid: nil, connection: :disconnected, signal: nil} end)

      def current_status(agent), do: Agent.get(agent, & &1)
    end

    defp connect_live_calibration(ctx) do
      {:ok, holder} = start_supervised({SessionHolder, name: nil})
      {:ok, wifi} = start_supervised(CalibrationFakeWiFi)
      topic = "device:" <> ctx.identity.fingerprint

      client =
        start_supervised!(
          {ChannelClient,
           name: nil,
           auto_connect?: true,
           test_mode?: true,
           url: "wss://test.local/device_socket/websocket",
           session_holder: holder,
           wifi: {CalibrationFakeWiFi, wifi},
           keystore_opts: [base_path: ctx.base]}
        )

      connect_and_assert_join(client, ^topic, %{}, :ok)

      {:ok, hello_wire, rstate} =
        Handshake.responder_hello(
          server_identity_private: ctx.srv_priv,
          server_identity_public: ctx.srv_pub,
          device_identity_public: ctx.identity.public_key,
          epoch: 0
        )

      push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
      assert_push(^topic, "handshake_init", %{"init" => init_b64})
      {:ok, init_wire} = Base.decode64(init_b64)
      {:ok, server_session} = Handshake.responder_finalize(rstate, init_wire)
      push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})

      assert_push(^topic, "wifi_status", _wifi)
      assert eventually(fn -> SessionHolder.live?(holder) end)
      {client, topic}
    end

    test "pushes calibration_update over the channel when a session is live", ctx do
      {client, topic} = connect_live_calibration(ctx)

      update = %{
        boat_identifier: "boat-42",
        seq: 3,
        entries: [
          %{
            hardware_identifier: "1A2B",
            parameter: "awa_offset",
            value: 2.5,
            confidence: 1.0,
            sample_count: 9,
            state: "applied",
            residual: 0.1
          },
          %{
            hardware_identifier: "3C4D",
            parameter: "stw_scale",
            value: 1.05,
            confidence: 0.9,
            sample_count: 7,
            state: "applied",
            residual: 0.01,
            curve: [%{center: 1, gain: 1.05}]
          }
        ]
      }

      assert :ok = ChannelClient.send_calibration_update(client, update)

      assert_push(^topic, "calibration_update", payload)
      assert payload.boat_identifier == "boat-42"
      assert payload.seq == 3
      assert [awa, stw] = payload.entries
      assert awa.parameter == "awa_offset"
      assert awa.state == "applied"
      assert stw.parameter == "stw_scale"
      assert stw.curve == [%{center: 1, gain: 1.05}]
    end

    test "an empty-entries update is not pushed", ctx do
      {client, _topic} = connect_live_calibration(ctx)

      assert :ok = ChannelClient.send_calibration_update(client, %{boat_identifier: "boat-42", seq: 1, entries: []})
      refute_push("calibration_update", _payload, 50)
    end

    test "no-ops (no push) when there is no live session", ctx do
      client =
        start_supervised!({ChannelClient, name: nil, auto_connect?: false, keystore_opts: [base_path: ctx.base]})

      update = %{
        boat_identifier: "boat-42",
        seq: 1,
        entries: [
          %{
            hardware_identifier: "1A2B",
            parameter: "awa_offset",
            value: 2.5,
            confidence: 1.0,
            sample_count: 9,
            state: "applied",
            residual: 0.1
          }
        ]
      }

      assert :ok = ChannelClient.send_calibration_update(client, update)
      refute_push("calibration_update", _payload, 50)
      assert Process.alive?(client)
    end

    test "no-ops safely when the target process is not running" do
      update = %{boat_identifier: "boat-42", seq: 1, entries: []}
      assert :ok = ChannelClient.send_calibration_update(:no_such_channel_client, update)
    end
  end

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() ->
        true

      retries <= 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, retries - 1)
    end
  end
end
