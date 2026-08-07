defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1ControlTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport, as: SecureTransport

  alias RacingOrg.Tracker.Pro.SecureTransport.{Primitives, ReplayWindow, Session}
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Control, Messages}

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @session_id Base.decode16!("606162636465666768696a6b6c6d6e6f", case: :lower)
  @offer_hash :binary.copy(<<0xA1>>, 32)

  describe "key separation and state" do
    test "derives purpose 0x81 keys independently by direction" do
      session = session(:responder)

      assert SecureTransport.purpose_https_bulk() == 0x80
      assert SecureTransport.purpose_control_v1() == 0x81
      assert {:ok, keys} = Control.derive_keys(session)
      assert byte_size(keys.device_to_server) == 32
      assert byte_size(keys.server_to_device) == 32
      refute keys.device_to_server == keys.server_to_device
      refute keys.device_to_server == session.out_key
      refute keys.server_to_device == session.in_key
    end

    test "starts independent counters and replay windows regardless of data-plane state" do
      session = %{session(:responder) | send_counter: 999, replay_window: accepted_window(999)}

      assert {:ok, server} = Control.new(:server, session)
      assert server.send_counter == 0
      assert server.replay_window == ReplayWindow.new()
      assert session.send_counter == 999
      assert session.replay_window != server.replay_window
      refute inspect(server) =~ Base.encode16(server.send_key, case: :lower)
      refute inspect(server) =~ Base.encode16(server.receive_key, case: :lower)
    end
  end

  describe "control_v1 AEAD frame" do
    test "seals and opens an authenticated message with independent state" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      payload = control_accept_payload()

      assert {:ok, frame, server} = Control.seal(server, :control_accept, payload)
      assert server.send_counter == 1
      assert byte_size(frame) == 40 + byte_size(payload) + 16

      assert <<"ROC1", 0x01, 0x01, 0x02, 0x01, @session_id::binary, 7::32, 0::64, ciphertext_length::32, _::binary>> =
               frame

      assert ciphertext_length == byte_size(payload)
      assert {:ok, :control_accept, ^payload, device} = Control.open(device, frame)
      assert device.replay_window.hi == 0
      assert {:error, :replayed} = Control.open(device, frame)
    end

    test "does not commit a forged frame to the replay window" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      assert {:ok, frame, _server} = Control.seal(server, :control_accept, control_accept_payload())
      forged = flip_byte(frame, 45)

      assert {:error, :aead_open_failed} = Control.open(device, forged)
      assert {:ok, :control_accept, _payload, device} = Control.open(device, frame)
      assert device.replay_window.hi == 0
    end

    test "commits authenticated payload-domain failures so they cannot be replayed" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      wrong_payload = payload_with_domain("RacingOrg-ControlReadiness-v1")

      assert {:ok, frame} =
               Control.seal_with(
                 server.send_key,
                 @session_id,
                 7,
                 :server_to_device,
                 :control_accept,
                 0,
                 wrong_payload,
                 validate_payload_domain: false
               )

      assert {:error, :payload_domain_mismatch, device} = Control.open(device, frame)
      assert device.replay_window.hi == 0
      assert {:error, :replayed} = Control.open(device, frame)

      wrong_version =
        Contract.payload_domain(:control_accept) <> <<0x02, 0x01, 0x00>>

      assert {:ok, frame} =
               Control.seal_with(
                 server.send_key,
                 @session_id,
                 7,
                 :server_to_device,
                 :control_accept,
                 1,
                 wrong_version,
                 validate_payload_domain: false
               )

      assert {:error, :unsupported_payload_version, device} = Control.open(device, frame)
      assert device.replay_window.hi == 1

      wrong_type =
        Contract.payload_domain(:control_accept) <> <<0x01, 0x02, 0x00>>

      assert {:ok, frame} =
               Control.seal_with(
                 server.send_key,
                 @session_id,
                 7,
                 :server_to_device,
                 :control_accept,
                 2,
                 wrong_type,
                 validate_payload_domain: false
               )

      assert {:error, :payload_type_mismatch, device} = Control.open(device, frame)
      assert device.replay_window.hi == 2
    end

    test "rejects wrong direction, message type, session, epoch, lengths, tags, and trailing bytes" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      assert {:ok, frame, _server} = Control.seal(server, :control_accept, control_accept_payload())

      assert {:error, :wrong_direction} = Control.open(server, frame)
      assert {:error, :wrong_session} = Control.open(device, replace_bytes(frame, 8, :binary.copy(<<0>>, 16)))
      assert {:error, :stale_credential_epoch} = Control.open(device, replace_bytes(frame, 24, <<8::32>>))
      assert {:error, :unsupported_message_type} = Control.open(device, replace_bytes(frame, 7, <<0x20>>))
      assert {:error, :wrong_message_direction} = Control.open(device, replace_bytes(frame, 7, <<0x02>>))
      assert {:error, :invalid_frame_length} = Control.open(device, replace_bytes(frame, 36, <<1::32>>))
      assert {:error, :invalid_frame_length} = Control.open(device, binary_part(frame, 0, byte_size(frame) - 1))
      assert {:error, :invalid_frame_length} = Control.open(device, frame <> <<0>>)
    end

    test "rejects tampered header counters, stale counters, and the rekey threshold" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      assert {:ok, frame0, server} = Control.seal(server, :control_accept, control_accept_payload())
      assert {:ok, frame1, _server} = Control.seal(server, :manifest_delivery, manifest_delivery_payload())

      tampered_counter = replace_bytes(frame0, 28, <<1::64>>)
      assert {:error, :aead_open_failed} = Control.open(device, tampered_counter)

      assert {:ok, :manifest_delivery, _payload, device} = Control.open(device, frame1)
      assert {:ok, :control_accept, _payload, device} = Control.open(device, frame0)

      high = %{device | replay_window: accepted_window(64)}
      assert {:error, :stale_counter} = Control.open(high, frame0)

      exhausted = %{server | send_counter: SecureTransport.rekey_after()}
      assert {:error, :rekey_required} = Control.seal(exhausted, :manifest_delivery, manifest_delivery_payload())
    end

    test "rejects authenticated receive counters at the rekey threshold" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, device} = Control.new(:device, session(:initiator))
      counter = SecureTransport.rekey_after()
      payload = control_accept_payload()
      {:ok, type_code, :server_to_device} = Contract.message_type(:control_accept)

      header =
        <<"ROC1", Contract.version(), SecureTransport.aead_chacha20_poly1305(), SecureTransport.dir_server_to_device(),
          type_code, @session_id::binary, 7::32, counter::64, byte_size(payload)::32>>

      nonce = <<7::32, counter::64>>

      assert {:ok, ciphertext, tag} =
               Primitives.aead_seal(server.send_key, nonce, payload, header)

      assert {:error, :rekey_required} =
               Control.open(device, header <> ciphertext <> tag)

      assert device.replay_window == ReplayWindow.new()
    end

    test "enforces the maximum plaintext before encryption" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      oversized = :binary.copy(<<0>>, Control.max_plaintext_size() + 1)

      assert {:error, :plaintext_too_large} =
               Control.seal_with(
                 server.send_key,
                 @session_id,
                 7,
                 :server_to_device,
                 :control_accept,
                 0,
                 oversized,
                 validate_payload_domain: false
               )
    end
  end

  describe "strict Phoenix carrier" do
    test "uses exactly one strict padded standard Base64 field" do
      assert {:ok, server} = Control.new(:server, session(:responder))
      assert {:ok, frame, _server} = Control.seal(server, :control_accept, control_accept_payload())
      carrier = Control.encode_carrier(frame)

      assert %{"frame" => encoded} = carrier
      assert Base.encode64(frame) == encoded
      assert {:ok, ^frame} = Control.decode_carrier(carrier)

      unpadded = String.trim_trailing(encoded, "=")
      assert {:error, :invalid_control_base64} = Control.decode_carrier(%{"frame" => unpadded})
      assert {:error, :invalid_control_base64} = Control.decode_carrier(%{"frame" => String.replace(encoded, "+", "-")})
      assert {:error, :invalid_control_base64} = Control.decode_carrier(%{"frame" => encoded <> "\n"})
      assert {:error, :invalid_control_carrier} = Control.decode_carrier(%{"frame" => encoded, "extra" => true})
      assert {:error, :invalid_control_carrier} = Control.decode_carrier(%{frame: encoded})
    end
  end

  defp session(role) do
    direction_keys = %{
      responder: {:binary.copy(<<0x91>>, 32), :binary.copy(<<0x92>>, 32)},
      initiator: {:binary.copy(<<0x92>>, 32), :binary.copy(<<0x91>>, 32)}
    }

    {out_key, in_key} = Map.fetch!(direction_keys, role)

    Session.new(
      role: role,
      session_id: @session_id,
      epoch: 7,
      credential_epoch: 7,
      out_key: out_key,
      in_key: in_key,
      prk: Base.decode16!("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", case: :lower),
      identity_fingerprint:
        Base.decode16!("202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f", case: :lower),
      transcript_hash: Base.decode16!("404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f", case: :lower)
    )
  end

  defp control_accept_payload do
    {:ok, payload} =
      Messages.encode(:control_accept, %{
        device_id: @device_id,
        credential_epoch: 7,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash
      })

    payload
  end

  defp manifest_delivery_payload do
    Contract.payload_domain(:manifest_delivery) <> <<Contract.version(), 0x03, 0x00>>
  end

  defp payload_with_domain(domain), do: domain <> <<0x01, 0x00>>

  defp accepted_window(counter) do
    {:ok, window} = ReplayWindow.check_and_commit(ReplayWindow.new(), counter)
    window
  end

  defp flip_byte(binary, offset) do
    <<prefix::binary-size(offset), byte, suffix::binary>> = binary
    prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix
  end

  defp replace_bytes(binary, offset, replacement) do
    suffix_offset = offset + byte_size(replacement)
    <<prefix::binary-size(offset), _old::binary-size(byte_size(replacement)), suffix::binary>> = binary
    assert suffix_offset <= byte_size(binary)
    prefix <> replacement <> suffix
  end
end
