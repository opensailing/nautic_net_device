defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1GoldenTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.Session
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Control,
    KATVectors,
    Manifest,
    Messages,
    Negotiation,
    Section,
    Secret
  }

  setup_all do
    vector = KATVectors.load()
    %{inputs: vector["inputs"], expected: vector["expected"]}
  end

  test "reproduces canonical offer, canonical value, all sections, and complete manifest", context do
    inputs = context.inputs
    expected = context.expected

    offer = %{control_versions: [1], desired_state_versions: [1]}
    assert {:ok, offer_bytes} = Negotiation.encode_offer(offer)
    assert hex_string(offer_bytes) == expected["offer_hex"]
    assert hex_string(Negotiation.offer_hash(offer_bytes)) == expected["offer_hash_hex"]

    canonical_value = %{
      "é" => "Ångström",
      alpha: [nil, false, true, 0, -7, 1.5, Canonical.bytes(<<0x00, 0xFF>>)]
    }

    assert {:ok, canonical_bytes} = Canonical.encode(canonical_value)
    assert hex_string(canonical_bytes) == expected["canonical_value_hex"]
    assert hex_string(:crypto.hash(:sha256, canonical_bytes)) == expected["canonical_value_hash_hex"]

    digest_attrs = %{
      device_id: hex(inputs["device_id_hex"]),
      section: :wifi,
      section_schema_version: 1,
      secret_kind: :wifi_psk,
      digest_key_id: inputs["wifi_secret_descriptor"]["digest_key_id"],
      secret_ref: hex(inputs["wifi_secret_descriptor"]["ref_hex"])
    }

    assert {:ok, digest} =
             Secret.digest(
               hex(inputs["wifi_digest_key_hex"]),
               digest_attrs,
               hex(inputs["synthetic_noncredential_hex"])
             )

    assert hex_string(digest) == inputs["wifi_secret_descriptor"]["digest_hex"]

    sections = build_sections(inputs)

    for section <- sections do
      expected_section = get_in(expected, ["sections", Atom.to_string(section.name)])
      assert hex_string(section.content) == expected_section["canonical_content_hex"]
      assert {:ok, preimage} = Section.preimage(section)
      assert hex_string(preimage) == expected_section["preimage_hex"]
      assert hex_string(section.hash) == expected_section["hash_hex"]
      assert {:ok, descriptor} = Section.encode_descriptor(Section.descriptor(section))
      assert hex_string(descriptor) == expected_section["descriptor_hex"]
    end

    manifest_attrs = manifest_attrs(inputs, sections)
    assert {:ok, manifest_bytes} = Manifest.encode(manifest_attrs)
    assert hex_string(manifest_bytes) == expected["manifest_hex"]
    assert hex_string(Manifest.hash(manifest_bytes)) == expected["manifest_hash_hex"]
  end

  test "reproduces every desired-state payload and acknowledgement", context do
    inputs = context.inputs
    expected = context.expected
    sections = build_sections(inputs)
    assert {:ok, manifest_bytes} = Manifest.encode(manifest_attrs(inputs, sections))
    manifest_hash = Manifest.hash(manifest_bytes)
    offer_hash = hex(expected["offer_hash_hex"])

    payloads = message_payloads(inputs, sections, manifest_bytes, manifest_hash, offer_hash)

    for {name, {type, attrs}} <- payloads do
      assert {:ok, payload} = Messages.encode(type, attrs)
      assert hex_string(payload) == get_in(expected, ["messages", "#{name}_hex"])
      assert {:ok, ^attrs} = Messages.decode(type, payload)
    end
  end

  test "reproduces purpose-0x81 directional keys and complete control frames", context do
    inputs = context.inputs
    expected = context.expected
    session = session(inputs)

    assert {:ok, keys} = Control.derive_keys(session)
    assert hex_string(keys.device_to_server) == get_in(expected, ["control", "key_device_to_server_hex"])
    assert hex_string(keys.server_to_device) == get_in(expected, ["control", "key_server_to_device_hex"])

    sections = build_sections(inputs)
    assert {:ok, manifest_bytes} = Manifest.encode(manifest_attrs(inputs, sections))
    manifest_hash = Manifest.hash(manifest_bytes)
    offer_hash = hex(expected["offer_hash_hex"])
    payloads = message_payloads(inputs, sections, manifest_bytes, manifest_hash, offer_hash)

    assert {:ok, server} = Control.new(:server, session)
    assert {:ok, device} = Control.new(:device, session)

    {server, device} =
      Enum.reduce(control_sequence(), {server, device}, fn {name, sender}, {server, device} ->
        {type, attrs} = Map.fetch!(payloads, name)
        {:ok, payload} = Messages.encode(type, attrs)

        case sender do
          :server ->
            assert {:ok, frame, next_server} = Control.seal(server, type, payload)
            assert hex_string(frame) == get_in(expected, ["control", "frames", "#{name}_hex"])
            assert %{"frame" => carrier} = Control.encode_carrier(frame)
            assert carrier == get_in(expected, ["control", "carriers", "#{name}_base64"])
            assert {:ok, ^frame} = Control.decode_carrier(%{"frame" => carrier})
            assert {:ok, ^type, ^payload, next_device} = Control.open(device, frame)
            {next_server, next_device}

          :device ->
            assert {:ok, frame, next_device} = Control.seal(device, type, payload)
            assert hex_string(frame) == get_in(expected, ["control", "frames", "#{name}_hex"])
            assert %{"frame" => carrier} = Control.encode_carrier(frame)
            assert carrier == get_in(expected, ["control", "carriers", "#{name}_base64"])
            assert {:ok, ^frame} = Control.decode_carrier(%{"frame" => carrier})
            assert {:ok, ^type, ^payload, next_server} = Control.open(server, frame)
            {next_server, next_device}
        end
      end)

    assert server.send_counter == 4
    assert device.send_counter == 5
  end

  test "shared vector contains no plaintext Wi-Fi credential material", context do
    raw = File.read!(KATVectors.path())

    refute raw =~ "psk"
    refute raw =~ "password"
    refute raw =~ "passphrase"
    assert context.inputs["wifi_secret_descriptor"] != nil
    refute Map.has_key?(context.inputs["wifi_secret_descriptor"], "secret")
  end

  defp build_sections(inputs) do
    descriptor = %{
      kind: :wifi_psk,
      digest_key_id: inputs["wifi_secret_descriptor"]["digest_key_id"],
      ref: hex(inputs["wifi_secret_descriptor"]["ref_hex"]),
      digest: hex(inputs["wifi_secret_descriptor"]["digest_hex"])
    }

    specs = [
      {:assignment, :tombstone},
      {:calibration, %{"parameters" => [], "version" => 2}},
      {:clock_source, %{"mode" => "tracker_receive_time", "sources" => [], "version" => 1}},
      {:computed_values, %{"definitions" => [], "version" => 4}},
      {:polar, :tombstone},
      {:tracking, %{"broadcast_rate_hz" => 1.0, "enabled" => true, "version" => 5}},
      {:upstream, %{"ais" => true, "environment" => true, "instruments" => true, "version" => 1}},
      {:wifi, %{"enabled" => true, "ssid" => "kat-network", "version" => 3}},
      {:wind_shift,
       %{
         "damping_seconds" => 300.0,
         "enabled" => true,
         "new_extreme_margin_deg" => 2.0,
         "version" => 7
       }}
    ]

    Enum.map(specs, fn
      {name, :tombstone} ->
        {:ok, section} = Section.tombstone(name)
        section

      {:wifi, content} ->
        {:ok, section} = Section.build(:wifi, content, secrets: [descriptor])
        section

      {name, content} ->
        {:ok, section} = Section.build(name, content)
        section
    end)
  end

  defp manifest_attrs(inputs, sections) do
    %{
      device_id: hex(inputs["device_id_hex"]),
      credential_epoch: inputs["credential_epoch"],
      generation: inputs["generation"],
      minimum_firmware: inputs["minimum_firmware"],
      required_capabilities: capabilities(),
      sections: Enum.map(sections, &Section.descriptor/1)
    }
  end

  defp message_payloads(inputs, sections, manifest_bytes, manifest_hash, offer_hash) do
    identity = %{
      device_id: hex(inputs["device_id_hex"]),
      credential_epoch: inputs["credential_epoch"],
      boot_id: hex(inputs["boot_id_hex"]),
      storage_epoch: hex(inputs["storage_epoch_hex"])
    }

    generation = inputs["generation"]
    tracking = Enum.find(sections, &(&1.name == :tracking))
    wifi = Enum.find(sections, &(&1.name == :wifi))

    summaries =
      Enum.map(sections, fn section ->
        %{
          section: section.name,
          section_schema_version: section.schema_version,
          tombstone: section.tombstone,
          section_hash: section.hash
        }
      end)

    %{
      "control_accept" =>
        {:control_accept,
         %{
           device_id: identity.device_id,
           credential_epoch: identity.credential_epoch,
           selected_control_version: 1,
           selected_desired_version: 1,
           offer_hash: offer_hash
         }},
      "readiness" =>
        {:readiness,
         Map.merge(identity, %{
           selected_control_version: 1,
           selected_desired_version: 1,
           offer_hash: offer_hash,
           firmware_version: inputs["firmware_version"],
           firmware_git_sha: inputs["firmware_git_sha"],
           capabilities: capabilities(),
           effective: nil
         })},
      "manifest_delivery" =>
        {:manifest_delivery,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           manifest: manifest_bytes
         })},
      "section_chunk" =>
        {:section_chunk,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           section: :tracking,
           section_schema_version: tracking.schema_version,
           section_hash: tracking.hash,
           total_content_length: tracking.content_length,
           chunk_index: 0,
           chunk_count: 1,
           chunk_offset: 0,
           chunk: tracking.content
         })},
      "resume" =>
        {:resume,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           incomplete_sections: [
             %{
               section: :wind_shift,
               section_schema_version: 1,
               section_hash: Enum.find(sections, &(&1.name == :wind_shift)).hash,
               total_content_length: 130_000,
               missing_ranges: [
                 %{first_chunk_index: 0, chunk_count: 1},
                 %{first_chunk_index: 2, chunk_count: 1}
               ]
             }
           ]
         })},
      "secret_delivery" =>
        {:secret_delivery,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           section: :wifi,
           section_schema_version: wifi.schema_version,
           section_hash: wifi.hash,
           secret_kind: :wifi_psk,
           digest_key_id: inputs["wifi_secret_descriptor"]["digest_key_id"],
           secret_ref: hex(inputs["wifi_secret_descriptor"]["ref_hex"]),
           secret_digest: hex(inputs["wifi_secret_descriptor"]["digest_hex"]),
           secret: hex(inputs["synthetic_noncredential_hex"])
         })},
      "ack_staged" =>
        {:ack,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           status: :staged,
           sections: summaries
         })},
      "ack_effective" =>
        {:ack,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           status: :effective
         })},
      "ack_rejected" =>
        {:ack,
         Map.merge(identity, %{
           generation: generation,
           manifest_hash: manifest_hash,
           status: :rejected,
           phase: :transfer,
           error_code: :section_hash_mismatch,
           retryable: true,
           section: %{
             section: :tracking,
             section_schema_version: tracking.schema_version,
             section_hash: tracking.hash
           }
         })}
    }
  end

  defp control_sequence do
    [
      {"control_accept", :server},
      {"readiness", :device},
      {"manifest_delivery", :server},
      {"section_chunk", :server},
      {"resume", :device},
      {"secret_delivery", :server},
      {"ack_staged", :device},
      {"ack_effective", :device},
      {"ack_rejected", :device}
    ]
  end

  defp session(inputs) do
    Session.new(
      role: :responder,
      session_id: hex(inputs["session"]["session_id_hex"]),
      epoch: inputs["credential_epoch"],
      credential_epoch: inputs["credential_epoch"],
      out_key: :binary.copy(<<0>>, 32),
      in_key: :binary.copy(<<0>>, 32),
      prk: hex(inputs["session"]["prk_hex"]),
      identity_fingerprint: hex(inputs["session"]["identity_fingerprint_hex"]),
      transcript_hash: hex(inputs["session"]["transcript_hash_hex"])
    )
  end

  defp capabilities do
    Contract.capabilities()
    |> Enum.map(fn {name, _id, version} -> {name, version} end)
  end

  defp hex(value), do: Base.decode16!(value, case: :lower)
  defp hex_string(value), do: Base.encode16(value, case: :lower)
end
