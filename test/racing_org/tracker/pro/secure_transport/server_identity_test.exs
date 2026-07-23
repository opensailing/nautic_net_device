defmodule RacingOrg.Tracker.Pro.SecureTransport.ServerIdentityTest do
  @moduledoc """
  Server-identity PINNING on the device: the device holds the SERVER's Ed25519
  PUBLIC key (32 bytes) to authenticate the handshake HELLO. Configured at runtime
  (env/Application), accepted as raw 32 bytes or 64-char hex, with a clear error
  when a consumer requests it while unset.
  """
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.SecureTransport.ServerIdentity

  @app :racing_org_tracker_pro

  setup do
    prior = Application.get_env(@app, ServerIdentity)
    on_exit(fn -> restore(prior) end)
    :ok
  end

  defp restore(nil), do: Application.delete_env(@app, ServerIdentity)
  defp restore(value), do: Application.put_env(@app, ServerIdentity, value)

  defp put_public_key(value),
    do: Application.put_env(@app, ServerIdentity, public_key: value)

  test "loads + decodes a configured 32-byte raw public key" do
    raw = :crypto.strong_rand_bytes(32)
    put_public_key(raw)

    assert ServerIdentity.public_key() == raw
    assert byte_size(ServerIdentity.public_key()) == 32
  end

  test "loads + decodes a configured 64-char hex public key (either case)" do
    raw = :crypto.strong_rand_bytes(32)
    put_public_key(Base.encode16(raw, case: :lower))
    assert ServerIdentity.public_key() == raw

    put_public_key(Base.encode16(raw, case: :upper))
    assert ServerIdentity.public_key() == raw
  end

  test "fetch_public_key/0 returns {:ok, key} when configured" do
    raw = :crypto.strong_rand_bytes(32)
    put_public_key(raw)
    assert {:ok, ^raw} = ServerIdentity.fetch_public_key()
  end

  test "configured?/0 reflects whether a valid key is set" do
    Application.delete_env(@app, ServerIdentity)
    refute ServerIdentity.configured?()

    put_public_key(:crypto.strong_rand_bytes(32))
    assert ServerIdentity.configured?()
  end

  test "unset -> fetch_public_key/0 returns a clear error, public_key/0 raises" do
    Application.delete_env(@app, ServerIdentity)

    assert {:error, :server_public_key_not_configured} = ServerIdentity.fetch_public_key()
    assert_raise RuntimeError, ~r/server.*public key/i, fn -> ServerIdentity.public_key() end
  end

  test "a malformed configured value (wrong length) is a clear error, not a silent pass" do
    put_public_key(<<1, 2, 3>>)
    assert {:error, :server_public_key_not_configured} = ServerIdentity.fetch_public_key()
    assert_raise RuntimeError, fn -> ServerIdentity.public_key() end
  end
end
