defmodule RacingOrg.Tracker.Pro.E2E.LegacyRolloutCompatTest do
  @moduledoc """
  Chained end-to-end legacy rollout compatibility scenario: a device incarnation
  that NEVER establishes v1 desired-state authority (a legacy device talking to
  the new backend) keeps its outputs and its legacy control flows fully working
  while the new desired-state gate machinery sits closed and untouched.

  The chain, in order, on one incarnation:

    1. Boot: an isolated OperationalGate starts closed with no authority marker;
       the legacy carve-out keeps `output_permitted?/1` (and the OutputFence
       over it) true even though the gate is closed.
    2. Legacy negotiation: a `control_offer: :legacy` ChannelClient connects and
       joins advertising ONLY its fingerprint — no `control_versions` /
       `desired_state_versions` capability parameters.
    3. Legacy session: the full secure-transport handshake completes, the
       session goes live in the SessionHolder, the initial `wifi_status`
       streams, and no `control_v1` readiness is ever produced or required.
    4. Legacy control: server-pushed `set_wifi` applies through the injected
       WiFi collaborator and reports `wifi_status` back (never leaking the
       psk); a simulated wlan0 change pushes a fresh `wifi_status`.
    5. The whole time: the gate stays closed, no authority is ever recorded,
       output stays permitted — including across an explicit `close/1` — and
       the client stays alive.
    6. Epilogue (contrast, freezing the carve-out boundary): only when the test
       itself simulates a first v1 activation by recording authority does the
       same closed gate fence output — and even then the legacy channel keeps
       operating; the fence governs outputs, not legacy control.

  Process boundaries: everything device-side is REAL and chained in-process —
  the ChannelClient Slipstream state machine (test_mode transport), the
  SessionHolder, the on-disk KeyStore, the Ed25519/secure-session handshake
  crypto, and a live OperationalGate GenServer registered through the shared
  AuthorityRegistry under an ISOLATED persistent_term key. The chain stops at
  three seams: the backend is the Slipstream.SocketTest conceptual server
  driven by this test process (no real websocket/Phoenix/network); WiFi
  hardware is a fake collaborator recording `apply_config/2` calls (no
  VintageNet); and output hot paths are represented by the OutputFence
  predicate over the isolated gate key (no real telemetry/NMEA emitters). The
  DesiredState.Manager is deliberately never started — its absence IS the
  legacy scenario under test.
  """

  use Slipstream.SocketTest

  alias RacingOrg.Tracker.Pro.DesiredState.OperationalGate
  alias RacingOrg.Tracker.Pro.DesiredState.OutputFence
  alias RacingOrg.Tracker.Pro.SecureTransport.ChannelClient
  alias RacingOrg.Tracker.Pro.SecureTransport.Handshake
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.Primitives
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  # Mirrors the WiFiManager API surface the ChannelClient uses; records
  # apply_config/2 calls to the test process and returns a canned status, so no
  # real WiFiManager / VintageNet is needed. All values are synthetic.
  defmodule FakeWiFi do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         parent: Keyword.fetch!(opts, :parent),
         status: Keyword.fetch!(opts, :status),
         apply_result: Keyword.fetch!(opts, :apply_result)
       }}
    end

    def apply_config(server, config), do: GenServer.call(server, {:apply_config, config})
    def current_status(server), do: GenServer.call(server, :current_status)

    @impl true
    def handle_call({:apply_config, config}, _from, state) do
      send(state.parent, {:apply_config_called, config})
      {:reply, state.apply_result, state}
    end

    def handle_call(:current_status, _from, state), do: {:reply, state.status, state}
  end

  # Per-test KeyStore in a temp dir + a pinned server keypair (the
  # channel_client_test harness pattern), plus an OperationalGate on an
  # ISOLATED term_key — never the default persistent_term key (shared test VM).
  setup do
    base = Path.join(System.tmp_dir!(), "legacy_rollout_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    {:ok, identity} = KeyStore.load_or_generate(base_path: base)

    srv_seed = :binary.copy(<<0xB2>>, 32)
    srv_pub = Primitives.ed25519_public_from_secret(srv_seed)
    prev = Application.get_env(:racing_org_tracker_pro, ServerIdentity)
    Application.put_env(:racing_org_tracker_pro, ServerIdentity, public_key: srv_pub)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:racing_org_tracker_pro, ServerIdentity)
        prev -> Application.put_env(:racing_org_tracker_pro, ServerIdentity, prev)
      end
    end)

    term_key = {__MODULE__, make_ref()}
    {:ok, gate} = OperationalGate.start_link(name: nil, term_key: term_key, controller: self())

    on_exit(fn ->
      stop_if_alive(gate)
      OperationalGate.clear_authority_established(term_key)
      :persistent_term.erase(term_key)
    end)

    %{
      base: base,
      identity: identity,
      srv_pub: srv_pub,
      srv_priv: srv_seed,
      gate: gate,
      term_key: term_key
    }
  end

  test "a legacy incarnation that never establishes v1 authority keeps outputs and legacy control flows working end to end",
       ctx do
    fence = fn -> OperationalGate.output_permitted?(ctx.term_key) end

    # -- Phase 1: boot — closed gate, no authority marker, outputs permitted.
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    refute OperationalGate.authority_established?(ctx.term_key)
    assert OperationalGate.output_permitted?(ctx.term_key)
    assert OutputFence.permitted?(fence)

    # -- Phase 2: legacy negotiation — fingerprint only, no capability params.
    {:ok, holder} = start_supervised({SessionHolder, name: nil})

    {:ok, wifi} =
      start_supervised(
        {FakeWiFi,
         parent: self(),
         status: %{enabled: true, ssid: "boat-net", connection: :internet, signal: -55},
         apply_result: {:ok, %{version: 2, enabled: true, ssid: "boat-net", psk: "synthetic-not-a-credential"}}}
      )

    topic = "device:" <> ctx.identity.fingerprint

    client =
      start_supervised!(
        {ChannelClient,
         name: nil,
         auto_connect?: true,
         test_mode?: true,
         control_offer: :legacy,
         url: "wss://test.local/device_socket/websocket",
         session_holder: holder,
         wifi: {FakeWiFi, wifi},
         firmware_validator: fn -> :ok end,
         keystore_opts: [base_path: ctx.base]}
      )

    assert eventually(fn -> not is_nil(:sys.get_state(client).channel_config) end)
    socket = :sys.get_state(client)

    assert URI.decode_query(socket.channel_config.uri.query) ==
             %{"fingerprint" => ctx.identity.fingerprint}

    assert socket.assigns.control_offer == :legacy
    assert socket.assigns.control_selection == nil

    connect_and_assert_join(client, ^topic, %{}, :ok)

    # -- Phase 3: legacy handshake — the session goes live, wifi_status streams,
    # and no control_v1 readiness is produced or required.
    server_session = complete_handshake(client, topic, ctx)
    assert_push(^topic, "wifi_status", _initial_status, _ref, 2_000)
    assert eventually(fn -> SessionHolder.live?(holder) end)
    assert {:ok, device_session} = SessionHolder.get_current_session(holder)
    assert device_session.session_id == server_session.session_id
    refute_push(^topic, "control_v1", _readiness, 50)
    refute :sys.get_state(client).assigns.control_ready?

    # -- Phase 4: legacy control flow — server-pushed set_wifi applies through
    # the injected collaborator and reports wifi_status back without the psk.
    push(client, topic, "set_wifi", %{
      "ssid" => "boat-net",
      "psk" => "synthetic-not-a-credential",
      "enabled" => true,
      "version" => 2
    })

    assert_receive {:apply_config_called, config}, 2_000
    assert config["ssid"] == "boat-net"
    assert config["version"] == 2
    assert config["enabled"] == true

    assert_push(^topic, "wifi_status", set_wifi_status, _ref, 2_000)
    assert set_wifi_status.applied_version == 2
    refute Map.has_key?(set_wifi_status, :psk)
    refute Map.has_key?(set_wifi_status, "psk")

    # A simulated wlan0 connection change keeps streaming wifi_status — normal
    # live legacy operation.
    send(client, {VintageNet, ["interface", "wlan0", "connection"], :disconnected, :lan, %{}})
    assert_push(^topic, "wifi_status", _refreshed_status, _ref, 2_000)

    # -- Phase 5: the entire legacy session never touched the gate machinery.
    refute OperationalGate.authority_established?(ctx.term_key)
    refute OperationalGate.open?(ctx.term_key)
    assert OperationalGate.status(ctx.gate) == :closed
    assert OperationalGate.output_permitted?(ctx.term_key)
    assert OutputFence.permitted?(fence)

    # Even an EXPLICIT close keeps the legacy carve-out: no authority was ever
    # recorded, so the closed gate still permits output.
    assert :ok = OperationalGate.close(ctx.gate)
    assert OperationalGate.status(ctx.gate) == :closed
    assert OperationalGate.output_permitted?(ctx.term_key)
    assert OutputFence.permitted?(fence)

    # The device remains fully operational after all of that.
    assert Process.alive?(client)
    assert SessionHolder.live?(holder)
    send(client, {VintageNet, ["interface", "wlan0", "connection"], :lan, :internet, %{}})
    assert_push(^topic, "wifi_status", _post_close_status, _ref, 2_000)

    # -- Phase 6 (contrast): output stayed permitted BECAUSE no authority was
    # ever established. The moment the test simulates a first v1 activation by
    # recording authority, the same closed gate fences output — while the
    # legacy channel itself keeps operating untouched.
    assert :ok = OperationalGate.record_authority_established(ctx.term_key)
    assert OperationalGate.authority_established?(ctx.term_key)
    refute OperationalGate.output_permitted?(ctx.term_key)
    refute OutputFence.permitted?(fence)

    send(client, {VintageNet, ["interface", "wlan0", "connection"], :internet, :lan, %{}})
    assert_push(^topic, "wifi_status", _fenced_epoch_status, _ref, 2_000)
    assert Process.alive?(client)
    assert SessionHolder.live?(holder)
  end

  # The channel_client_test handshake harness: the conceptual server builds a
  # real HELLO, verifies the client's INIT, and confirms with handshake_ok.
  defp complete_handshake(client, topic, ctx) do
    {:ok, hello_wire, responder_state} =
      Handshake.responder_hello(
        server_identity_private: ctx.srv_priv,
        server_identity_public: ctx.srv_pub,
        device_identity_public: ctx.identity.public_key,
        epoch: 0
      )

    push(client, topic, "handshake_hello", %{"hello" => Base.encode64(hello_wire)})
    assert_push(^topic, "handshake_init", %{"init" => init_b64}, _ref, 2_000)
    {:ok, init_wire} = Base.decode64(init_b64)
    {:ok, server_session} = Handshake.responder_finalize(responder_state, init_wire)

    push(client, topic, "handshake_ok", %{"session_id" => Base.encode64(server_session.session_id)})
    server_session
  end

  defp stop_if_alive(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
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
