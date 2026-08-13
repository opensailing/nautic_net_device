defmodule RacingOrg.Tracker.Pro.TestSupport.BackendCheckpointTransferDirectSource do
  @moduledoc false

  @backend_env "RACING_ORG_BACKEND_PATH"
  @default_backend_root Path.expand("../racing_org/website/backend", File.cwd!())

  @source_files [
    "lib/racing_org/secure_transport/desired_state_v1.ex",
    "lib/racing_org/secure_transport/desired_state_v1/canonical.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/calibration.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/polar.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint_runtime/wind_shift.ex",
    "lib/racing_org/secure_transport/desired_state_v1/checkpoint.ex",
    "lib/racing_org/secure_transport/desired_state_v1/section.ex",
    "lib/racing_org/secure_transport/desired_state_v1/manifest.ex",
    "lib/racing_org/secure_transport/desired_state_v1/command.ex",
    "lib/racing_org/secure_transport/desired_state_v1/receipt.ex",
    "lib/racing_org/secure_transport/desired_state_v1/messages.ex"
  ]

  @kat_path "priv/secure_transport/desired_state_v1_kat.json"

  @types [
    :checkpoint_submission_chunk,
    :checkpoint_submission_resume,
    :checkpoint_hydration_chunk,
    :checkpoint_hydration_resume
  ]

  def snapshot! do
    backend_root = backend_root!()
    script = script(backend_root)

    {output, status} =
      System.cmd("elixir", ["-e", script],
        cd: File.cwd!(),
        env: [{"ERL_AFLAGS", "+S 2:2"}],
        stderr_to_stdout: true
      )

    if status == 0 do
      case String.split(output, "BACKEND_CHECKPOINT_TRANSFER_FIXTURE:", parts: 2) do
        ["", fixture] ->
          fixture
          |> String.trim()
          |> Base.decode64!()
          |> :erlang.binary_to_term()

        [compiler_output, _fixture] ->
          raise "backend direct-source checkpoint transfer probe emitted compiler output:\n#{compiler_output}"

        _ ->
          raise "backend direct-source checkpoint transfer probe emitted no fixture:\n#{output}"
      end
    else
      raise "backend direct-source checkpoint transfer probe exited with #{status}:\n#{output}"
    end
  end

  def backend_root! do
    root = System.get_env(@backend_env, @default_backend_root) |> Path.expand()
    required = @source_files ++ [@kat_path]

    missing = Enum.reject(required, &File.regular?(Path.join(root, &1)))

    if missing == [] do
      root
    else
      raise """
      checkpoint transfer backend direct source is unavailable at #{root}

      Set #{@backend_env} to the backend root containing:
      #{Enum.map_join(missing, "\n", &"  - #{&1}")}
      """
    end
  end

  defp script(backend_root) do
    source_paths = Enum.map(@source_files, &Path.join(backend_root, &1))
    kat_path = Path.join(backend_root, @kat_path)

    """
    Code.put_compiler_option(:no_warn_undefined, :all)

    Enum.each(#{inspect(source_paths)}, &Code.require_file/1)

    defmodule BackendCheckpointTransferDirectSourceProbe do
      alias RacingOrg.SecureTransport.DesiredStateV1, as: Contract
      alias RacingOrg.SecureTransport.DesiredStateV1.{Checkpoint, Messages}

      @types #{inspect(@types)}
      @chunk_size 61_440
      @max_content_size 8_388_608
      @device_id Base.decode16!("00112233445566778899aabbccddeeff", case: :lower)
      @submission_storage_epoch Base.decode16!("ffeeddccbbaa99887766554433221100", case: :lower)
      @target_storage_epoch Base.decode16!("102132435465768798a9bacbdcedfe0f", case: :lower)
      @parent_hash :binary.copy(<<0xB2>>, 32)
      @content_hash :binary.copy(<<0xA1>>, 32)

      def run(kat_path) do
        valid_vectors = valid_vectors()

        %{
          contract: contract(),
          reverse_message_types: reverse_message_types(),
          kat_entries: kat_entries(kat_path),
          kat_codecs: kat_codecs(kat_path),
          valid_vectors: valid_vectors,
          over_capacity_vectors: over_capacity_vectors(),
          mutations: mutations(valid_vectors)
        }
      end

      defp contract do
        %{
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
      end

      defp reverse_message_types do
        Map.new(@types, fn type ->
          {:ok, code, _direction} = Contract.message_type(type)
          {code, Contract.message_type(code)}
        end)
      end

      defp kat_entries(kat_path) do
        messages = json_kat_messages(kat_path)

        Map.new(@types, fn type ->
          {type, extract_json_hex!(messages, Atom.to_string(type) <> "_hex")}
        end)
      end

      defp kat_codecs(kat_path) do
        Map.new(kat_entries(kat_path), fn {type, hex} ->
          bytes = Base.decode16!(hex, case: :lower)
          decode = Messages.decode(type, bytes)

          encode =
            case decode do
              {:ok, attrs} -> Messages.encode(type, attrs)
              {:error, _reason} = error -> error
            end

          {type, %{encode: encode, decode: decode}}
        end)
      end

      defp json_kat_messages(kat_path) do
        json = File.read!(kat_path)
        marker = ~S("messages": {)
        start = :binary.match(json, marker) |> elem(0)
        open = start + byte_size(marker) - 1
        extract_json_object(json, open)
      end

      defp extract_json_object(json, open) do
        length = find_json_object_end(json, open + 1, 1, false, false)
        binary_part(json, open, length - open + 1)
      end

      defp find_json_object_end(json, index, depth, in_string, escaped) do
        <<_prefix::binary-size(index), byte, _rest::binary>> = json

        cond do
          in_string and escaped -> find_json_object_end(json, index + 1, depth, true, false)
          in_string and byte == 0x5C -> find_json_object_end(json, index + 1, depth, true, true)
          byte == ?" -> find_json_object_end(json, index + 1, depth, not in_string, false)
          in_string -> find_json_object_end(json, index + 1, depth, true, false)
          byte == ?{ -> find_json_object_end(json, index + 1, depth + 1, false, false)
          byte == ?} and depth == 1 -> index
          byte == ?} -> find_json_object_end(json, index + 1, depth - 1, false, false)
          true -> find_json_object_end(json, index + 1, depth, false, false)
        end
      end

      defp extract_json_hex!(messages, key) do
        pattern = ~r/"\#{Regex.escape(key)}"\\s*:\\s*"([0-9a-f]+)"/

        case Regex.run(pattern, messages, capture: :all_but_first) do
          [hex] -> hex
          _ -> raise "missing backend JSON KAT entry \#{key}"
        end
      end

      defp valid_vectors do
        chunk_vectors =
          for type <- [:checkpoint_submission_chunk, :checkpoint_hydration_chunk],
              {total, index} <- [{1, 0}, {@chunk_size, 0}, {@chunk_size + 1, 0}, {@chunk_size + 1, 1}, {@max_content_size, 136}] do
            attrs = chunk_attrs(type, total, index)
            codec_vector("\#{type}:\#{total}:\#{index}.chunk", type, attrs)
          end

        ranges = separated_ranges(69)

        resume_vectors =
          for type <- [:checkpoint_submission_resume, :checkpoint_hydration_resume],
              total <- [1, @chunk_size, @chunk_size + 1, @max_content_size] do
            attrs = resume_attrs(type, total, if(total == @max_content_size, do: ranges, else: [%{first_chunk_index: 0, chunk_count: 1}]))
            codec_vector("\#{type}:\#{total}.resume", type, attrs)
          end

        chunk_vectors ++ resume_vectors
      end

      defp over_capacity_vectors do
        for type <- @types do
          attrs =
            if type in [:checkpoint_submission_chunk, :checkpoint_hydration_chunk],
              do: chunk_attrs(type, @max_content_size + 1, 136),
              else: resume_attrs(type, @max_content_size + 1, [%{first_chunk_index: 0, chunk_count: 1}])

          %{type: type, attrs: attrs, encode: Messages.encode(type, attrs)}
        end
      end

      defp mutations(valid_vectors) do
        submission_chunk = vector_attrs!(valid_vectors, "checkpoint_submission_chunk:61441:0.chunk")
        hydration_chunk = vector_attrs!(valid_vectors, "checkpoint_hydration_chunk:1:0.chunk")
        submission_resume = vector_attrs!(valid_vectors, "checkpoint_submission_resume:8388608.resume")

        encode_mutations = [
          encode_mutation("checkpoint_submission_chunk.total_content_length", :checkpoint_submission_chunk, rehash_chunk(%{submission_chunk | total_content_length: 0})),
          encode_mutation("checkpoint_submission_chunk.chunk_count", :checkpoint_submission_chunk, rehash_chunk(%{submission_chunk | chunk_count: 1})),
          encode_mutation("checkpoint_submission_chunk.chunk_index", :checkpoint_submission_chunk, rehash_chunk(%{submission_chunk | chunk_index: 2, chunk_offset: 2 * @chunk_size})),
          encode_mutation("checkpoint_submission_chunk.chunk_offset", :checkpoint_submission_chunk, rehash_chunk(%{submission_chunk | chunk_offset: 1})),
          encode_mutation("checkpoint_submission_chunk.chunk", :checkpoint_submission_chunk, submission_chunk |> Map.put(:chunk, binary_part(submission_chunk.chunk, 0, @chunk_size - 1)) |> rehash_chunk()),
          encode_mutation("checkpoint_submission_chunk.chunk_hash", :checkpoint_submission_chunk, %{submission_chunk | chunk_hash: :binary.copy(<<0xFF>>, 32)}),
          encode_mutation("checkpoint_submission_chunk.credential_epoch", :checkpoint_submission_chunk, %{submission_chunk | credential_epoch: 8}),
          encode_mutation("checkpoint_hydration_chunk.boot_id", :checkpoint_hydration_chunk, Map.put(hydration_chunk, :boot_id, <<0::128>>)),
          encode_mutation("checkpoint_submission_resume.missing_ranges_empty", :checkpoint_submission_resume, %{submission_resume | missing_ranges: []}),
          encode_mutation("checkpoint_submission_resume.missing_range_zero", :checkpoint_submission_resume, %{submission_resume | missing_ranges: [%{first_chunk_index: 0, chunk_count: 0}]}),
          encode_mutation("checkpoint_submission_resume.missing_ranges_adjacent", :checkpoint_submission_resume, %{submission_resume | missing_ranges: [%{first_chunk_index: 0, chunk_count: 1}, %{first_chunk_index: 1, chunk_count: 1}]}),
          encode_mutation("checkpoint_submission_resume.missing_ranges_over_cap", :checkpoint_submission_resume, %{submission_resume | missing_ranges: for(index <- 0..69, do: %{first_chunk_index: index, chunk_count: 1})})
        ]

        decode_mutations =
          for type <- @types do
            attrs =
              if type in [:checkpoint_submission_chunk, :checkpoint_hydration_chunk],
                do: chunk_attrs(type, 1, 0),
                else: resume_attrs(type, 1, [%{first_chunk_index: 0, chunk_count: 1}])

            {:ok, bytes} = Messages.encode(type, attrs)
            domain = Contract.payload_domain(type)
            {:ok, code, _direction} = Contract.message_type(type)
            <<^domain::binary, version, ^code, body::binary>> = bytes
            wrong_code = if(code == 0x34, do: 0x35, else: 0x34)

            [
              decode_mutation("\#{type}.domain", type, replace_byte(bytes, 0, 0)),
              decode_mutation("\#{type}.version", type, domain <> <<version + 1, code>> <> body),
              decode_mutation("\#{type}.type", type, domain <> <<version, wrong_code>> <> body),
              decode_mutation("\#{type}.truncated", type, binary_part(bytes, 0, byte_size(bytes) - 1)),
              decode_mutation("\#{type}.trailing", type, bytes <> <<0>>)
            ]
          end
          |> List.flatten()

        encode_mutations ++ decode_mutations
      end

      defp codec_vector(id, type, attrs) do
        encode = Messages.encode(type, attrs)

        decode =
          case encode do
            {:ok, bytes} -> Messages.decode(type, bytes)
            {:error, _reason} = error -> error
          end

        %{id: id, type: type, attrs: attrs, encode: encode, decode: decode}
      end

      defp encode_mutation(id, type, input),
        do: %{id: id, operation: :encode, type: type, input: input, result: Messages.encode(type, input)}

      defp decode_mutation(id, type, input),
        do: %{id: id, operation: :decode, type: type, input: input, result: Messages.decode(type, input)}

      defp vector_attrs!(vectors, id), do: Enum.find(vectors, &(&1.id == id)).attrs

      defp chunk_attrs(type, total, index) do
        common = if type == :checkpoint_submission_chunk, do: submission_common(), else: hydration_common()
        offset = index * @chunk_size
        length = max(min(@chunk_size, total - offset), 0)
        chunk = :binary.copy(<<rem(index + total, 256)>>, length)

        common
        |> Map.merge(%{
          total_content_length: total,
          chunk_index: index,
          chunk_count: chunk_count(total),
          chunk_offset: offset,
          chunk_hash: <<0::256>>,
          chunk: chunk
        })
        |> rehash_chunk()
      end

      defp resume_attrs(type, total, ranges) do
        common = if type == :checkpoint_submission_resume, do: submission_common(), else: hydration_common()
        Map.merge(common, %{total_content_length: total, chunk_count: chunk_count(total), missing_ranges: ranges})
      end

      defp submission_common do
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

        {:ok, checkpoint_hash} = Checkpoint.hash(attrs)
        Map.put(attrs, :checkpoint_hash, checkpoint_hash)
      end

      defp hydration_common do
        submission_common()
        |> Map.put(:credential_epoch, 8)
        |> Map.put(:storage_epoch, @target_storage_epoch)
        |> Map.put(:origin_credential_epoch, 7)
        |> Map.put(:origin_storage_epoch, @submission_storage_epoch)
      end

      defp rehash_chunk(attrs) do
        hash_attrs = Map.take(attrs, [:checkpoint_hash, :total_content_length, :chunk_index, :chunk_count, :chunk_offset, :chunk])

        chunk_hash =
          :crypto.hash(
            :sha256,
            Contract.checkpoint_content_chunk_hash_domain() <>
              <<Contract.version(), hash_attrs.checkpoint_hash::binary-size(32), hash_attrs.total_content_length::64,
                hash_attrs.chunk_index::32, hash_attrs.chunk_count::32, hash_attrs.chunk_offset::64,
                byte_size(hash_attrs.chunk)::32, hash_attrs.chunk::binary>>
          )

        Map.put(attrs, :chunk_hash, chunk_hash)
      end

      defp separated_ranges(count),
        do: for(index <- 0..(count - 1), do: %{first_chunk_index: index * 2, chunk_count: 1})

      defp chunk_count(total), do: div(total + @chunk_size - 1, @chunk_size)

      defp replace_byte(bytes, offset, replacement) do
        <<prefix::binary-size(offset), _old, suffix::binary>> = bytes
        prefix <> <<replacement>> <> suffix
      end
    end

    snapshot = BackendCheckpointTransferDirectSourceProbe.run(#{inspect(kat_path)})
    IO.write("BACKEND_CHECKPOINT_TRANSFER_FIXTURE:" <> (snapshot |> :erlang.term_to_binary() |> Base.encode64()))
    """
  end
end
