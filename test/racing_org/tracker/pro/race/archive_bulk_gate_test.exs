defmodule RacingOrg.Tracker.Pro.Race.ArchiveBulkGateTest do
  @moduledoc """
  The post-race bulk upload trigger's DEFAULT gate (`Archive`'s `default_bulk_upload/1`).

  After removing the redundant `:bulk_upload_enabled` build flag, the single
  "secure transport is configured" signal is the PINNED SERVER PUBLIC KEY
  (`ServerIdentity.configured?`). The default trigger fires only when BOTH the
  server is pinned AND the device has a provisioned identity (the uploader signs
  every request). This drives global app env, so it is NOT async.
  """
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.Commands
  alias RacingOrg.Tracker.Protobuf.DataSet
  alias RacingOrg.Tracker.Protobuf.DeviceCommand
  alias RacingOrg.Tracker.Protobuf.RaceAssignment
  alias RacingOrg.Tracker.Protobuf.ServerReply
  alias RacingOrg.Tracker.Pro.Race.Archive
  alias RacingOrg.Tracker.Pro.Race.BulkUploader
  alias RacingOrg.Tracker.Pro.SecureTransport.KeyStore
  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity
  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.SessionHolder

  @app :racing_org_tracker_pro

  setup do
    base = Path.join(System.tmp_dir!(), "nn_arc_gate_#{System.unique_integer([:positive])}")
    keystore_dir = Path.join(System.tmp_dir!(), "nn_arc_ks_#{System.unique_integer([:positive])}")
    File.mkdir_p!(keystore_dir)

    prev_si = Application.get_env(@app, ServerIdentity)
    prev_ks = Application.get_env(@app, KeyStore)
    holder = start_supervised!({SessionHolder, name: nil})

    on_exit(fn ->
      File.rm_rf(base)
      File.rm_rf(keystore_dir)
      restore(ServerIdentity, prev_si)
      restore(KeyStore, prev_ks)
    end)

    %{base: base, keystore_dir: keystore_dir, holder: holder}
  end

  defp restore(key, nil), do: Application.delete_env(@app, key)
  defp restore(key, value), do: Application.put_env(@app, key, value)

  defp pin_server, do: Application.put_env(@app, ServerIdentity, public_key: :crypto.strong_rand_bytes(32))
  defp unpin_server, do: Application.delete_env(@app, ServerIdentity)

  defp configure_keystore(dir), do: Application.put_env(@app, KeyStore, base_path: dir)

  defp provision_identity(dir) do
    {:ok, identity} = KeyStore.load_or_generate(base_path: dir)
    identity
  end

  defp publish_session(holder, identity) do
    session =
      Session.new(
        role: :initiator,
        session_id: :crypto.strong_rand_bytes(16),
        epoch: 0,
        credential_epoch: 0,
        identity_fingerprint: Base.decode16!(identity.fingerprint, case: :mixed),
        out_key: :crypto.strong_rand_bytes(32),
        in_key: :crypto.strong_rand_bytes(32)
      )

    SessionHolder.publish(holder, session)
  end

  # Start an Archive using its REAL default trigger (no injected bulk_upload_fn), plus
  # a probe BulkUploader whose actual upload is short-circuited by a capturing adapter.
  defp start_archive(base, holder) do
    test_pid = self()
    commands = start_supervised!({Commands, device_id: "dev"})

    # A thin BulkUploader (the named server the default trigger casts to). Its
    # upload/2 will fail fast on the missing recording dir, but a capturing adapter
    # lets us observe that the cast WAS dispatched (i.e. the gate let it through).
    _uploader =
      start_supervised!(
        {BulkUploader,
         name: BulkUploader,
         session_holder: holder,
         credential_epoch_fun: fn -> {:ok, 0} end,
         adapter: fn %Tesla.Env{} = env ->
           send(test_pid, {:bulk_request, env.url})
           {:ok, %{env | status: 200, body: "{}"}}
         end}
      )

    archive =
      start_supervised!(
        {Archive,
         base_dir: base,
         commands: commands,
         device_id: "dev",
         enqueue_fn: fn binary -> send(test_pid, {:enqueued, binary}) end,
         now_fn: fn -> ~U[2026-06-03 12:00:00Z] end,
         name: nil}
      )

    %{commands: commands, archive: archive}
  end

  defp assign(commands, recording_id, attrs) do
    race = struct(RaceAssignment, [race_recording_id: recording_id, route_hash: "rh"] ++ attrs)

    command =
      struct(DeviceCommand,
        command_id: "c1",
        assignment_id: "a1",
        assignment_version: 1,
        assignment_hash: "course-hash",
        payload: {:race_assignment, race}
      )

    reply = struct(ServerReply, protocol_version: 1, device_id: "", command: command) |> ServerReply.encode()
    :applied = Commands.apply_reply(commands, reply)
  end

  defp ds(i), do: DataSet.encode(struct(DataSet, boat_identifier: "b", counter: i))

  defp run_race(archive, commands, base) do
    assign(commands, "2026-06-03-7", race_session_id: "sess-abc")
    send(archive, {:sampling_phase, :idle, :racing})
    for i <- [1, 2], do: Archive.record(archive, ds(i))
    # Ensure the recording dir exists so the (gated) upload path can read it.
    _ = base
    send(archive, {:sampling_phase, :finish, :complete})
  end

  test "default trigger does NOT fire when the server is NOT pinned", %{base: base, keystore_dir: dir, holder: holder} do
    unpin_server()
    configure_keystore(dir)
    provision_identity(dir)

    %{commands: c, archive: a} = start_archive(base, holder)
    run_race(a, c, base)

    # Legacy UDP manifest still flows; but no signed bulk request is dispatched.
    assert_receive {:enqueued, _}
    refute_receive {:bulk_request, _}, 200
  end

  test "default trigger does NOT fire when the server is pinned but identity is NOT provisioned",
       %{base: base, keystore_dir: dir, holder: holder} do
    pin_server()
    configure_keystore(dir)
    # No provision_identity/1 -> KeyStore.load/0 returns {:error, :not_provisioned}.

    %{commands: c, archive: a} = start_archive(base, holder)
    run_race(a, c, base)

    assert_receive {:enqueued, _}
    refute_receive {:bulk_request, _}, 200
  end

  test "default trigger reaches bulk transport when pin, identity, and live session are current",
       %{base: base, keystore_dir: dir, holder: holder} do
    pin_server()
    configure_keystore(dir)
    identity = provision_identity(dir)
    assert {:ok, _session} = publish_session(holder, identity)

    %{commands: c, archive: a} = start_archive(base, holder)
    run_race(a, c, base)

    assert_receive {:enqueued, _}
    # The gate let the upload through: the signed bulk plane was hit.
    assert_receive {:bulk_request, url}, 1_000
    assert url =~ "/api/bulk/"
  end
end
