defmodule RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1.Negotiation do
  @moduledoc """
  Canonical desired-state/control wire-version offer parsing and selection.

  Negotiation chooses byte compatibility only. It does not grant authority or establish
  device identity; those remain bound to the authenticated control payloads.
  """

  alias RacingOrg.Tracker.Pro.SecureTransport.DesiredStateV1, as: Contract

  @attrs [:control_versions, :desired_state_versions]
  @u16_max 0xFFFF
  @max_versions 8

  @doc "Parse Phoenix connection parameters, preserving omitted parameters as legacy mode."
  def parse_params(params) when is_map(params) do
    case {Map.has_key?(params, "control_versions"), Map.has_key?(params, "desired_state_versions")} do
      {false, false} ->
        {:ok, :legacy}

      {true, true} ->
        with {:ok, control_versions} <- parse_versions(params["control_versions"]),
             {:ok, desired_state_versions} <- parse_versions(params["desired_state_versions"]) do
          {:ok,
           %{
             control_versions: control_versions,
             desired_state_versions: desired_state_versions
           }}
        end

      {_control_present, _desired_present} ->
        {:error, :incomplete_capability_offer}
    end
  end

  def parse_params(_), do: {:error, :invalid_capability_offer}

  @doc "Encode the exact offer bytes authenticated by `control_accept` and `readiness`."
  def encode_offer(offer) when is_map(offer) do
    with :ok <- exact_keys(offer, @attrs),
         {:ok, control} <- validate_versions(offer.control_versions),
         {:ok, desired} <- validate_versions(offer.desired_state_versions) do
      {:ok,
       Contract.offer_domain() <>
         <<Contract.version(), length(control)>> <>
         encode_versions(control) <>
         <<length(desired)>> <>
         encode_versions(desired)}
    end
  end

  def encode_offer(_), do: {:error, :invalid_capability_offer}

  @doc "Strictly decode one canonical capability offer."
  def decode_offer(bytes) when is_binary(bytes) do
    with {:ok, rest} <- strip_domain_version(bytes),
         <<control_count, rest::binary>> <- rest,
         :ok <- ensure_count(control_count),
         {:ok, control, rest} <- take_versions(rest, control_count, []),
         <<desired_count, rest::binary>> <- rest,
         :ok <- ensure_count(desired_count),
         {:ok, desired, <<>>} <- take_versions(rest, desired_count, []),
         {:ok, control} <- validate_versions(control),
         {:ok, desired} <- validate_versions(desired),
         offer = %{desired_state_versions: desired, control_versions: control},
         {:ok, canonical} <- encode_offer(offer),
         true <- canonical == bytes || {:error, :noncanonical_capability_offer} do
      {:ok, offer}
    else
      {:ok, _versions, _trailing} -> {:error, :trailing_bytes}
      false -> {:error, :noncanonical_capability_offer}
      {:error, _reason} = error -> error
      _ -> {:error, :truncated}
    end
  end

  def decode_offer(_), do: {:error, :invalid_capability_offer}

  @doc "SHA-256 the exact canonical offer bytes."
  def offer_hash(bytes) when is_binary(bytes), do: :crypto.hash(:sha256, bytes)

  def offer_hash(offer) when is_map(offer) do
    case encode_offer(offer) do
      {:ok, bytes} -> :crypto.hash(:sha256, bytes)
      {:error, reason} -> raise ArgumentError, "invalid desired-state offer: #{inspect(reason)}"
    end
  end

  @doc "Select the highest mutually supported frozen wire versions."
  def select(offer) when is_map(offer) do
    with :ok <- exact_keys(offer, @attrs),
         {:ok, desired} <- validate_versions(offer.desired_state_versions),
         {:ok, control} <- validate_versions(offer.control_versions),
         selected_desired when not is_nil(selected_desired) <- select_version(desired, [1]),
         selected_control when not is_nil(selected_control) <- select_version(control, [1]),
         {:ok, bytes} <- encode_offer(offer) do
      {:ok,
       %{
         selected_control_version: selected_control,
         selected_desired_version: selected_desired,
         offer_hash: offer_hash(bytes)
       }}
    else
      nil -> {:error, :no_common_version}
      {:error, _reason} = error -> error
    end
  end

  def select(_), do: {:error, :invalid_capability_offer}

  defp parse_versions(value) when is_binary(value) do
    pieces = String.split(value, ",", trim: false)

    cond do
      length(pieces) > Contract.max_capability_versions() ->
        {:error, :too_many_capability_versions}

      true ->
        pieces
        |> Enum.reduce_while({:ok, []}, fn piece, {:ok, acc} ->
          case parse_decimal_u16(piece) do
            {:ok, version} -> {:cont, {:ok, [version | acc]}}
            {:error, _reason} -> {:halt, {:error, :invalid_capability_versions}}
          end
        end)
        |> case do
          {:ok, versions} -> validate_versions(Enum.reverse(versions))
          error -> error
        end
    end
  end

  defp parse_versions(_), do: {:error, :invalid_capability_versions}

  defp parse_decimal_u16(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 and integer <= @u16_max ->
        if Integer.to_string(integer) == value,
          do: {:ok, integer},
          else: {:error, :invalid_capability_versions}

      _ ->
        {:error, :invalid_capability_versions}
    end
  end

  defp validate_versions(versions) when is_list(versions) do
    with :ok <- ensure_proper_list(versions) do
      cond do
        versions == [] ->
          {:error, :invalid_capability_versions}

        length(versions) > Contract.max_capability_versions() ->
          {:error, :too_many_capability_versions}

        Enum.any?(versions, &(not is_integer(&1) or &1 <= 0 or &1 > @u16_max)) ->
          {:error, :invalid_capability_versions}

        versions != Enum.sort(versions) or length(Enum.uniq(versions)) != length(versions) ->
          {:error, :invalid_capability_versions}

        true ->
          {:ok, versions}
      end
    end
  end

  defp validate_versions(_), do: {:error, :invalid_capability_versions}

  defp encode_versions(versions), do: IO.iodata_to_binary(Enum.map(versions, &<<&1::16>>))

  defp take_versions(rest, 0, acc), do: {:ok, Enum.reverse(acc), rest}

  defp take_versions(<<version::16, rest::binary>>, count, acc) do
    take_versions(rest, count - 1, [version | acc])
  end

  defp take_versions(_rest, _count, _acc), do: {:error, :truncated}

  defp strip_domain_version(bytes) do
    domain = Contract.offer_domain()
    size = byte_size(domain)

    case bytes do
      <<presented::binary-size(size), version, rest::binary>> ->
        cond do
          presented != domain -> {:error, :offer_domain_mismatch}
          version != Contract.version() -> {:error, :unsupported_offer_version}
          true -> {:ok, rest}
        end

      _ ->
        {:error, :truncated}
    end
  end

  defp select_version(offered, supported) do
    offered
    |> MapSet.new()
    |> MapSet.intersection(MapSet.new(supported))
    |> MapSet.to_list()
    |> Enum.max(fn -> nil end)
  end

  defp exact_keys(attrs, expected) do
    if Enum.sort(Map.keys(attrs)) == Enum.sort(expected),
      do: :ok,
      else: {:error, :invalid_capability_offer}
  end

  defp ensure_count(count) when count > 0 and count <= @max_versions, do: :ok
  defp ensure_count(count) when count > @max_versions, do: {:error, :too_many_capability_versions}
  defp ensure_count(_), do: {:error, :invalid_capability_versions}

  defp ensure_proper_list([]), do: :ok
  defp ensure_proper_list([_ | rest]), do: ensure_proper_list(rest)
  defp ensure_proper_list(_), do: {:error, :invalid_capability_versions}
end
