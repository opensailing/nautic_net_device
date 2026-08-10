defmodule RacingOrg.Tracker.Pro.DurableDelivery.Outbox.Snapshot do
  @moduledoc false

  @magic "RODS"
  @version 1
  @checksum_size 32
  @max_payload_size 64 * 1_024 * 1_024
  @checksum_domain "RacingOrg-DurableOutboxSnapshotChecksum-v1"

  @spec encode(map()) :: {:ok, binary()} | {:error, atom()}
  def encode(snapshot) when is_map(snapshot) do
    payload = :erlang.term_to_binary(snapshot, [:deterministic])
    payload_size = byte_size(payload)

    if payload_size <= @max_payload_size do
      checksum = checksum(payload_size, payload)
      {:ok, <<@magic, @version, payload_size::64, checksum::binary, payload::binary>>}
    else
      {:error, :snapshot_too_large}
    end
  end

  def encode(_snapshot), do: {:error, :invalid_snapshot}

  @spec decode(binary()) :: {:ok, map()} | {:error, atom()}
  def decode(<<@magic, @version, payload_size::64, stored_checksum::binary-size(@checksum_size), rest::binary>>) do
    cond do
      payload_size > @max_payload_size ->
        {:error, :snapshot_too_large}

      byte_size(rest) < payload_size ->
        {:error, :incomplete_snapshot}

      byte_size(rest) > payload_size ->
        {:error, :trailing_snapshot_bytes}

      true ->
        with :ok <- validate_checksum(stored_checksum, checksum(payload_size, rest)),
             {:ok, snapshot} <- decode_payload(rest) do
          {:ok, snapshot}
        end
    end
  end

  def decode(<<@magic, version, _rest::binary>>) when version != @version,
    do: {:error, :unsupported_snapshot_version}

  def decode(binary) when is_binary(binary) and byte_size(binary) < 5,
    do: {:error, :incomplete_snapshot}

  def decode(_binary), do: {:error, :invalid_snapshot}

  defp decode_payload(payload) do
    case :erlang.binary_to_term(payload, [:safe]) do
      snapshot when is_map(snapshot) -> {:ok, snapshot}
      _other -> {:error, :invalid_snapshot}
    end
  rescue
    _exception -> {:error, :invalid_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_snapshot}
  end

  defp checksum(payload_size, payload) do
    :crypto.hash(:sha256, [@checksum_domain, <<@version, payload_size::64>>, payload])
  end

  defp validate_checksum(checksum, checksum), do: :ok
  defp validate_checksum(_stored, _expected), do: {:error, :snapshot_checksum_mismatch}
end
