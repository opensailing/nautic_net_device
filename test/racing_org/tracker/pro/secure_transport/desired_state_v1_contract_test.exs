defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1ContractTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{
    Canonical,
    Manifest,
    Messages,
    Negotiation,
    Section,
    Secret
  }

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @boot_id Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @offer_hash :binary.copy(<<0xA1>>, 32)
  @manifest_hash :binary.copy(<<0xB2>>, 32)
  @section_hash :binary.copy(<<0xC3>>, 32)
  @database_int_max 9_223_372_036_854_775_807

  describe "closed registries" do
    test "freezes the authoritative nine-section set and schema versions" do
      assert Contract.sections() == [
               :assignment,
               :calibration,
               :clock_source,
               :computed_values,
               :polar,
               :tracking,
               :upstream,
               :wifi,
               :wind_shift
             ]

      assert Enum.map(Contract.sections(), &Contract.section_code/1) == Enum.to_list(1..9)
      assert Enum.all?(Contract.sections(), &(Contract.section_schema_version(&1) == 1))

      assert Contract.tombstone_allowed?(:assignment)
      assert Contract.tombstone_allowed?(:polar)
      assert Contract.tombstone_allowed?(:wifi)
      refute Contract.tombstone_allowed?(:tracking)

      assert {:error, :unknown_section} = Contract.section_name(0xFF)
      assert {:error, :unknown_section} = Contract.section_code(:race_policy)
    end

    test "freezes control message assignments and reserved task ranges" do
      assert Contract.message_types() == %{
               control_accept: {0x01, :server_to_device},
               readiness: {0x02, :device_to_server},
               manifest_delivery: {0x03, :server_to_device},
               section_chunk: {0x04, :server_to_device},
               resume: {0x05, :device_to_server},
               secret_delivery: {0x06, :server_to_device},
               ack: {0x07, :device_to_server},
               command_delivery: {0x20, :server_to_device},
               command_ack: {0x21, :device_to_server},
               delivery_receipt: {0x30, :server_to_device},
               checkpoint_submission: {0x31, :device_to_server},
               checkpoint_hydration: {0x32, :server_to_device},
               delivery_submission: {0x33, :device_to_server},
               checkpoint_submission_chunk: {0x34, :device_to_server},
               checkpoint_submission_resume: {0x35, :server_to_device},
               checkpoint_hydration_chunk: {0x36, :server_to_device},
               checkpoint_hydration_resume: {0x37, :device_to_server},
               delivery_payload: {0x38, :device_to_server},
               delivery_payload_chunk: {0x39, :device_to_server}
             }

      assert Contract.reserved_message_ranges() == [
               {0x08..0x1F, :desired_state_extensions},
               {0x20..0x2F, :commands_task_69},
               {0x30..0x4F, :receipts_checkpoints_task_68},
               {0x50..0x5F, :health_ota_task_70},
               {0x60..0x7F, :future_standard},
               {0x80..0xFF, :unassigned_private}
             ]

      assert Contract.message_type(0x20) == {:ok, :command_delivery, :server_to_device}
      assert Contract.message_type(0x21) == {:ok, :command_ack, :device_to_server}
      assert {:error, :unsupported_message_type} = Contract.message_type(0x22)
      assert {:error, :unsupported_message_type} = Contract.message_type(0x80)
    end
  end

  describe "sections, tombstones, and secret descriptors" do
    test "hashes a present section over its canonical top-level map" do
      assert {:ok, section} =
               Section.build(:tracking, %{
                 version: 7,
                 enabled: true,
                 broadcast_rate_hz: 1.0
               })

      assert section.name == :tracking
      assert section.code == 6
      assert section.schema_version == 1
      refute section.tombstone
      assert section.content_length == byte_size(section.content)
      assert byte_size(section.hash) == 32
      assert {:ok, ^section} = Section.verify(section, section.content)

      tampered = binary_part(section.content, 0, byte_size(section.content) - 1) <> <<0>>
      assert {:error, :section_hash_mismatch} = Section.verify(section, tampered)
    end

    test "uses real domain-separated hashes for tombstones and rejects illegal shapes" do
      assert {:ok, tombstone} = Section.tombstone(:assignment)
      assert tombstone.tombstone
      assert tombstone.content == <<>>
      assert tombstone.content_length == 0
      assert tombstone.secrets == []
      assert tombstone.hash != :binary.copy(<<0>>, 32)
      assert {:ok, ^tombstone} = Section.verify(tombstone, <<>>)

      assert {:error, :tombstone_not_allowed} = Section.tombstone(:tracking)
      assert {:error, :section_content_must_be_map} = Section.build(:tracking, [])
    end

    test "rejects decoded tombstones for non-tombstoneable sections" do
      name = "tracking"

      preimage =
        Contract.section_domain() <>
          <<Contract.version(), byte_size(name)::16, name::binary, 1::16, 1, 0::64, 0>>

      hash = :crypto.hash(:sha256, preimage)
      code = Contract.section_code(:tracking)
      descriptor = <<code, 1::16, 1, 0::64, 0, hash::binary>>

      assert {:error, :tombstone_not_allowed} = Section.take_descriptor(descriptor)
    end

    test "rejects tombstone descriptors with an incorrect domain-separated hash" do
      assert {:ok, tombstone} = Section.tombstone(:assignment)
      assert {:ok, encoded} = Section.encode_descriptor(tombstone)

      prefix_size = byte_size(encoded) - 32
      <<prefix::binary-size(prefix_size), _old_hash::binary-size(32)>> = encoded
      invalid = prefix <> :binary.copy(<<0>>, 32)

      assert {:error, :section_hash_mismatch} = Section.take_descriptor(invalid)
    end

    test "rejects zero-length non-tombstone descriptors" do
      assert {:ok, section} = Section.build(:computed_values, %{})

      invalid =
        section
        |> Section.descriptor()
        |> Map.put(:content_length, 0)

      assert {:error, :invalid_content_length} = Section.encode_descriptor(invalid)
    end

    test "freezes Wi-Fi secret references without accepting plaintext in section content" do
      secret_ref = Base.decode16!("11111111111111111111111111111111", case: :lower)
      digest = :binary.copy(<<0xD4>>, 32)

      descriptor = %{
        kind: :wifi_psk,
        digest_key_id: 7,
        ref: secret_ref,
        digest: digest
      }

      assert {:ok, wifi} =
               Section.build(
                 :wifi,
                 %{version: 3, enabled: true, ssid: "kat-network"},
                 secrets: [descriptor]
               )

      refute wifi.content =~ "psk"
      assert wifi.secrets == [descriptor]
      assert {:ok, encoded_descriptor} = Section.encode_secret_descriptor(descriptor)
      assert {:ok, ^descriptor, <<>>} = Section.take_secret_descriptor(encoded_descriptor)

      assert {:error, :secret_not_allowed} =
               Section.build(:tracking, %{version: 1}, secrets: [descriptor])

      assert {:error, :invalid_secret_reference} =
               Section.build(:wifi, %{version: 1}, secrets: [%{descriptor | ref: :binary.copy(<<0>>, 16)}])

      assert {:error, :duplicate_secret_descriptor} =
               Section.build(:wifi, %{version: 1}, secrets: [descriptor, descriptor])

      safe_content = %{version: 3, enabled: true, ssid: "kat-network"}

      for field <- [:psk, "password", :passphrase] do
        assert {:error, :plaintext_wifi_secret_forbidden} =
                 Section.build(:wifi, Map.put(safe_content, field, "synthetic-noncredential"))
      end

      assert {:error, :unknown_wifi_field} =
               Section.build(:wifi, Map.put(safe_content, :network_key, "synthetic-noncredential"))

      assert {:error, :invalid_wifi_content} =
               Section.build(:wifi, %{safe_content | ssid: %{psk: "synthetic-noncredential"}})

      assert {:ok, unsafe_content} =
               Canonical.encode(Map.put(safe_content, :psk, "synthetic-noncredential"))

      name = "wifi"

      unsafe_preimage =
        Contract.section_domain() <>
          <<Contract.version(), byte_size(name)::16, name::binary, 1::16, 0, byte_size(unsafe_content)::64, 0>> <>
          unsafe_content

      unsafe_descriptor = %{
        name: :wifi,
        code: Contract.section_code(:wifi),
        schema_version: 1,
        tombstone: false,
        content_length: byte_size(unsafe_content),
        secrets: [],
        hash: :crypto.hash(:sha256, unsafe_preimage)
      }

      assert {:error, :plaintext_wifi_secret_forbidden} =
               Section.verify(unsafe_descriptor, unsafe_content)
    end

    test "computes the dedicated server-keyed secret digest over all binding fields" do
      key = :binary.copy(<<0x5A>>, 32)
      secret_ref = Base.decode16!("12121212121212121212121212121212", case: :lower)
      synthetic_noncredential = <<0x00, 0xFF, 0x01>>

      attrs = %{
        device_id: @device_id,
        section: :wifi,
        section_schema_version: 1,
        secret_kind: :wifi_psk,
        digest_key_id: 7,
        secret_ref: secret_ref
      }

      assert {:ok, digest} = Secret.digest(key, attrs, synthetic_noncredential)
      assert byte_size(digest) == 32
      assert digest == Secret.digest!(key, attrs, synthetic_noncredential)
      refute digest == :crypto.hash(:sha256, synthetic_noncredential)

      assert {:error, :digest_key_too_short} =
               Secret.digest(:binary.copy(<<0>>, 31), attrs, synthetic_noncredential)

      assert {:error, :secret_too_large} =
               Secret.digest(key, attrs, :binary.copy(<<0>>, 1_025))
    end
  end

  describe "manifest" do
    test "encodes and strictly decodes one complete ordered generation" do
      sections = complete_sections()
      attrs = manifest_attrs(sections)

      assert {:ok, bytes} = Manifest.encode(attrs)
      assert byte_size(bytes) <= Contract.max_manifest_size()
      assert {:ok, decoded} = Manifest.decode(bytes)

      assert decoded.device_id == @device_id
      assert decoded.credential_epoch == 7
      assert decoded.generation == 42
      assert decoded.desired_state_version == 1
      assert decoded.section_set_version == 1
      assert decoded.minimum_firmware == "3.0.0"
      assert decoded.required_capabilities == required_capabilities()
      assert Enum.map(decoded.sections, & &1.name) == Contract.sections()
      assert decoded.bytes == bytes
      assert decoded.hash == Manifest.hash(bytes)
      assert decoded.complete_hash == decoded.hash
    end

    test "caps authoritative generations at the signed database range" do
      attrs = %{manifest_attrs(complete_sections()) | generation: @database_int_max}

      assert {:ok, bytes} = Manifest.encode(attrs)
      assert {:ok, %{generation: @database_int_max}} = Manifest.decode(bytes)

      assert {:error, :invalid_generation} =
               Manifest.encode(%{attrs | generation: @database_int_max + 1})
    end

    test "rejects missing, duplicate, unknown, out-of-order, oversized, and invalid compatibility data" do
      sections = complete_sections()

      assert {:error, :missing_section} =
               Manifest.encode(manifest_attrs(Enum.drop(sections, -1)))

      assert {:error, :duplicate_section} =
               Manifest.encode(manifest_attrs([hd(sections) | sections]))

      assert {:error, :sections_out_of_order} =
               Manifest.encode(manifest_attrs(Enum.reverse(sections)))

      unknown = %{hd(sections) | name: :unknown, code: 0xFF}

      assert {:error, :unknown_section} =
               Manifest.encode(manifest_attrs([unknown | tl(sections)]))

      assert {:error, :invalid_semver} =
               Manifest.encode(%{manifest_attrs(sections) | minimum_firmware: "03.0.0"})

      assert {:error, :invalid_semver} =
               Manifest.encode(%{manifest_attrs(sections) | minimum_firmware: "3.0.0+build"})

      assert {:error, :capabilities_out_of_order} =
               Manifest.encode(%{
                 manifest_attrs(sections)
                 | required_capabilities: Enum.reverse(required_capabilities())
               })

      assert {:error, :unknown_field} =
               Manifest.encode(Map.put(manifest_attrs(sections), :created_at, 123))

      oversized_sections =
        Enum.map(sections, fn section ->
          %{section | content_length: 16_777_216}
        end)

      assert {:error, :generation_content_too_large} =
               Manifest.encode(manifest_attrs(oversized_sections))
    end

    test "rejects malformed section descriptors instead of raising" do
      sections = complete_sections()
      first = hd(sections)

      for invalid <- [
            Map.delete(first, :content_length),
            Map.put(first, :content_length, "invalid")
          ] do
        assert {:error, :invalid_content_length} =
                 sections
                 |> List.replace_at(0, invalid)
                 |> manifest_attrs()
                 |> Manifest.encode()
      end
    end

    test "rejects tampering and trailing bytes" do
      assert {:ok, bytes} = complete_sections() |> manifest_attrs() |> Manifest.encode()
      last = byte_size(bytes) - 1
      <<prefix::binary-size(last), byte>> = bytes
      tampered = prefix <> <<Bitwise.bxor(byte, 1)>>

      assert {:error, _reason} = Manifest.decode(tampered)
      assert {:error, :trailing_bytes} = Manifest.decode(bytes <> <<0>>)
    end
  end

  describe "capability negotiation" do
    test "encodes control versions before desired-state versions" do
      offer = %{control_versions: [1, 3], desired_state_versions: [2]}

      assert {:ok, bytes} = Negotiation.encode_offer(offer)

      assert bytes ==
               Contract.offer_domain() <>
                 <<Contract.version(), 2, 1::16, 3::16, 1, 2::16>>

      assert {:ok, ^offer} = Negotiation.decode_offer(bytes)
    end

    test "keeps omission explicitly legacy and freezes canonical offer selection" do
      assert {:ok, :legacy} = Negotiation.parse_params(%{})

      params = %{
        "control_versions" => "1",
        "desired_state_versions" => "1"
      }

      assert {:ok, offer} = Negotiation.parse_params(params)
      assert {:ok, ^offer} = Negotiation.parse_params(Map.put(params, "fingerprint", "unchanged"))
      assert offer.control_versions == [1]
      assert offer.desired_state_versions == [1]
      assert {:ok, bytes} = Negotiation.encode_offer(offer)
      assert {:ok, ^offer} = Negotiation.decode_offer(bytes)
      assert {:ok, selection} = Negotiation.select(offer)
      assert selection.selected_control_version == 1
      assert selection.selected_desired_version == 1
      assert selection.offer_hash == Negotiation.offer_hash(bytes)
    end

    test "rejects malformed, partial, duplicate, descending, oversized, and unsupported offers" do
      assert {:error, :incomplete_capability_offer} =
               Negotiation.parse_params(%{"control_versions" => "1"})

      for value <- ["", "01", "1,", "1,1", "2,1", "-1", "65536", "1  ,2"] do
        assert {:error, :invalid_capability_versions} =
                 Negotiation.parse_params(%{
                   "control_versions" => value,
                   "desired_state_versions" => "1"
                 })
      end

      too_many = Enum.join(1..9, ",")

      assert {:error, :too_many_capability_versions} =
               Negotiation.parse_params(%{
                 "control_versions" => too_many,
                 "desired_state_versions" => "1"
               })

      assert {:error, :no_common_version} =
               Negotiation.select(%{
                 control_versions: [2],
                 desired_state_versions: [1]
               })
    end
  end

  describe "authenticated control payloads" do
    test "round-trips control accept and readiness identity" do
      accept = %{
        device_id: @device_id,
        credential_epoch: 7,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash
      }

      assert {:ok, accept_bytes} = Messages.encode(:control_accept, accept)
      assert {:ok, ^accept} = Messages.decode(:control_accept, accept_bytes)

      readiness = %{
        device_id: @device_id,
        credential_epoch: 7,
        boot_id: @boot_id,
        storage_epoch: @storage_epoch,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash,
        firmware_version: "3.0.0",
        firmware_git_sha: "0123abc",
        capabilities: required_capabilities(),
        effective: %{
          credential_epoch: 6,
          generation: 41,
          manifest_hash: @manifest_hash
        }
      }

      assert {:ok, readiness_bytes} = Messages.encode(:readiness, readiness)
      assert {:ok, ^readiness} = Messages.decode(:readiness, readiness_bytes)

      effective_suffix = <<1, 6::32, 41::64, @manifest_hash::binary>>

      assert binary_part(
               readiness_bytes,
               byte_size(readiness_bytes) - byte_size(effective_suffix),
               byte_size(effective_suffix)
             ) == effective_suffix

      without_effective = %{readiness | effective: nil}
      assert {:ok, without_effective_bytes} = Messages.encode(:readiness, without_effective)
      assert :binary.last(without_effective_bytes) == 0
      assert {:ok, ^without_effective} = Messages.decode(:readiness, without_effective_bytes)

      invalid_presence =
        binary_part(without_effective_bytes, 0, byte_size(without_effective_bytes) - 1) <> <<2>>

      assert {:error, :invalid_effective_presence} =
               Messages.decode(:readiness, invalid_presence)

      assert {:error, :invalid_boot_id} =
               Messages.encode(:readiness, %{readiness | boot_id: :binary.copy(<<0>>, 16)})

      assert {:error, :invalid_git_sha} =
               Messages.encode(:readiness, %{readiness | firmware_git_sha: "ABCDEF0"})
    end

    test "rejects generation zero in a present effective readiness identity" do
      readiness = %{
        device_id: @device_id,
        credential_epoch: 7,
        boot_id: @boot_id,
        storage_epoch: @storage_epoch,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash,
        firmware_version: "3.0.0",
        firmware_git_sha: "0123abc",
        capabilities: required_capabilities(),
        effective: %{
          credential_epoch: 6,
          generation: 1,
          manifest_hash: @manifest_hash
        }
      }

      invalid = put_in(readiness, [:effective, :generation], 0)
      assert {:error, :invalid_generation} = Messages.encode(:readiness, invalid)

      assert {:ok, bytes} = Messages.encode(:readiness, readiness)
      effective_size = 1 + 4 + 8 + 32
      prefix_size = byte_size(bytes) - effective_size

      assert <<prefix::binary-size(prefix_size), 1, 6::32, 1::64, @manifest_hash::binary>> = bytes

      assert {:error, :invalid_generation} =
               Messages.decode(
                 :readiness,
                 prefix <> <<1, 6::32, 0::64, @manifest_hash::binary>>
               )
    end

    test "caps every desired-generation control identity at the signed database range" do
      readiness = %{
        device_id: @device_id,
        credential_epoch: 7,
        boot_id: @boot_id,
        storage_epoch: @storage_epoch,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash,
        firmware_version: "3.0.0",
        firmware_git_sha: "0123abc",
        capabilities: required_capabilities(),
        effective: %{
          credential_epoch: 7,
          generation: @database_int_max,
          manifest_hash: @manifest_hash
        }
      }

      assert {:ok, _bytes} = Messages.encode(:readiness, readiness)

      assert {:error, :invalid_generation} =
               readiness
               |> put_in([:effective, :generation], @database_int_max + 1)
               |> then(&Messages.encode(:readiness, &1))

      manifest_attrs = %{manifest_attrs(complete_sections()) | generation: @database_int_max}
      assert {:ok, manifest} = Manifest.encode(manifest_attrs)
      manifest_hash = Manifest.hash(manifest)

      delivery =
        identity_fields(%{
          generation: @database_int_max,
          manifest_hash: manifest_hash,
          manifest: manifest
        })

      assert {:ok, _bytes} = Messages.encode(:manifest_delivery, delivery)

      assert {:error, :invalid_generation} =
               Messages.encode(:manifest_delivery, %{delivery | generation: @database_int_max + 1})

      chunk =
        identity_fields(%{
          generation: @database_int_max,
          manifest_hash: @manifest_hash,
          section: :tracking,
          section_schema_version: 1,
          section_hash: @section_hash,
          total_content_length: 1,
          chunk_index: 0,
          chunk_count: 1,
          chunk_offset: 0,
          chunk: <<0>>
        })

      assert {:ok, _bytes} = Messages.encode(:section_chunk, chunk)

      assert {:error, :invalid_generation} =
               Messages.encode(:section_chunk, %{chunk | generation: @database_int_max + 1})
    end

    test "binds manifest delivery to device, epoch, incarnation, generation, and hash" do
      assert {:ok, manifest_bytes} = complete_sections() |> manifest_attrs() |> Manifest.encode()
      manifest_hash = Manifest.hash(manifest_bytes)

      delivery =
        identity_fields(%{
          generation: 42,
          manifest_hash: manifest_hash,
          manifest: manifest_bytes
        })

      assert {:ok, bytes} = Messages.encode(:manifest_delivery, delivery)
      assert {:ok, ^delivery} = Messages.decode(:manifest_delivery, bytes)

      assert {:error, :manifest_binding_mismatch} =
               Messages.encode(:manifest_delivery, %{delivery | credential_epoch: 8})

      assert {:error, :manifest_hash_mismatch} =
               Messages.encode(:manifest_delivery, %{delivery | manifest_hash: @manifest_hash})
    end

    test "freezes strict chunk geometry and resume ranges" do
      chunk =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          section: :tracking,
          section_schema_version: 1,
          section_hash: @section_hash,
          total_content_length: 70_000,
          chunk_index: 1,
          chunk_count: 2,
          chunk_offset: 61_440,
          chunk: :binary.copy(<<0xAA>>, 8_560)
        })

      assert {:ok, bytes} = Messages.encode(:section_chunk, chunk)
      assert {:ok, ^chunk} = Messages.decode(:section_chunk, bytes)

      assert {:error, :invalid_chunk_offset} =
               Messages.encode(:section_chunk, %{chunk | chunk_offset: 61_439})

      assert {:error, :invalid_chunk_length} =
               Messages.encode(:section_chunk, %{chunk | chunk: :binary.copy(<<0>>, 8_559)})

      resume =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          incomplete_sections: [
            %{
              section: :tracking,
              section_schema_version: 1,
              section_hash: @section_hash,
              total_content_length: 200_000,
              missing_ranges: [
                %{first_chunk_index: 0, chunk_count: 1},
                %{first_chunk_index: 2, chunk_count: 2}
              ]
            }
          ]
        })

      assert {:ok, resume_bytes} = Messages.encode(:resume, resume)
      assert {:ok, ^resume} = Messages.decode(:resume, resume_bytes)

      adjacent =
        put_in(resume, [:incomplete_sections, Access.at(0), :missing_ranges], [
          %{first_chunk_index: 0, chunk_count: 1},
          %{first_chunk_index: 1, chunk_count: 1}
        ])

      assert {:error, :nonminimal_missing_ranges} = Messages.encode(:resume, adjacent)
    end

    test "freezes authenticated secret injection without allowing it into manifests" do
      secret =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          section: :wifi,
          section_schema_version: 1,
          section_hash: @section_hash,
          secret_kind: :wifi_psk,
          digest_key_id: 7,
          secret_ref: Base.decode16!("11111111111111111111111111111111", case: :lower),
          secret_digest: :binary.copy(<<0xD4>>, 32),
          secret: <<0x00, 0xFF, 0x01>>
        })

      assert {:ok, bytes} = Messages.encode(:secret_delivery, secret)
      assert {:ok, ^secret} = Messages.decode(:secret_delivery, bytes)

      assert {:error, :secret_too_large} =
               Messages.encode(:secret_delivery, %{secret | secret: :binary.copy(<<0>>, 1_025)})

      refute inspect(complete_sections()) =~ "00ff01"
    end

    test "freezes staged, effective, and rejected acknowledgement shapes" do
      summaries =
        Enum.map(complete_sections(), fn section ->
          %{
            section: section.name,
            section_schema_version: section.schema_version,
            tombstone: section.tombstone,
            section_hash: section.hash
          }
        end)

      staged =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          status: :staged,
          sections: summaries
        })

      effective =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          status: :effective
        })

      rejected =
        identity_fields(%{
          generation: 42,
          manifest_hash: @manifest_hash,
          status: :rejected,
          phase: :transfer,
          error_code: :section_hash_mismatch,
          retryable: true,
          section: %{
            section: :tracking,
            section_schema_version: 1,
            section_hash: @section_hash
          }
        })

      for ack <- [staged, effective, rejected] do
        assert {:ok, bytes} = Messages.encode(:ack, ack)
        assert {:ok, ^ack} = Messages.decode(:ack, bytes)
      end

      assert {:error, :missing_section} =
               Messages.encode(:ack, %{staged | sections: Enum.drop(summaries, -1)})

      assert {:error, :invalid_rejection_shape} =
               Messages.encode(:ack, Map.put(effective, :error_code, :internal_failure))

      assert {:error, :unknown_rejection_code} =
               Messages.encode(:ack, %{rejected | error_code: :arbitrary_detail})
    end

    test "rejects wrong domains, versions, type substitution, truncation, and trailing bytes" do
      accept = %{
        device_id: @device_id,
        credential_epoch: 7,
        selected_control_version: 1,
        selected_desired_version: 1,
        offer_hash: @offer_hash
      }

      assert {:ok, bytes} = Messages.encode(:control_accept, accept)
      assert {:error, :payload_domain_mismatch} = Messages.decode(:readiness, bytes)

      assert {:error, :unsupported_payload_version} =
               Messages.decode(:control_accept, replace_version(bytes, 0x02))

      assert {:error, :truncated} =
               Messages.decode(:control_accept, binary_part(bytes, 0, byte_size(bytes) - 1))

      assert {:error, :trailing_bytes} = Messages.decode(:control_accept, bytes <> <<0>>)
    end
  end

  defp complete_sections do
    secret_descriptor = %{
      kind: :wifi_psk,
      digest_key_id: 7,
      ref: Base.decode16!("11111111111111111111111111111111", case: :lower),
      digest: :binary.copy(<<0xD4>>, 32)
    }

    builders = [
      fn -> Section.tombstone(:assignment) end,
      fn -> Section.build(:calibration, %{version: 2, parameters: []}) end,
      fn -> Section.build(:clock_source, %{version: 1, mode: "tracker_receive_time", sources: []}) end,
      fn -> Section.build(:computed_values, %{version: 4, definitions: []}) end,
      fn -> Section.tombstone(:polar) end,
      fn -> Section.build(:tracking, %{version: 5, enabled: true, broadcast_rate_hz: 1.0}) end,
      fn -> Section.build(:upstream, %{version: 1, ais: true, environment: true, instruments: true}) end,
      fn ->
        Section.build(:wifi, %{version: 3, enabled: true, ssid: "kat-network"}, secrets: [secret_descriptor])
      end,
      fn ->
        Section.build(:wind_shift, %{
          version: 7,
          enabled: true,
          damping_seconds: 300.0,
          new_extreme_margin_deg: 2.0
        })
      end
    ]

    Enum.map(builders, fn builder ->
      assert {:ok, section} = builder.()
      section
    end)
  end

  defp manifest_attrs(sections) do
    %{
      device_id: @device_id,
      credential_epoch: 7,
      generation: 42,
      minimum_firmware: "3.0.0",
      required_capabilities: required_capabilities(),
      sections: Enum.map(sections, &Section.descriptor/1)
    }
  end

  defp required_capabilities do
    Contract.capabilities()
    |> Enum.map(fn {name, _id, version} -> {name, version} end)
  end

  defp identity_fields(extra) do
    Map.merge(
      %{
        device_id: @device_id,
        credential_epoch: 7,
        boot_id: @boot_id,
        storage_epoch: @storage_epoch
      },
      extra
    )
  end

  defp replace_version(bytes, version) do
    domain = Contract.payload_domain(:control_accept)
    <<^domain::binary, _old_version, rest::binary>> = bytes
    domain <> <<version>> <> rest
  end
end
