defmodule RacingOrg.Tracker.Pro.DurableNamespace do
  @moduledoc """
  Deterministic path projection for exact durable Ledger and Outbox identities.

  Each leaf is owned by one full `{device_id, credential_epoch, storage_epoch}`
  identity. Device and storage components group credential leaves for stable
  enumeration, but only the complete credential path names a store owner.
  """

  @identity_keys [:credential_epoch, :device_id, :storage_epoch]
  @identifier_bytes 16
  @zero_identifier <<0::128>>
  @u32_max 0xFFFF_FFFF
  @device_prefix "device-"
  @storage_prefix "storage-"
  @credential_prefix "credential-"
  @kind_components %{ledger: "ledger", outbox: "outbox"}

  defmodule Leaf do
    @moduledoc "Stable full-identity metadata returned for generated and parsed leaves."

    @enforce_keys [
      :root,
      :kind,
      :identity,
      :lineage,
      :credential_epoch,
      :relative_path,
      :path,
      :device_path,
      :storage_path,
      :credential_path
    ]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            root: Path.t(),
            kind: :ledger | :outbox,
            identity: %{
              device_id: <<_::128>>,
              credential_epoch: non_neg_integer(),
              storage_epoch: <<_::128>>
            },
            lineage: {<<_::128>>, <<_::128>>},
            credential_epoch: non_neg_integer(),
            relative_path: Path.t(),
            path: Path.t(),
            device_path: Path.t(),
            storage_path: Path.t(),
            credential_path: Path.t()
          }
  end

  @doc "Build metadata for one exact Ledger or Outbox durable identity leaf."
  @spec leaf(Path.t(), :ledger | :outbox, map()) :: {:ok, Leaf.t()} | {:error, atom()}
  def leaf(root, kind, identity) do
    with {:ok, root} <- canonical_root(root),
         {:ok, kind_component} <- kind_component(kind),
         {:ok, identity} <- validate_identity(identity) do
      {:ok, build_leaf(root, kind, kind_component, identity)}
    end
  end

  @doc "Parse one canonical leaf path into stable full-identity enumeration metadata."
  @spec parse_leaf(Path.t(), Path.t()) :: {:ok, Leaf.t()} | {:error, atom()}
  def parse_leaf(root, path) do
    with {:ok, root} <- canonical_root(root),
         {:ok, components} <- relative_leaf_components(root, path),
         {:ok, device_id, storage_epoch, credential_epoch, kind} <- parse_components(components),
         identity = %{
           device_id: device_id,
           credential_epoch: credential_epoch,
           storage_epoch: storage_epoch
         },
         {:ok, leaf} <- leaf(root, kind, identity),
         true <- leaf.path == path do
      {:ok, leaf}
    else
      _reason -> {:error, :invalid_leaf_path}
    end
  end

  defp canonical_root(root) when is_binary(root) and root != "" do
    if :binary.match(root, <<0>>) == :nomatch and Path.type(root) == :absolute and
         Path.expand(root) == root do
      {:ok, root}
    else
      {:error, :invalid_root}
    end
  end

  defp canonical_root(_root), do: {:error, :invalid_root}

  defp kind_component(kind) do
    case Map.fetch(@kind_components, kind) do
      {:ok, component} -> {:ok, component}
      :error -> {:error, :invalid_kind}
    end
  end

  defp kind_from_component(component) do
    case Enum.find(@kind_components, fn {_kind, value} -> value == component end) do
      {kind, _component} -> {:ok, kind}
      nil -> {:error, :invalid_kind}
    end
  end

  defp validate_identity(identity) when is_map(identity) do
    if Enum.sort(Map.keys(identity)) == @identity_keys do
      with :ok <- validate_identifier(Map.get(identity, :device_id), :invalid_device_id),
           :ok <- validate_credential_epoch(Map.get(identity, :credential_epoch)),
           :ok <- validate_identifier(Map.get(identity, :storage_epoch), :invalid_storage_epoch) do
        {:ok, identity}
      end
    else
      {:error, :invalid_identity}
    end
  end

  defp validate_identity(_identity), do: {:error, :invalid_identity}

  defp validate_identifier(@zero_identifier, reason), do: {:error, reason}
  defp validate_identifier(<<_identifier::binary-size(@identifier_bytes)>>, _reason), do: :ok
  defp validate_identifier(_identifier, reason), do: {:error, reason}

  defp validate_credential_epoch(epoch)
       when is_integer(epoch) and epoch >= 0 and epoch <= @u32_max,
       do: :ok

  defp validate_credential_epoch(_epoch), do: {:error, :invalid_credential_epoch}

  defp build_leaf(root, kind, kind_component, identity) do
    device_component = @device_prefix <> encode_identifier(identity.device_id)
    storage_component = @storage_prefix <> encode_identifier(identity.storage_epoch)
    credential_component = @credential_prefix <> encode_credential_epoch(identity.credential_epoch)
    device_path = Path.join(root, device_component)
    storage_path = Path.join(device_path, storage_component)
    credential_path = Path.join(storage_path, credential_component)
    path = Path.join(credential_path, kind_component)

    %Leaf{
      root: root,
      kind: kind,
      identity: identity,
      lineage: {identity.device_id, identity.storage_epoch},
      credential_epoch: identity.credential_epoch,
      relative_path: Path.join([device_component, storage_component, credential_component, kind_component]),
      path: path,
      device_path: device_path,
      storage_path: storage_path,
      credential_path: credential_path
    }
  end

  defp relative_leaf_components(root, path) when is_binary(path) and path != "" do
    if :binary.match(path, <<0>>) == :nomatch and Path.type(path) == :absolute and
         Path.expand(path) == path do
      relative = Path.relative_to(path, root)

      if relative != path and relative != ".." and not String.starts_with?(relative, "../") do
        case Path.split(relative) do
          [device, storage, credential, kind] = components ->
            if Enum.all?(components, &safe_component?/1),
              do: {:ok, [device, storage, credential, kind]},
              else: {:error, :invalid_leaf_path}

          _components ->
            {:error, :invalid_leaf_path}
        end
      else
        {:error, :invalid_leaf_path}
      end
    else
      {:error, :invalid_leaf_path}
    end
  end

  defp relative_leaf_components(_root, _path), do: {:error, :invalid_leaf_path}

  defp safe_component?(component) when is_binary(component) do
    component not in ["", ".", ".."] and :binary.match(component, ["/", "\\", <<0>>]) == :nomatch and
      ascii?(component)
  end

  defp safe_component?(_component), do: false

  defp ascii?(component) do
    component
    |> :binary.bin_to_list()
    |> Enum.all?(&(&1 >= 0x20 and &1 <= 0x7E))
  end

  defp parse_components([device_component, storage_component, credential_component, kind_component]) do
    with {:ok, device_id} <- parse_identifier_component(device_component, @device_prefix),
         {:ok, storage_epoch} <- parse_identifier_component(storage_component, @storage_prefix),
         {:ok, credential_epoch} <- parse_credential_component(credential_component),
         {:ok, kind} <- kind_from_component(kind_component),
         :ok <- validate_identifier(device_id, :invalid_device_id),
         :ok <- validate_identifier(storage_epoch, :invalid_storage_epoch) do
      {:ok, device_id, storage_epoch, credential_epoch, kind}
    end
  end

  defp parse_identifier_component(component, prefix) do
    with {:ok, encoded} <- exact_suffix(component, prefix, @identifier_bytes * 2),
         {:ok, identifier} <- Base.decode16(encoded, case: :lower),
         true <- encode_identifier(identifier) == encoded do
      {:ok, identifier}
    else
      _reason -> {:error, :invalid_identifier_component}
    end
  end

  defp parse_credential_component(component) do
    with {:ok, encoded} <- exact_suffix(component, @credential_prefix, 8),
         {epoch, ""} <- Integer.parse(encoded, 16),
         :ok <- validate_credential_epoch(epoch),
         true <- encode_credential_epoch(epoch) == encoded do
      {:ok, epoch}
    else
      _reason -> {:error, :invalid_credential_component}
    end
  end

  defp exact_suffix(component, prefix, encoded_size) do
    case component do
      <<^prefix::binary, encoded::binary-size(encoded_size)>> -> {:ok, encoded}
      _component -> {:error, :invalid_component}
    end
  end

  defp encode_identifier(identifier), do: Base.encode16(identifier, case: :lower)

  defp encode_credential_epoch(epoch) do
    epoch
    |> Integer.to_string(16)
    |> String.downcase(:ascii)
    |> String.pad_leading(8, "0")
  end
end
