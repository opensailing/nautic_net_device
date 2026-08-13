defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointSubmission.Builder do
  @moduledoc """
  Pure exact-runtime checkpoint construction and durable-admission boundary.

  Snapshot acquisition, runtime projection, durable identity, backend-accepted
  parent lookup, and outbox admission are injected. The outbox collaborator owns
  sequence allocation and invokes the supplied builder while its mutation lock is
  held. Success is returned only when that collaborator reports durable enqueue
  success.
  """

  alias RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHead.Record
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Checkpoint
  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Messages

  @identity_keys [:device_id, :credential_epoch, :storage_epoch]
  @device_id_size 16
  @storage_epoch_size 16
  @hash_size 32
  @u32_max 0xFFFF_FFFF

  @runtime_schemas Map.new(Contract.checkpoint_runtime_schemas(), fn {kind, _code, schema_version} ->
                     {kind, schema_version}
                   end)

  @type result :: {:ok, term()} | {:error, term()}
  @type options :: [
          observer_snapshot: (-> {:ok, term()} | {:error, term()}),
          runtime_adapter: module() | (term() -> {:ok, map()} | {:error, term()}),
          durable_identity: (-> {:ok, map()} | {:error, term()}),
          accepted_parent: (atom() -> {:ok, <<_::256>>} | :empty | {:error, term()}),
          enqueue_checkpoint: ((pos_integer() ->
                                  {:ok, %{payload: binary(), payload_hash: <<_::256>>}} | {:error, term()}) ->
                                 result()),
          content_hash: (atom(), pos_integer(), binary() -> {:ok, <<_::256>>} | {:error, term()}),
          checkpoint_hash: (map() -> {:ok, <<_::256>>} | {:error, term()}),
          message_encoder: (atom(), map() -> {:ok, binary()} | {:error, term()})
        ]

  @doc """
  Build and durably admit the current exact-runtime checkpoint for `kind`.

  The authoritative checkpoint sequence is supplied by `:enqueue_checkpoint`.
  Every explicit collaborator error and the final enqueue result pass through
  unchanged.
  """
  @spec submit(atom(), options()) :: result()
  def submit(kind, opts) when is_atom(kind) and is_list(opts) do
    with {:ok, schema_version} <- runtime_schema(kind),
         {:ok, dependencies} <- dependencies(opts) do
      dependencies.enqueue_checkpoint.(fn sequence ->
        build(kind, schema_version, sequence, dependencies)
      end)
    end
  end

  def submit(_kind, _opts), do: {:error, :invalid_checkpoint_builder_options}

  defp build(kind, schema_version, sequence, dependencies) do
    with {:ok, snapshot} <- acquire_snapshot(dependencies.observer_snapshot),
         {:ok, content} <- project_snapshot(dependencies.runtime_adapter, snapshot),
         {:ok, identity} <- acquire_identity(dependencies.durable_identity),
         {:ok, parent_hash} <- acquire_parent(dependencies.accepted_parent, kind),
         {:ok, source_generation} <- source_generation(kind, schema_version, content),
         {:ok, canonical_content} <- Checkpoint.canonical_content(kind, schema_version, content),
         :ok <- Checkpoint.validate_authority(kind, schema_version, canonical_content, identity),
         {:ok, content_hash} <-
           dependencies.content_hash.(kind, schema_version, canonical_content),
         attrs =
           checkpoint_attrs(
             identity,
             sequence,
             kind,
             schema_version,
             source_generation,
             parent_hash,
             content_hash
           ),
         {:ok, checkpoint_hash} <- dependencies.checkpoint_hash.(attrs),
         {:ok, payload} <-
           dependencies.message_encoder.(
             :checkpoint_submission,
             attrs
             |> Map.put(:checkpoint_hash, checkpoint_hash)
             |> Map.put(:content, canonical_content)
           ) do
      {:ok, %{payload: payload, payload_hash: checkpoint_hash}}
    end
  end

  defp runtime_schema(kind) do
    case Map.fetch(@runtime_schemas, kind) do
      {:ok, schema_version} -> {:ok, schema_version}
      :error -> {:error, :unknown_checkpoint_kind}
    end
  end

  defp dependencies(opts) do
    with {:ok, observer_snapshot} <- function_option(opts, :observer_snapshot, 0),
         {:ok, runtime_adapter} <- adapter_option(opts),
         {:ok, durable_identity} <- function_option(opts, :durable_identity, 0),
         {:ok, accepted_parent} <- function_option(opts, :accepted_parent, 1),
         {:ok, enqueue_checkpoint} <- function_option(opts, :enqueue_checkpoint, 1),
         {:ok, content_hash} <-
           optional_function(opts, :content_hash, 3, &Checkpoint.content_hash/3),
         {:ok, checkpoint_hash} <-
           optional_function(opts, :checkpoint_hash, 1, &Checkpoint.hash/1),
         {:ok, message_encoder} <-
           optional_function(opts, :message_encoder, 2, &Messages.encode/2) do
      {:ok,
       %{
         observer_snapshot: observer_snapshot,
         runtime_adapter: runtime_adapter,
         durable_identity: durable_identity,
         accepted_parent: accepted_parent,
         enqueue_checkpoint: enqueue_checkpoint,
         content_hash: content_hash,
         checkpoint_hash: checkpoint_hash,
         message_encoder: message_encoder
       }}
    end
  end

  defp function_option(opts, key, arity) do
    case Keyword.fetch(opts, key) do
      {:ok, function} when is_function(function, arity) -> {:ok, function}
      _other -> {:error, {:invalid_checkpoint_builder_dependency, key}}
    end
  end

  defp optional_function(opts, key, arity, default) do
    case Keyword.fetch(opts, key) do
      :error -> {:ok, default}
      {:ok, function} when is_function(function, arity) -> {:ok, function}
      _other -> {:error, {:invalid_checkpoint_builder_dependency, key}}
    end
  end

  defp adapter_option(opts) do
    case Keyword.fetch(opts, :runtime_adapter) do
      {:ok, adapter} when is_function(adapter, 1) -> {:ok, adapter}
      {:ok, adapter} when is_atom(adapter) -> {:ok, adapter}
      _other -> {:error, {:invalid_checkpoint_builder_dependency, :runtime_adapter}}
    end
  end

  defp acquire_snapshot(observer_snapshot) do
    case observer_snapshot.() do
      {:ok, snapshot} -> {:ok, snapshot}
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_observer_snapshot_result}
    end
  end

  defp project_snapshot(runtime_adapter, snapshot) when is_function(runtime_adapter, 1) do
    normalize_projection(runtime_adapter.(snapshot))
  end

  defp project_snapshot(runtime_adapter, snapshot) when is_atom(runtime_adapter) do
    with {:module, ^runtime_adapter} <- Code.ensure_loaded(runtime_adapter),
         true <- function_exported?(runtime_adapter, :project, 1) do
      normalize_projection(runtime_adapter.project(snapshot))
    else
      _other -> {:error, :invalid_runtime_adapter}
    end
  end

  defp normalize_projection({:ok, content}) when is_map(content), do: {:ok, content}
  defp normalize_projection({:error, _reason} = error), do: error
  defp normalize_projection(_other), do: {:error, :invalid_runtime_adapter_result}

  defp acquire_identity(durable_identity) do
    case durable_identity.() do
      {:ok, identity} -> validate_identity(identity)
      {:error, _reason} = error -> error
      _other -> {:error, :invalid_durable_identity_result}
    end
  end

  defp validate_identity(identity) when is_map(identity) do
    with true <- Map.keys(identity) |> Enum.sort() == Enum.sort(@identity_keys),
         true <- fixed_binary?(identity.device_id, @device_id_size),
         true <- is_integer(identity.credential_epoch),
         true <- identity.credential_epoch in 0..@u32_max,
         true <- nonzero_binary?(identity.storage_epoch, @storage_epoch_size) do
      {:ok, identity}
    else
      _other -> {:error, :invalid_durable_identity}
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_durable_identity}

  defp acquire_parent(accepted_parent, kind) do
    case accepted_parent.(kind) do
      :empty ->
        {:ok, Record.genesis_parent()}

      {:ok, parent_hash} when is_binary(parent_hash) and byte_size(parent_hash) == @hash_size ->
        {:ok, parent_hash}

      {:ok, _parent_hash} ->
        {:error, :invalid_accepted_parent}

      {:error, _reason} = error ->
        error

      _other ->
        {:error, :invalid_accepted_parent_result}
    end
  end

  defp source_generation(:calibration, 2, %{"learner" => %{"seq" => generation}}),
    do: generation(generation)

  defp source_generation(:polar, 3, %{
         "learner" => %{"source_generation" => generation}
       }),
       do: generation(generation)

  defp source_generation(:wind_shift, 2, %{"source_generation" => generation}),
    do: generation(generation)

  defp source_generation(_kind, _schema_version, _content),
    do: {:error, :invalid_source_generation}

  defp generation(value) when is_integer(value) and value >= 0 and value <= 9_223_372_036_854_775_807,
    do: {:ok, value}

  defp generation(_value), do: {:error, :invalid_source_generation}

  defp checkpoint_attrs(
         identity,
         sequence,
         kind,
         schema_version,
         source_generation,
         parent_hash,
         content_hash
       ) do
    %{
      device_id: identity.device_id,
      credential_epoch: identity.credential_epoch,
      storage_epoch: identity.storage_epoch,
      sequence: sequence,
      kind: kind,
      schema_version: schema_version,
      source_generation: source_generation,
      parent_hash: parent_hash,
      content_hash: content_hash
    }
  end

  defp fixed_binary?(value, size), do: is_binary(value) and byte_size(value) == size
  defp nonzero_binary?(value, size), do: fixed_binary?(value, size) and value != <<0::size(size)-unit(8)>>
end
