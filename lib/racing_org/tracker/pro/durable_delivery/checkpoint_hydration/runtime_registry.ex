defmodule RacingOrg.Tracker.Pro.DurableDelivery.CheckpointHydration.RuntimeRegistry do
  @moduledoc """
  Closed injected dispatch for exact-runtime checkpoint schemas.

  The registry does not consult the legacy learner checkpoint contract or infer a
  latest version. Callers must supply every exact `{kind, schema_version}` pair
  they are prepared to validate and restore; all other pairs fail closed.
  """

  @enforce_keys [:entries, :kinds]
  defstruct @enforce_keys

  @opaque t :: %__MODULE__{
            entries: %{{atom(), pos_integer()} => module()},
            kinds: MapSet.t(atom())
          }

  @spec new([{atom(), pos_integer(), module()}]) ::
          {:ok, t()} | {:error, atom()}
  def new(entries) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}, MapSet.new()}, fn entry, {:ok, acc, kinds} ->
      case validate_entry(entry) do
        {:ok, kind, schema_version, adapter} ->
          identity = {kind, schema_version}

          if Map.has_key?(acc, identity) do
            {:halt, {:error, :duplicate_checkpoint_runtime_schema}}
          else
            {:cont, {:ok, Map.put(acc, identity, adapter), MapSet.put(kinds, kind)}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, registry, kinds} -> {:ok, %__MODULE__{entries: registry, kinds: kinds}}
      {:error, _reason} = error -> error
    end
  end

  def new(_entries), do: {:error, :invalid_checkpoint_runtime_registry}

  @spec entries(t()) :: [{atom(), pos_integer(), module()}]
  def entries(%__MODULE__{} = registry) do
    registry.entries
    |> Enum.map(fn {{kind, schema_version}, adapter} -> {kind, schema_version, adapter} end)
    |> Enum.sort()
  end

  @spec fetch(t(), atom(), pos_integer()) ::
          {:ok, module()}
          | {:error,
             :invalid_checkpoint_runtime_identity
             | :unknown_checkpoint_runtime_kind
             | :unsupported_checkpoint_runtime_schema}
  def fetch(%__MODULE__{} = registry, kind, schema_version)
      when is_atom(kind) and is_integer(schema_version) and schema_version > 0 do
    case Map.fetch(registry.entries, {kind, schema_version}) do
      {:ok, adapter} ->
        {:ok, adapter}

      :error ->
        if MapSet.member?(registry.kinds, kind),
          do: {:error, :unsupported_checkpoint_runtime_schema},
          else: {:error, :unknown_checkpoint_runtime_kind}
    end
  end

  def fetch(%__MODULE__{}, _kind, _schema_version),
    do: {:error, :invalid_checkpoint_runtime_identity}

  defp validate_entry({kind, schema_version, adapter})
       when is_atom(kind) and is_integer(schema_version) and schema_version > 0 and
              is_atom(adapter) do
    {:ok, kind, schema_version, adapter}
  end

  defp validate_entry(_entry), do: {:error, :invalid_checkpoint_runtime_registry}
end
