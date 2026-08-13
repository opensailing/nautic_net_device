defmodule RacingOrg.Tracker.Pro.DurableDelivery.Submission.Planner do
  @moduledoc """
  Pure planning from one pending durable outbox entry to frozen submission frames.

  Generic delivery submissions intentionally carry only durable identity and the
  payload hash. Their payload bytes remain separate work for the stream-specific
  transport. Checkpoint submissions carry their canonical content directly when
  it fits one frozen control payload and otherwise become exact checkpoint chunks.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Payload
  alias RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Entry
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.{Checkpoint, Messages}

  @type frame :: %{required(:type) => atom(), required(:attrs) => map()}

  @type plan :: %{
          required(:entry) => Entry.t(),
          required(:payload) => binary() | nil,
          required(:frames) => [frame()]
        }

  @doc "Plan frozen submission frames for one pending outbox entry."
  @spec plan(Entry.t(), keyword()) :: {:ok, plan()} | {:error, term()}
  def plan(entry, opts \\ [])

  def plan(%Entry{stream: :checkpoint} = entry, opts) when is_list(opts) do
    with {:ok, decoder} <- checkpoint_decoder(opts),
         {:ok, encoder} <- message_encoder(opts),
         {:ok, hash_fun} <- chunk_hash_fun(opts),
         {:ok, submission} <- decoder.(entry.payload),
         :ok <- checkpoint_entry_matches(entry, submission),
         {:ok, frames} <- checkpoint_frames(submission, encoder, hash_fun) do
      {:ok, %{entry: entry, payload: nil, frames: frames}}
    end
  end

  def plan(%Entry{} = entry, opts) when is_list(opts) do
    with {:ok, encoder} <- message_encoder(opts),
         attrs = delivery_submission_attrs(entry),
         {:ok, _encoded} <- encoder.(:delivery_submission, attrs) do
      {:ok,
       %{
         entry: entry,
         payload: entry.payload,
         frames: [%{type: :delivery_submission, attrs: attrs}]
       }}
    end
  end

  def plan(%Entry{}, _opts), do: {:error, :invalid_options}
  def plan(_entry, _opts), do: {:error, :invalid_outbox_entry}

  defp delivery_submission_attrs(entry) do
    %{
      device_id: entry.device_id,
      credential_epoch: entry.credential_epoch,
      storage_epoch: entry.storage_epoch,
      stream: entry.stream,
      sequence: entry.sequence,
      payload_hash: entry.payload_hash
    }
  end

  defp checkpoint_entry_matches(entry, submission) when is_map(submission) do
    if submission.device_id == entry.device_id and
         submission.credential_epoch == entry.credential_epoch and
         submission.storage_epoch == entry.storage_epoch and
         submission.sequence == entry.sequence and
         submission.checkpoint_hash == entry.payload_hash do
      :ok
    else
      {:error, :checkpoint_submission_mismatch}
    end
  rescue
    _exception -> {:error, :checkpoint_submission_mismatch}
  end

  defp checkpoint_entry_matches(_entry, _submission),
    do: {:error, :checkpoint_submission_mismatch}

  defp checkpoint_frames(%{content: content} = submission, encoder, hash_fun)
       when is_binary(content) do
    total_content_length = byte_size(content)

    with {:ok, expected_content_hash} <-
           Checkpoint.content_hash(submission.kind, submission.schema_version, content),
         :ok <- exact_content_hash(expected_content_hash, submission.content_hash) do
      do_checkpoint_frames(submission, encoder, hash_fun, total_content_length)
    end
  end

  defp checkpoint_frames(_submission, _encoder, _hash_fun),
    do: {:error, :checkpoint_submission_mismatch}

  defp do_checkpoint_frames(submission, encoder, hash_fun, total_content_length) do
    cond do
      total_content_length <= Contract.max_checkpoint_size() ->
        with {:ok, _encoded} <- encoder.(:checkpoint_submission, submission) do
          {:ok, [%{type: :checkpoint_submission, attrs: submission}]}
        end

      total_content_length > Contract.max_checkpoint_content_size() ->
        {:error, :checkpoint_too_large}

      true ->
        build_chunk_frames(
          Map.delete(submission, :content),
          submission.content,
          total_content_length,
          chunk_count(total_content_length),
          encoder,
          hash_fun,
          0,
          []
        )
    end
  end

  defp exact_content_hash(hash, hash), do: :ok
  defp exact_content_hash(_expected, _presented), do: {:error, :checkpoint_content_hash_mismatch}

  defp build_chunk_frames(
         _common,
         _content,
         _total_content_length,
         chunk_count,
         _encoder,
         _hash_fun,
         chunk_count,
         frames
       ),
       do: {:ok, Enum.reverse(frames)}

  defp build_chunk_frames(
         common,
         content,
         total_content_length,
         chunk_count,
         encoder,
         hash_fun,
         chunk_index,
         frames
       ) do
    chunk_offset = chunk_index * Contract.chunk_size()
    chunk_length = min(Contract.chunk_size(), total_content_length - chunk_offset)
    chunk = binary_part(content, chunk_offset, chunk_length)

    hash_attrs = %{
      checkpoint_hash: common.checkpoint_hash,
      total_content_length: total_content_length,
      chunk_index: chunk_index,
      chunk_count: chunk_count,
      chunk_offset: chunk_offset,
      chunk: chunk
    }

    with {:ok, chunk_hash} <- hash_fun.(hash_attrs),
         attrs <- Map.merge(common, Map.put(hash_attrs, :chunk_hash, chunk_hash)),
         {:ok, _encoded} <- encoder.(:checkpoint_submission_chunk, attrs) do
      build_chunk_frames(
        common,
        content,
        total_content_length,
        chunk_count,
        encoder,
        hash_fun,
        chunk_index + 1,
        [%{type: :checkpoint_submission_chunk, attrs: attrs} | frames]
      )
    end
  end

  defp chunk_count(total_content_length),
    do: div(total_content_length + Contract.chunk_size() - 1, Contract.chunk_size())

  defp checkpoint_decoder(opts), do: option_fun(opts, :checkpoint_decoder, 1, &Payload.decode/1)

  defp message_encoder(opts), do: option_fun(opts, :message_encoder, 2, &Messages.encode/2)
  defp chunk_hash_fun(opts), do: option_fun(opts, :chunk_hash, 1, &Checkpoint.chunk_hash/1)

  defp option_fun(opts, key, arity, default) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, default}
      {:ok, fun} when is_function(fun, arity) -> {:ok, fun}
      {:ok, _value} -> {:error, :invalid_options}
    end
  end
end
