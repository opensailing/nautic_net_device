Code.require_file(Path.expand("../../../../support/backend_checkpoint_transfer_direct_source.exs", __DIR__))

defmodule RacingOrg.Tracker.Pro.SecureTransport.CheckpointTransferV1CrossRepoTest do
  use ExUnit.Case, async: false

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages
  alias RacingOrg.Tracker.Pro.TestSupport.BackendCheckpointTransferDirectSource, as: Backend

  @types [
    :checkpoint_submission_chunk,
    :checkpoint_submission_resume,
    :checkpoint_hydration_chunk,
    :checkpoint_hydration_resume
  ]

  setup_all do
    {:ok, backend: Backend.snapshot!()}
  end

  test "direct backend source freezes the same version, capacities, assignments, directions, and domains",
       %{backend: backend} do
    expected_messages = %{
      checkpoint_submission_chunk: %{
        code: 0x34,
        direction: :device_to_server,
        domain: "RacingOrg-CheckpointSubmissionChunk-v1"
      },
      checkpoint_submission_resume: %{
        code: 0x35,
        direction: :server_to_device,
        domain: "RacingOrg-CheckpointSubmissionResume-v1"
      },
      checkpoint_hydration_chunk: %{
        code: 0x36,
        direction: :server_to_device,
        domain: "RacingOrg-CheckpointHydrationChunk-v1"
      },
      checkpoint_hydration_resume: %{
        code: 0x37,
        direction: :device_to_server,
        domain: "RacingOrg-CheckpointHydrationResume-v1"
      }
    }

    expected_contract = %{
      version: 0x01,
      chunk_size: 61_440,
      max_checkpoint_content_size: 8_388_608,
      max_checkpoint_chunks: 137,
      max_checkpoint_missing_ranges: 69,
      chunk_hash_domain: "RacingOrg-CheckpointContentChunkHash-v1",
      messages: expected_messages
    }

    assert backend.contract == expected_contract

    tracker_contract = %{
      version: Contract.version(),
      chunk_size: Contract.chunk_size(),
      max_checkpoint_content_size: Contract.max_checkpoint_content_size(),
      max_checkpoint_chunks: Contract.max_checkpoint_chunks(),
      max_checkpoint_missing_ranges: Contract.max_checkpoint_missing_ranges(),
      chunk_hash_domain: Contract.checkpoint_content_chunk_hash_domain(),
      messages:
        Map.new(@types, fn type ->
          {:ok, code, direction} = Contract.message_type(type)
          {type, %{code: code, direction: direction, domain: Contract.payload_domain(type)}}
        end)
    }

    assert tracker_contract == backend.contract

    for {type, %{code: code, direction: direction}} <- expected_messages do
      assert Contract.message_type(code) == {:ok, type, direction}
      assert backend.reverse_message_types[code] == {:ok, type, direction}
    end
  end

  test "both repositories' JSON KAT entries match and round-trip through both codecs", %{
    backend: backend
  } do
    tracker_kat = tracker_kat_entries()

    assert Map.keys(backend.kat_entries) |> Enum.sort() == Enum.sort(@types)
    assert Map.keys(tracker_kat) |> Enum.sort() == Enum.sort(@types)
    assert tracker_kat == backend.kat_entries

    for type <- @types do
      bytes = Base.decode16!(Map.fetch!(tracker_kat, type), case: :lower)
      backend_codec = Map.fetch!(backend.kat_codecs, type)

      assert backend_codec.decode == Messages.decode(type, bytes)
      assert {:ok, attrs} = backend_codec.decode
      assert backend_codec.encode == {:ok, bytes}
      assert Messages.encode(type, attrs) == backend_codec.encode
    end
  end

  test "representative valid vectors have byte-identical backend and tracker encode/decode output",
       %{backend: backend} do
    assert backend.valid_vectors != []

    for vector <- backend.valid_vectors do
      assert {:ok, bytes} = vector.encode
      assert vector.decode == {:ok, vector.attrs}
      assert Messages.encode(vector.type, vector.attrs) == vector.encode
      assert Messages.decode(vector.type, bytes) == vector.decode
    end

    chunk_vectors = Enum.filter(backend.valid_vectors, &String.ends_with?(&1.id, ".chunk"))

    assert MapSet.new(Enum.map(chunk_vectors, & &1.attrs.total_content_length)) ==
             MapSet.new([1, 61_440, 61_441, 8_388_608])

    for type <- [:checkpoint_submission_chunk, :checkpoint_hydration_chunk] do
      full_nonfinal = vector!(backend, "#{type}:61441:0.chunk")
      short_final = vector!(backend, "#{type}:61441:1.chunk")
      maximum = vector!(backend, "#{type}:8388608:136.chunk")

      assert full_nonfinal.attrs.chunk_count == 2
      assert full_nonfinal.attrs.chunk_offset == 0
      assert byte_size(full_nonfinal.attrs.chunk) == 61_440

      assert short_final.attrs.chunk_count == 2
      assert short_final.attrs.chunk_offset == 61_440
      assert byte_size(short_final.attrs.chunk) == 1

      assert maximum.attrs.chunk_count == 137
      assert maximum.attrs.chunk_index == 136
      assert maximum.attrs.chunk_offset == 136 * 61_440
      assert byte_size(maximum.attrs.chunk) == 32_768
    end

    for type <- [:checkpoint_submission_resume, :checkpoint_hydration_resume] do
      maximum = vector!(backend, "#{type}:8388608.resume")

      assert maximum.attrs.chunk_count == 137
      assert length(maximum.attrs.missing_ranges) == 69
      assert List.first(maximum.attrs.missing_ranges) == %{first_chunk_index: 0, chunk_count: 1}
      assert List.last(maximum.attrs.missing_ranges) == %{first_chunk_index: 136, chunk_count: 1}
    end
  end

  test "all four codecs reject 8 MiB plus one with the same exact error", %{backend: backend} do
    assert Enum.map(backend.over_capacity_vectors, & &1.type) |> Enum.sort() == Enum.sort(@types)

    for vector <- backend.over_capacity_vectors do
      assert vector.attrs.total_content_length == 8_388_609
      assert vector.encode == {:error, :checkpoint_too_large}
      assert Messages.encode(vector.type, vector.attrs) == vector.encode
    end
  end

  test "representative field and envelope mutations retain exact matching error atoms", %{
    backend: backend
  } do
    expected_encode_errors = %{
      "checkpoint_submission_chunk.total_content_length" => :invalid_total_content_length,
      "checkpoint_submission_chunk.chunk_count" => :invalid_chunk_count,
      "checkpoint_submission_chunk.chunk_index" => :invalid_chunk_index,
      "checkpoint_submission_chunk.chunk_offset" => :invalid_chunk_offset,
      "checkpoint_submission_chunk.chunk" => :invalid_chunk_length,
      "checkpoint_submission_chunk.chunk_hash" => :checkpoint_chunk_hash_mismatch,
      "checkpoint_submission_chunk.credential_epoch" => :checkpoint_hash_mismatch,
      "checkpoint_hydration_chunk.boot_id" => :invalid_checkpoint_hydration_chunk,
      "checkpoint_submission_resume.missing_ranges_empty" => :invalid_missing_ranges,
      "checkpoint_submission_resume.missing_range_zero" => :invalid_missing_range,
      "checkpoint_submission_resume.missing_ranges_adjacent" => :nonminimal_missing_ranges,
      "checkpoint_submission_resume.missing_ranges_over_cap" => :too_many_missing_ranges
    }

    encode_mutations = Enum.filter(backend.mutations, &(&1.operation == :encode))
    decode_mutations = Enum.filter(backend.mutations, &(&1.operation == :decode))

    assert Map.new(encode_mutations, &{&1.id, error_atom(&1.result)}) == expected_encode_errors

    for mutation <- encode_mutations do
      assert Messages.encode(mutation.type, mutation.input) == mutation.result
    end

    expected_decode_errors =
      for type <- @types,
          {suffix, reason} <- [
            domain: :payload_domain_mismatch,
            version: :unsupported_payload_version,
            type: :payload_type_mismatch,
            truncated: :truncated,
            trailing: :trailing_bytes
          ],
          into: %{} do
        {"#{type}.#{suffix}", reason}
      end

    assert Map.new(decode_mutations, &{&1.id, error_atom(&1.result)}) == expected_decode_errors

    for mutation <- decode_mutations do
      assert Messages.decode(mutation.type, mutation.input) == mutation.result
    end
  end

  defp tracker_kat_entries do
    path = Path.expand("../../../../../priv/secure_transport/desired_state_v1_kat.json", __DIR__)
    messages = path |> File.read!() |> Jason.decode!() |> get_in(["expected", "messages"])

    Map.new(@types, fn type ->
      {type, Map.fetch!(messages, "#{type}_hex")}
    end)
  end

  defp vector!(backend, id) do
    Enum.find(backend.valid_vectors, &(&1.id == id)) || flunk("missing backend vector #{id}")
  end

  defp error_atom({:error, reason}), do: reason
end
