defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Payload do
  @moduledoc """
  Durable outbox representation for complete checkpoint submissions.

  Checkpoints that fit the frozen single-frame wire contract retain those exact
  bytes. Larger exact-runtime checkpoints use a private, checksummed envelope
  containing the same record metadata and canonical content. The envelope is an
  at-rest outbox value only; submission planning converts it to frozen chunk
  frames before transport.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Checkpoint, Messages}

  @magic "ROCP"
  @version 1
  @kind_code 1
  @header_size 18
  @checksum_size 32
  @checksum_domain "RacingOrg-DurableCheckpointPayload-v1"
  @hash_size 32
  @common_size 153
  @common_keys [
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

  @doc "Encode a complete checkpoint for durable outbox storage."
  @spec encode(map()) :: {:ok, binary()} | {:error, term()}
  def encode(%{content: content} = submission) when is_binary(content) do
    if byte_size(content) <= Contract.max_checkpoint_size() do
      Messages.encode(:checkpoint_submission, submission)
    else
      encode_large(submission)
    end
  end

  def encode(_submission), do: {:error, :invalid_checkpoint_submission}

  @doc "Decode either the exact legacy frame or the private large-content envelope."
  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case Messages.decode(:checkpoint_submission, payload) do
      {:ok, submission} -> {:ok, submission}
      {:error, _reason} -> decode_large(payload)
    end
  end

  def decode(_payload), do: {:error, :invalid_checkpoint_submission}

  defp encode_large(submission) do
    with :ok <- exact_keys(submission, @common_keys ++ [:content]),
         content when is_binary(content) <- submission.content,
         :ok <- large_content_size(content),
         {:ok, expected_content_hash} <-
           Checkpoint.content_hash(submission.kind, submission.schema_version, content),
         :ok <- exact_hash(expected_content_hash, submission.content_hash, :checkpoint_content_hash_mismatch),
         {:ok, expected_checkpoint_hash} <- Checkpoint.hash(Map.take(submission, @common_keys -- [:checkpoint_hash])),
         :ok <- exact_hash(expected_checkpoint_hash, submission.checkpoint_hash, :checkpoint_hash_mismatch),
         {:ok, metadata} <- encode_metadata(submission) do
      content_length = byte_size(content)
      prefix = <<@magic, @version, @kind_code, byte_size(metadata)::32, content_length::64>>
      checksum = checksum(prefix, metadata, content)
      {:ok, prefix <> checksum <> metadata <> content}
    else
      false -> {:error, :invalid_checkpoint_submission}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkpoint_submission}
    end
  end

  defp decode_large(
         <<@magic, @version, @kind_code, metadata_length::32, content_length::64,
           stored_checksum::binary-size(@checksum_size), rest::binary>> = payload
       ) do
    total_length = metadata_length + content_length

    with true <- byte_size(rest) == total_length,
         <<metadata::binary-size(metadata_length), content::binary-size(content_length)>> <- rest,
         prefix <- binary_part(payload, 0, @header_size),
         :ok <- exact_hash(checksum(prefix, metadata, content), stored_checksum, :checkpoint_payload_checksum_mismatch),
         {:ok, common} <- decode_metadata(metadata),
         submission = Map.put(common, :content, content),
         {:ok, canonical} <- encode_large(submission),
         true <- canonical == payload do
      {:ok, submission}
    else
      false -> {:error, :invalid_checkpoint_payload}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_checkpoint_payload}
    end
  end

  defp decode_large(_payload), do: {:error, :invalid_checkpoint_payload}

  defp encode_metadata(submission) do
    with {:ok, checkpoint_preimage} <-
           submission
           |> Map.take(@common_keys -- [:checkpoint_hash])
           |> Checkpoint.encode(),
         true <- byte_size(checkpoint_preimage) == @common_size do
      {:ok, checkpoint_preimage <> submission.checkpoint_hash}
    else
      false -> {:error, :invalid_checkpoint_payload}
      {:error, _reason} = error -> error
    end
  end

  defp decode_metadata(<<checkpoint_preimage::binary-size(@common_size), checkpoint_hash::binary-size(@hash_size)>>) do
    with {:ok, common} <- Checkpoint.decode(checkpoint_preimage) do
      {:ok, Map.put(common, :checkpoint_hash, checkpoint_hash)}
    end
  end

  defp decode_metadata(_metadata), do: {:error, :invalid_checkpoint_payload}

  defp large_content_size(content) do
    size = byte_size(content)

    cond do
      size <= Contract.max_checkpoint_size() -> {:error, :noncanonical_checkpoint_payload}
      size > Contract.max_checkpoint_content_size() -> {:error, :checkpoint_too_large}
      true -> :ok
    end
  end

  defp exact_keys(map, keys) when is_map(map) do
    if Map.keys(map) |> Enum.sort() == Enum.sort(keys),
      do: :ok,
      else: {:error, :invalid_checkpoint_submission}
  end

  defp exact_hash(expected, presented, reason)
       when is_binary(expected) and is_binary(presented) and byte_size(expected) == byte_size(presented) do
    if :crypto.hash_equals(expected, presented), do: :ok, else: {:error, reason}
  end

  defp exact_hash(_expected, _presented, reason), do: {:error, reason}

  defp checksum(prefix, metadata, content) do
    :crypto.hash(:sha256, [@checksum_domain, prefix, metadata, content])
  end
end
