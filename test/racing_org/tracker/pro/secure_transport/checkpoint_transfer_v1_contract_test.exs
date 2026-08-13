defmodule RacingOrg.Tracker.Pro.SecureTransport.CheckpointTransferV1ContractTest do
  use ExUnit.Case, async: true

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Checkpoint, Control, Messages}

  @version 0x01
  @chunk_size 61_440
  @max_content_size 8_388_608
  @max_chunks 137
  @max_missing_ranges 69

  @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
  @submission_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
  @target_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
  @parent_hash :binary.copy(<<0xB2>>, 32)
  @content_hash :binary.copy(<<0xA1>>, 32)

  @submission_common_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content_hash,
    :checkpoint_hash
  ]
  @hydration_common_keys [
    :device_id,
    :credential_epoch,
    :storage_epoch,
    :origin_credential_epoch,
    :origin_storage_epoch,
    :sequence,
    :kind,
    :schema_version,
    :source_generation,
    :parent_hash,
    :content_hash,
    :checkpoint_hash
  ]
  @chunk_keys [
    :total_content_length,
    :chunk_index,
    :chunk_count,
    :chunk_offset,
    :chunk_hash,
    :chunk
  ]
  @resume_keys [:total_content_length, :chunk_count, :missing_ranges]

  describe "closed checkpoint-transfer registry and capacities" do
    test "freezes all four message assignments, reverse lookups, domains, and capacity APIs" do
      expected = [
        {:checkpoint_submission_chunk, 0x34, :device_to_server, "RacingOrg-CheckpointSubmissionChunk-v1"},
        {:checkpoint_submission_resume, 0x35, :server_to_device, "RacingOrg-CheckpointSubmissionResume-v1"},
        {:checkpoint_hydration_chunk, 0x36, :server_to_device, "RacingOrg-CheckpointHydrationChunk-v1"},
        {:checkpoint_hydration_resume, 0x37, :device_to_server, "RacingOrg-CheckpointHydrationResume-v1"}
      ]

      for {type, code, direction, domain} <- expected do
        assert Contract.message_type(type) == {:ok, code, direction}
        assert Contract.message_type(code) == {:ok, type, direction}
        assert Contract.payload_domain(type) == domain
      end

      assert Contract.checkpoint_content_chunk_hash_domain() ==
               "RacingOrg-CheckpointContentChunkHash-v1"

      assert Contract.max_checkpoint_chunks() == @max_chunks
      assert Contract.max_checkpoint_missing_ranges() == @max_missing_ranges
      assert Contract.chunk_size() == @chunk_size
      assert Contract.max_checkpoint_content_size() == @max_content_size
    end
  end

  describe "checkpoint content chunk hashes" do
    test "hashes the exact independently constructed domain-separated preimage" do
      attrs = %{
        checkpoint_hash: :binary.copy(<<0xC3>>, 32),
        total_content_length: 61_441,
        chunk_index: 1,
        chunk_count: 2,
        chunk_offset: @chunk_size,
        chunk: <<0x00, 0xFF, 0x42>>
      }

      preimage = raw_chunk_hash_preimage(attrs)

      assert preimage ==
               "RacingOrg-CheckpointContentChunkHash-v1" <>
                 <<@version, attrs.checkpoint_hash::binary-size(32), 61_441::64, 1::32, 2::32, @chunk_size::64, 3::32,
                   0x00, 0xFF, 0x42>>

      expected_hash = :crypto.hash(:sha256, preimage)
      assert {:ok, ^expected_hash} = Checkpoint.chunk_hash(attrs)

      assert {:error, _reason} = Checkpoint.chunk_hash(Map.put(attrs, :chunk_length, 3))
      assert {:error, _reason} = Checkpoint.chunk_hash(Map.delete(attrs, :chunk))
    end
  end

  describe "checkpoint chunks" do
    test "round-trips and byte-freezes the smallest one-byte transfer in both directions" do
      chunk = <<0x7F>>

      for {type, attrs} <- [
            checkpoint_submission_chunk: submission_chunk_attrs(1, 0, chunk),
            checkpoint_hydration_chunk: hydration_chunk_attrs(1, 0, chunk)
          ] do
        refute Map.has_key?(attrs, :boot_id)
        refute Map.has_key?(attrs, :chunk_length)
        assert_exact_keys(attrs, chunk_keys(type))

        assert {:ok, bytes} = Messages.encode(type, attrs)
        assert bytes == raw_wire(type, attrs)
        assert {:ok, ^attrs} = Messages.decode(type, bytes)

        chunk_hash_attrs = Map.take(attrs, chunk_hash_keys())
        assert {:ok, attrs.chunk_hash} == Checkpoint.chunk_hash(chunk_hash_attrs)
      end
    end

    test "accepts an exact full nonfinal chunk and the exact short final remainder" do
      total_content_length = @chunk_size + 1
      full = :binary.copy(<<0x5A>>, @chunk_size)
      final = <<0xA5>>

      for {type, builder} <- [
            {:checkpoint_submission_chunk, &submission_chunk_attrs/3},
            {:checkpoint_hydration_chunk, &hydration_chunk_attrs/3}
          ],
          {chunk_index, chunk} <- [{0, full}, {1, final}] do
        attrs = builder.(total_content_length, chunk_index, chunk)

        assert attrs.chunk_count == 2
        assert attrs.chunk_offset == chunk_index * @chunk_size
        assert {:ok, bytes} = Messages.encode(type, attrs)
        assert bytes == raw_wire(type, attrs)
        assert {:ok, ^attrs} = Messages.decode(type, bytes)
      end
    end

    test "accepts the exact 8 MiB cap as 137 chunks with the exact final remainder" do
      final_index = @max_chunks - 1
      final_offset = final_index * @chunk_size
      final = :binary.copy(<<0xD4>>, @max_content_size - final_offset)

      assert byte_size(final) == 32_768

      for {type, attrs} <- [
            checkpoint_submission_chunk: submission_chunk_attrs(@max_content_size, final_index, final),
            checkpoint_hydration_chunk: hydration_chunk_attrs(@max_content_size, final_index, final)
          ] do
        assert attrs.chunk_count == @max_chunks
        assert attrs.chunk_offset == final_offset
        assert {:ok, bytes} = Messages.encode(type, attrs)
        assert bytes == raw_wire(type, attrs)
        assert {:ok, ^attrs} = Messages.decode(type, bytes)
      end
    end

    test "rejects 8 MiB plus one and refuses declared counts beyond the 137-chunk cap" do
      total_content_length = @max_content_size + 1
      final_index = @max_chunks - 1
      final_offset = final_index * @chunk_size
      final = :binary.copy(<<0xE5>>, total_content_length - final_offset)

      for {type, attrs} <- [
            checkpoint_submission_chunk: submission_chunk_attrs(total_content_length, final_index, final),
            checkpoint_hydration_chunk: hydration_chunk_attrs(total_content_length, final_index, final)
          ] do
        assert attrs.chunk_count == @max_chunks
        assert {:error, :checkpoint_too_large} = Messages.encode(type, attrs)
      end

      for {type, attrs} <- [
            checkpoint_submission_chunk: submission_chunk_attrs(@max_content_size, 0, full_chunk()),
            checkpoint_hydration_chunk: hydration_chunk_attrs(@max_content_size, 0, full_chunk())
          ] do
        assert {:error, :invalid_chunk_count} =
                 attrs
                 |> Map.put(:chunk_count, @max_chunks + 1)
                 |> rehash_chunk()
                 |> then(&Messages.encode(type, &1))
      end
    end

    test "strictly enforces calculated count, index, offset, and nonfinal/final lengths" do
      valid_first = submission_chunk_attrs(@chunk_size + 1, 0, full_chunk())
      valid_final = submission_chunk_attrs(@chunk_size + 1, 1, <<0xAA>>)

      assert {:error, :invalid_total_content_length} =
               valid_first
               |> Map.put(:total_content_length, 0)
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))

      assert {:error, :invalid_chunk_count} =
               valid_first
               |> Map.put(:chunk_count, 1)
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))

      assert {:error, :invalid_chunk_index} =
               valid_first
               |> Map.put(:chunk_index, 2)
               |> Map.put(:chunk_offset, 2 * @chunk_size)
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))

      assert {:error, :invalid_chunk_offset} =
               valid_first
               |> Map.put(:chunk_offset, 1)
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))

      assert {:error, :invalid_chunk_length} =
               valid_first
               |> Map.put(:chunk, binary_part(full_chunk(), 0, @chunk_size - 1))
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))

      assert {:error, :invalid_chunk_length} =
               valid_final
               |> Map.put(:chunk, <<0xAA, 0xBB>>)
               |> rehash_chunk()
               |> then(&Messages.encode(:checkpoint_submission_chunk, &1))
    end

    test "rejects presented chunk-hash and chunk-byte tampering" do
      attrs = hydration_chunk_attrs(3, 0, <<0x10, 0x20, 0x30>>)

      assert {:error, _reason} =
               Messages.encode(:checkpoint_hydration_chunk, %{
                 attrs
                 | chunk_hash: :binary.copy(<<0xFF>>, 32)
               })

      assert {:ok, bytes} = Messages.encode(:checkpoint_hydration_chunk, attrs)
      last = byte_size(bytes) - 1
      <<prefix::binary-size(last), byte>> = bytes
      tampered = prefix <> <<Bitwise.bxor(byte, 1)>>

      assert {:error, _reason} =
               Messages.decode(:checkpoint_hydration_chunk, tampered)
    end

    test "validates submission checkpoint hashes against the submitting durable identity" do
      attrs = submission_chunk_attrs(3, 0, <<1, 2, 3>>)

      assert {:error, :checkpoint_hash_mismatch} =
               Messages.encode(:checkpoint_submission_chunk, %{attrs | credential_epoch: 8})

      rebound =
        attrs
        |> Map.put(:credential_epoch, 8)
        |> put_submission_checkpoint_hash()
        |> rehash_chunk()

      assert {:ok, bytes} = Messages.encode(:checkpoint_submission_chunk, rebound)
      assert {:ok, ^rebound} = Messages.decode(:checkpoint_submission_chunk, bytes)
    end

    test "validates hydration checkpoint hashes against origin identity, never target identity" do
      attrs = hydration_chunk_attrs(3, 0, <<1, 2, 3>>)
      origin_hash = attrs.checkpoint_hash
      target_hash = raw_checkpoint_hash(attrs, :target)

      refute target_hash == origin_hash
      assert {:ok, bytes} = Messages.encode(:checkpoint_hydration_chunk, attrs)
      assert {:ok, ^attrs} = Messages.decode(:checkpoint_hydration_chunk, bytes)

      target_bound =
        attrs
        |> Map.put(:checkpoint_hash, target_hash)
        |> rehash_chunk()

      assert {:error, :checkpoint_hash_mismatch} =
               Messages.encode(:checkpoint_hydration_chunk, target_bound)

      confused =
        attrs
        |> Map.put(:credential_epoch, attrs.origin_credential_epoch)
        |> Map.put(:storage_epoch, attrs.origin_storage_epoch)
        |> Map.put(:origin_credential_epoch, attrs.credential_epoch)
        |> Map.put(:origin_storage_epoch, attrs.storage_epoch)
        |> rehash_chunk()

      assert {:error, :checkpoint_hash_mismatch} =
               Messages.encode(:checkpoint_hydration_chunk, confused)
    end

    test "does not demand assembled canonical content validation from an individual chunk" do
      chunk = <<0xFF, 0x00, 0x81, 0x82, 0x83>>
      attrs = submission_chunk_attrs(byte_size(chunk), 0, chunk)

      refute attrs.content_hash == :crypto.hash(:sha256, chunk)
      assert {:error, _reason} = Checkpoint.decode_canonical_content(:polar, 2, chunk)

      assert {:ok, bytes} = Messages.encode(:checkpoint_submission_chunk, attrs)
      assert {:ok, ^attrs} = Messages.decode(:checkpoint_submission_chunk, bytes)
    end
  end

  describe "checkpoint resumes" do
    test "round-trips and byte-freezes the smallest nonempty missing-range request" do
      missing_ranges = [%{first_chunk_index: 0, chunk_count: 1}]

      for {type, attrs} <- [
            checkpoint_submission_resume: submission_resume_attrs(1, missing_ranges),
            checkpoint_hydration_resume: hydration_resume_attrs(1, missing_ranges)
          ] do
        refute Map.has_key?(attrs, :boot_id)
        refute Map.has_key?(attrs, :missing_range_count)
        assert_exact_keys(attrs, resume_keys(type))

        assert {:ok, bytes} = Messages.encode(type, attrs)
        assert bytes == raw_wire(type, attrs)
        assert {:ok, ^attrs} = Messages.decode(type, bytes)
      end
    end

    test "accepts exactly 69 sorted separated ranges across the 137-chunk maximum" do
      missing_ranges =
        for first_chunk_index <- 0..136//2 do
          %{first_chunk_index: first_chunk_index, chunk_count: 1}
        end

      assert length(missing_ranges) == @max_missing_ranges

      for {type, attrs} <- [
            checkpoint_submission_resume: submission_resume_attrs(@max_content_size, missing_ranges),
            checkpoint_hydration_resume: hydration_resume_attrs(@max_content_size, missing_ranges)
          ] do
        assert attrs.chunk_count == @max_chunks
        assert {:ok, bytes} = Messages.encode(type, attrs)
        assert bytes == raw_wire(type, attrs)
        assert {:ok, ^attrs} = Messages.decode(type, bytes)
      end
    end

    test "requires exact calculated chunk count and rejects content beyond 8 MiB" do
      ranges = [%{first_chunk_index: 0, chunk_count: 1}]

      for {type, attrs} <- [
            checkpoint_submission_resume: submission_resume_attrs(@chunk_size + 1, ranges),
            checkpoint_hydration_resume: hydration_resume_attrs(@chunk_size + 1, ranges)
          ] do
        assert attrs.chunk_count == 2

        assert {:error, :invalid_chunk_count} =
                 attrs
                 |> Map.put(:chunk_count, 1)
                 |> then(&Messages.encode(type, &1))
      end

      for {type, attrs} <- [
            checkpoint_submission_resume: submission_resume_attrs(@max_content_size + 1, ranges),
            checkpoint_hydration_resume: hydration_resume_attrs(@max_content_size + 1, ranges)
          ] do
        assert attrs.chunk_count == @max_chunks
        assert {:error, :checkpoint_too_large} = Messages.encode(type, attrs)
      end
    end

    test "rejects empty, zero-length, outside, unsorted, overlapping, and adjacent ranges" do
      total_content_length = 6 * @chunk_size

      invalid_ranges = [
        {[], :invalid_missing_ranges},
        {[%{first_chunk_index: 0, chunk_count: 0}], :invalid_missing_range},
        {[%{first_chunk_index: 6, chunk_count: 1}], :invalid_missing_range},
        {[
           %{first_chunk_index: 4, chunk_count: 1},
           %{first_chunk_index: 0, chunk_count: 1}
         ], :nonminimal_missing_ranges},
        {[
           %{first_chunk_index: 0, chunk_count: 3},
           %{first_chunk_index: 2, chunk_count: 1}
         ], :nonminimal_missing_ranges},
        {[
           %{first_chunk_index: 0, chunk_count: 1},
           %{first_chunk_index: 1, chunk_count: 1}
         ], :nonminimal_missing_ranges}
      ]

      for {type, builder} <- [
            {:checkpoint_submission_resume, &submission_resume_attrs/2},
            {:checkpoint_hydration_resume, &hydration_resume_attrs/2}
          ],
          {missing_ranges, reason} <- invalid_ranges do
        assert {:error, ^reason} =
                 type
                 |> then(fn message_type ->
                   Messages.encode(
                     message_type,
                     builder.(total_content_length, missing_ranges)
                   )
                 end)
      end
    end

    test "rejects more than 69 ranges before accepting a noncanonical range list" do
      too_many =
        for first_chunk_index <- 0..69 do
          %{first_chunk_index: first_chunk_index, chunk_count: 1}
        end

      for {type, attrs} <- [
            checkpoint_submission_resume: submission_resume_attrs(@max_content_size, too_many),
            checkpoint_hydration_resume: hydration_resume_attrs(@max_content_size, too_many)
          ] do
        assert length(attrs.missing_ranges) == @max_missing_ranges + 1
        assert {:error, :too_many_missing_ranges} = Messages.encode(type, attrs)
      end
    end

    test "requires exact atom keys for each range" do
      valid =
        submission_resume_attrs(3 * @chunk_size, [
          %{first_chunk_index: 0, chunk_count: 1}
        ])

      extra = put_in(valid, [:missing_ranges, Access.at(0), :last_chunk_index], 0)

      string_key =
        put_in(valid, [:missing_ranges], [
          %{"first_chunk_index" => 0, chunk_count: 1}
        ])

      assert {:error, :invalid_missing_range} =
               Messages.encode(:checkpoint_submission_resume, extra)

      assert {:error, :invalid_missing_range} =
               Messages.encode(:checkpoint_submission_resume, string_key)
    end

    test "validates hydration resume checkpoint hashes against origin rather than target" do
      attrs =
        hydration_resume_attrs(3 * @chunk_size, [
          %{first_chunk_index: 0, chunk_count: 1}
        ])

      assert {:ok, bytes} = Messages.encode(:checkpoint_hydration_resume, attrs)
      assert {:ok, ^attrs} = Messages.decode(:checkpoint_hydration_resume, bytes)

      target_bound = Map.put(attrs, :checkpoint_hash, raw_checkpoint_hash(attrs, :target))

      assert {:error, :checkpoint_hash_mismatch} =
               Messages.encode(:checkpoint_hydration_resume, target_bound)
    end
  end

  describe "closed shapes and strict envelopes" do
    test "requires exact atom keys and excludes boot and derived wire-length fields" do
      fixtures = all_smallest_fixtures()

      for {type, attrs} <- fixtures do
        keys = if type in chunk_types(), do: chunk_keys(type), else: resume_keys(type)
        invalid_reason = invalid_shape_reason(type)
        first_key = hd(keys)

        refute Map.has_key?(attrs, :boot_id)
        refute Map.has_key?(attrs, :chunk_length)
        refute Map.has_key?(attrs, :missing_range_count)
        assert_exact_keys(attrs, keys)

        assert {:error, ^invalid_reason} =
                 Messages.encode(type, Map.put(attrs, :boot_id, <<0::128>>))

        assert {:error, ^invalid_reason} =
                 Messages.encode(type, Map.delete(attrs, first_key))

        string_keyed =
          attrs
          |> Map.delete(first_key)
          |> Map.put(Atom.to_string(first_key), Map.fetch!(attrs, first_key))

        assert {:error, ^invalid_reason} = Messages.encode(type, string_keyed)
      end
    end

    test "rejects wrong domains, versions, types, truncation, and trailing bytes for all four" do
      for {type, attrs} <- all_smallest_fixtures() do
        assert {:ok, bytes} = Messages.encode(type, attrs)

        assert {:error, :payload_domain_mismatch} =
                 Messages.decode(type, replace_bytes(bytes, 0, <<0>>))

        assert {:error, :unsupported_payload_version} =
                 Messages.decode(type, replace_version(bytes, type, @version + 1))

        assert {:error, :payload_type_mismatch} =
                 Messages.decode(type, replace_type(bytes, type, wrong_type_code(type)))

        assert {:error, :truncated} =
                 Messages.decode(type, binary_part(bytes, 0, byte_size(bytes) - 1))

        assert {:error, :trailing_bytes} = Messages.decode(type, bytes <> <<0>>)
      end
    end

    test "control sealing accepts only each registered direction for all four messages" do
      key = :binary.copy(<<0x5A>>, 32)
      session_id = :binary.copy(<<0x6B>>, 16)

      for {type, attrs} <- all_smallest_fixtures() do
        assert {:ok, payload} = Messages.encode(type, attrs)
        direction = direction(type)
        wrong_direction = opposite_direction(direction)

        assert {:ok, _frame} =
                 Control.seal_with(key, session_id, 7, direction, type, 0, payload)

        assert {:error, :wrong_message_direction} =
                 Control.seal_with(key, session_id, 7, wrong_direction, type, 0, payload)
      end
    end
  end

  defp all_smallest_fixtures do
    missing_ranges = [%{first_chunk_index: 0, chunk_count: 1}]

    [
      checkpoint_submission_chunk: submission_chunk_attrs(1, 0, <<0x11>>),
      checkpoint_submission_resume: submission_resume_attrs(1, missing_ranges),
      checkpoint_hydration_chunk: hydration_chunk_attrs(1, 0, <<0x22>>),
      checkpoint_hydration_resume: hydration_resume_attrs(1, missing_ranges)
    ]
  end

  defp submission_chunk_attrs(total_content_length, chunk_index, chunk) do
    submission_common_attrs()
    |> Map.merge(chunk_geometry(total_content_length, chunk_index, chunk))
    |> rehash_chunk()
  end

  defp hydration_chunk_attrs(total_content_length, chunk_index, chunk) do
    hydration_common_attrs()
    |> Map.merge(chunk_geometry(total_content_length, chunk_index, chunk))
    |> rehash_chunk()
  end

  defp submission_resume_attrs(total_content_length, missing_ranges) do
    Map.merge(submission_common_attrs(), %{
      total_content_length: total_content_length,
      chunk_count: calculated_chunk_count(total_content_length),
      missing_ranges: missing_ranges
    })
  end

  defp hydration_resume_attrs(total_content_length, missing_ranges) do
    Map.merge(hydration_common_attrs(), %{
      total_content_length: total_content_length,
      chunk_count: calculated_chunk_count(total_content_length),
      missing_ranges: missing_ranges
    })
  end

  defp submission_common_attrs do
    attrs = %{
      device_id: @device_id,
      credential_epoch: 7,
      storage_epoch: @submission_storage_epoch,
      sequence: 11,
      kind: :polar,
      schema_version: 2,
      source_generation: 42,
      parent_hash: @parent_hash,
      content_hash: @content_hash
    }

    Map.put(attrs, :checkpoint_hash, raw_checkpoint_hash(attrs, :submission))
  end

  defp hydration_common_attrs do
    attrs = %{
      device_id: @device_id,
      credential_epoch: 8,
      storage_epoch: @target_storage_epoch,
      origin_credential_epoch: 7,
      origin_storage_epoch: @submission_storage_epoch,
      sequence: 11,
      kind: :polar,
      schema_version: 2,
      source_generation: 42,
      parent_hash: @parent_hash,
      content_hash: @content_hash
    }

    Map.put(attrs, :checkpoint_hash, raw_checkpoint_hash(attrs, :origin))
  end

  defp chunk_geometry(total_content_length, chunk_index, chunk) do
    %{
      total_content_length: total_content_length,
      chunk_index: chunk_index,
      chunk_count: calculated_chunk_count(total_content_length),
      chunk_offset: chunk_index * @chunk_size,
      chunk_hash: <<0::256>>,
      chunk: chunk
    }
  end

  defp put_submission_checkpoint_hash(attrs) do
    Map.put(attrs, :checkpoint_hash, raw_checkpoint_hash(attrs, :submission))
  end

  defp rehash_chunk(attrs) do
    chunk_hash =
      attrs
      |> Map.take(chunk_hash_keys())
      |> raw_chunk_hash()

    Map.put(attrs, :chunk_hash, chunk_hash)
  end

  defp raw_chunk_hash(attrs) do
    attrs
    |> raw_chunk_hash_preimage()
    |> then(&:crypto.hash(:sha256, &1))
  end

  defp raw_chunk_hash_preimage(attrs) do
    "RacingOrg-CheckpointContentChunkHash-v1" <>
      <<@version, attrs.checkpoint_hash::binary-size(32), attrs.total_content_length::64, attrs.chunk_index::32,
        attrs.chunk_count::32, attrs.chunk_offset::64, byte_size(attrs.chunk)::32, attrs.chunk::binary>>
  end

  defp raw_checkpoint_hash(attrs, identity) do
    {credential_epoch, storage_epoch} = checkpoint_identity(attrs, identity)

    preimage =
      "RacingOrg-CheckpointRecordHash-v1" <>
        <<@version, attrs.device_id::binary-size(16), credential_epoch::32, storage_epoch::binary-size(16),
          attrs.sequence::64, kind_code(attrs.kind), attrs.schema_version::16, attrs.source_generation::64,
          attrs.parent_hash::binary-size(32), attrs.content_hash::binary-size(32)>>

    :crypto.hash(:sha256, preimage)
  end

  defp checkpoint_identity(attrs, :submission),
    do: {attrs.credential_epoch, attrs.storage_epoch}

  defp checkpoint_identity(attrs, :target),
    do: {attrs.credential_epoch, attrs.storage_epoch}

  defp checkpoint_identity(attrs, :origin),
    do: {attrs.origin_credential_epoch, attrs.origin_storage_epoch}

  defp raw_wire(type, attrs) do
    payload_domain(type) <> <<@version, message_code(type)>> <> raw_body(type, attrs)
  end

  defp raw_body(:checkpoint_submission_chunk, attrs) do
    raw_submission_common(attrs) <>
      <<attrs.total_content_length::64, attrs.chunk_index::32, attrs.chunk_count::32, attrs.chunk_offset::64,
        attrs.chunk_hash::binary-size(32), byte_size(attrs.chunk)::32, attrs.chunk::binary>>
  end

  defp raw_body(:checkpoint_hydration_chunk, attrs) do
    raw_hydration_common(attrs) <>
      <<attrs.total_content_length::64, attrs.chunk_index::32, attrs.chunk_count::32, attrs.chunk_offset::64,
        attrs.chunk_hash::binary-size(32), byte_size(attrs.chunk)::32, attrs.chunk::binary>>
  end

  defp raw_body(:checkpoint_submission_resume, attrs) do
    raw_submission_common(attrs) <>
      <<attrs.total_content_length::64, attrs.chunk_count::32, length(attrs.missing_ranges)::16>> <>
      raw_ranges(attrs.missing_ranges)
  end

  defp raw_body(:checkpoint_hydration_resume, attrs) do
    raw_hydration_common(attrs) <>
      <<attrs.total_content_length::64, attrs.chunk_count::32, length(attrs.missing_ranges)::16>> <>
      raw_ranges(attrs.missing_ranges)
  end

  defp raw_submission_common(attrs) do
    <<attrs.device_id::binary-size(16), attrs.credential_epoch::32, attrs.storage_epoch::binary-size(16),
      attrs.sequence::64, kind_code(attrs.kind), attrs.schema_version::16, attrs.source_generation::64,
      attrs.parent_hash::binary-size(32), attrs.content_hash::binary-size(32), attrs.checkpoint_hash::binary-size(32)>>
  end

  defp raw_hydration_common(attrs) do
    <<attrs.device_id::binary-size(16), attrs.credential_epoch::32, attrs.storage_epoch::binary-size(16),
      attrs.origin_credential_epoch::32, attrs.origin_storage_epoch::binary-size(16), attrs.sequence::64,
      kind_code(attrs.kind), attrs.schema_version::16, attrs.source_generation::64, attrs.parent_hash::binary-size(32),
      attrs.content_hash::binary-size(32), attrs.checkpoint_hash::binary-size(32)>>
  end

  defp raw_ranges(ranges) do
    ranges
    |> Enum.map(fn range ->
      <<range.first_chunk_index::32, range.chunk_count::32>>
    end)
    |> IO.iodata_to_binary()
  end

  defp calculated_chunk_count(total_content_length),
    do: div(total_content_length + @chunk_size - 1, @chunk_size)

  defp full_chunk, do: :binary.copy(<<0x5A>>, @chunk_size)

  defp assert_exact_keys(attrs, keys) do
    assert Enum.sort(Map.keys(attrs)) == Enum.sort(keys)
  end

  defp chunk_hash_keys do
    [
      :checkpoint_hash,
      :total_content_length,
      :chunk_index,
      :chunk_count,
      :chunk_offset,
      :chunk
    ]
  end

  defp chunk_keys(:checkpoint_submission_chunk),
    do: @submission_common_keys ++ @chunk_keys

  defp chunk_keys(:checkpoint_hydration_chunk),
    do: @hydration_common_keys ++ @chunk_keys

  defp resume_keys(:checkpoint_submission_resume),
    do: @submission_common_keys ++ @resume_keys

  defp resume_keys(:checkpoint_hydration_resume),
    do: @hydration_common_keys ++ @resume_keys

  defp chunk_types,
    do: [:checkpoint_submission_chunk, :checkpoint_hydration_chunk]

  defp invalid_shape_reason(:checkpoint_submission_chunk),
    do: :invalid_checkpoint_submission_chunk

  defp invalid_shape_reason(:checkpoint_submission_resume),
    do: :invalid_checkpoint_submission_resume

  defp invalid_shape_reason(:checkpoint_hydration_chunk),
    do: :invalid_checkpoint_hydration_chunk

  defp invalid_shape_reason(:checkpoint_hydration_resume),
    do: :invalid_checkpoint_hydration_resume

  defp kind_code(:polar), do: 0x02

  defp payload_domain(:checkpoint_submission_chunk),
    do: "RacingOrg-CheckpointSubmissionChunk-v1"

  defp payload_domain(:checkpoint_submission_resume),
    do: "RacingOrg-CheckpointSubmissionResume-v1"

  defp payload_domain(:checkpoint_hydration_chunk),
    do: "RacingOrg-CheckpointHydrationChunk-v1"

  defp payload_domain(:checkpoint_hydration_resume),
    do: "RacingOrg-CheckpointHydrationResume-v1"

  defp message_code(:checkpoint_submission_chunk), do: 0x34
  defp message_code(:checkpoint_submission_resume), do: 0x35
  defp message_code(:checkpoint_hydration_chunk), do: 0x36
  defp message_code(:checkpoint_hydration_resume), do: 0x37

  defp wrong_type_code(:checkpoint_submission_chunk), do: 0x35
  defp wrong_type_code(:checkpoint_submission_resume), do: 0x34
  defp wrong_type_code(:checkpoint_hydration_chunk), do: 0x37
  defp wrong_type_code(:checkpoint_hydration_resume), do: 0x36

  defp direction(:checkpoint_submission_chunk), do: :device_to_server
  defp direction(:checkpoint_submission_resume), do: :server_to_device
  defp direction(:checkpoint_hydration_chunk), do: :server_to_device
  defp direction(:checkpoint_hydration_resume), do: :device_to_server

  defp opposite_direction(:device_to_server), do: :server_to_device
  defp opposite_direction(:server_to_device), do: :device_to_server

  defp replace_version(bytes, type, version) do
    domain = payload_domain(type)
    <<^domain::binary, _old_version, rest::binary>> = bytes
    domain <> <<version>> <> rest
  end

  defp replace_type(bytes, type, type_code) do
    domain = payload_domain(type)
    <<^domain::binary, version, _old_type, rest::binary>> = bytes
    domain <> <<version, type_code>> <> rest
  end

  defp replace_bytes(bytes, offset, replacement) do
    <<prefix::binary-size(offset), _old::binary-size(byte_size(replacement)), suffix::binary>> =
      bytes

    prefix <> replacement <> suffix
  end
end
