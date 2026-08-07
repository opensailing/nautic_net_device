defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1CompatibilityTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport
  alias RacingOrg.Tracker.Pro.SecureTransport.{Handshake, Primitives}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Negotiation

  @handshake_kat_sha256 "cf93a3eab0281e8aba759867f285d14fe704c3d426dd314dda0811ee8e029ce6"
  @primitive_kat_sha256 "8a88d1449553d4e3363893da443719f1894c88f096b65a19c9a4429e31e8600e"
  @recovery_kat_sha256 "18a754c97fea6b358e8b688ff586dceac3302035233c106535654deb831794b4"

  test "existing handshake and recovery golden files remain byte-identical" do
    base = Application.app_dir(:racing_org_tracker_pro, "priv/secure_transport")

    assert file_sha256(Path.join(base, "handshake_kat.json")) == @handshake_kat_sha256
    assert file_sha256(Path.join(base, "kat_vectors.json")) == @primitive_kat_sha256
    assert file_sha256(Path.join(base, "registration_recovery_v2_kat.json")) == @recovery_kat_sha256
  end

  test "legacy secure-transport constants remain unchanged" do
    assert SecureTransport.protocol_version() == 0x02
    assert SecureTransport.magic() == "SRT1"
    assert SecureTransport.type_data() == 0x10
    assert SecureTransport.header_size() == 35
    assert SecureTransport.purpose_https_bulk() == 0x80
    assert SecureTransport.dir_device_to_server() == 0x01
    assert SecureTransport.dir_server_to_device() == 0x02
  end

  test "omitted capability parameters select legacy rather than an implicit downgrade" do
    assert {:ok, :legacy} = Negotiation.parse_params(%{})
    assert {:ok, :legacy} = Negotiation.parse_params(%{"fingerprint" => "unchanged"})
  end

  test "the existing epoch-zero handshake and frame behavior remains accepted" do
    {device_public, device_private} = Primitives.generate_identity_keypair()
    {server_public, server_private} = Primitives.generate_identity_keypair()

    assert {:ok, hello, responder_state} =
             Handshake.responder_hello(
               server_identity_private: server_private,
               server_identity_public: server_public,
               device_identity_public: device_public,
               epoch: 0
             )

    assert {:ok, init, device_session} =
             Handshake.initiator_init(hello,
               device_identity_private: device_private,
               device_identity_public: device_public,
               server_identity_public: server_public,
               device_id: "00000000-0000-0000-0000-000000000001",
               timestamp_ms: 1,
               epoch: 0
             )

    assert {:ok, server_session} = Handshake.responder_finalize(responder_state, init)
    assert device_session.epoch == 0
    assert server_session.epoch == 0

    assert {:ok, frame, _device_session} = SecureTransport.seal(device_session, "legacy")
    assert {:ok, "legacy", _server_session} = SecureTransport.open(server_session, frame)
  end

  defp file_sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
